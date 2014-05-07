%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2014, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Luis Azedo
%%%-------------------------------------------------------------------
-module(fax_xmpp).
-behaviour(gen_server).

-include("fax_gcp.hrl").
-include_lib("exmpp/include/exmpp.hrl").
-include_lib("exmpp/include/exmpp_client.hrl").

-define(XMPP_SCOPE,<<"https://www.googleapis.com/auth/googletalk">>).
-define(GCP_SCOPE,<<"https://www.googleapis.com/auth/cloudprint">>).
-define(SCOPES,<<(?XMPP_SCOPE)/binary, " ", (?GCP_SCOPE)/binary>>).
-define(XMPP_SERVER, "talk.google.com").

-export([start/1, start_link/1, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).
  
-export([send_notify/2]).


-record(state, {faxbox_id, printer_id, oauth_app_id, refresh_token, session, jid, full_jid}).


start(PrinterId) -> 
  gen_server:start({global, wh_util:to_atom(PrinterId, 'true')}, ?MODULE, [PrinterId], []).

start_link(PrinterId) -> 
  gen_server:start_link({global, wh_util:to_atom(PrinterId, 'true')}, ?MODULE, [PrinterId], []).
  
stop(PrinterId) ->
  gen_server:cast({global, wh_util:to_atom(PrinterId, 'true')}, stop).
  
init([PrinterId]) ->
    gen_server:cast(self(), 'start'),
    {ok, #state{faxbox_id=PrinterId}}.
  
  
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast('start', #state{faxbox_id=FaxBoxId} = State) ->
    lager:info("START"),
    case couch_mgr:open_doc(?WH_FAXES, FaxBoxId) of
        {'ok', JObj} ->
            Cloud = wh_json:get_value(<<"pvt_cloud">>, JObj),
            JID = wh_json:get_value(<<"xmpp_jid">>, Cloud),
            PrinterId = wh_json:get_value(<<"printer_id">>, Cloud),
            UID = <<JID/binary,"/",PrinterId/binary>>,
            AppId = wh_json:get_value(<<"oauth_app">>, Cloud),
            RefreshToken=#oauth_refresh_token{token=wh_json:get_value(<<"refresh_token">>, Cloud)},
            gen_server:cast(self(), 'connect'),
            {noreply, State#state{printer_id=PrinterId,
                                  oauth_app_id=AppId,
                                  full_jid=UID,
                                  refresh_token=RefreshToken}
            };
          E ->
              {stop, E, State}
    end;

handle_cast('connect', #state{oauth_app_id=AppId, full_jid=JID, refresh_token=RefreshToken}=State) ->
    {'ok', App} = kazoo_oauth_util:get_oauth_app(AppId),
    {'ok', #oauth_token{token=Token} = OAuthToken} = kazoo_oauth_util:token(App, RefreshToken),
    case connect(wh_util:to_list(JID), wh_util:to_list(Token)) of
        {ok, {MySession, MyJID}} ->
            gen_server:cast(self(), 'subscribe'),
            {noreply, State#state{session=MySession, jid=MyJID}};
        _ -> 
            {stop, <<"Error connecting to xmpp server">>, State}
    end;

handle_cast('status', State) ->
    'ok';

handle_cast('subscribe', #state{jid=MyJID, session=MySession}=State) ->
    IQ = get_sub_msg(MyJID),
    PacketId = exmpp_session:send_packet(MySession, IQ),
    {noreply, State};

handle_cast(stop, State) -> {stop, normal, State};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(#received_packet{packet_type='message'}=Packet, State) ->
    lager:info("received_packet"),
  process_received_packet(Packet, State),
  {noreply, State};
handle_info(#received_packet{}=Packet, State) ->
    lager:info("received_packet not message ~p",[Packet]),
  {noreply, State};
handle_info(_Info, State) -> 
    lager:info("xmpp handle_info ~p",[_Info]),
  {noreply, State}.
terminate(_Reason, #state{session=MySession}) -> 
  disconnect(MySession),
  ok;
terminate(_Reason, State) -> 
  ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.


get_sub_msg({_, JFull, JUser, JDomain,JResource} = JID) ->
    BareJID = <<JUser/binary,"@",JDomain/binary>>,
    Document = <<"<iq type='set' to='",BareJID/binary,"'>"
                 ,   "<subscribe xmlns='google:push'>"
                 ,      "<item channel='cloudprint.google.com' from='cloudprint.google.com'/>"
                 ,   "</subscribe>"
                 ,"</iq>">>,
     Document.

-define(NS_PUSH, 'google:push').
-define(XML_CTX_OPTIONS,[{namespace, [{"g", "google:push"}]}]).

process_received_packet(#received_packet{raw_packet=Packet},#state{jid=JID}=State) ->
    {_, JFull, JUser, JDomain,JResource} = JID,
    BareJID = <<JUser/binary,"@",JDomain/binary>>,
    case exmpp_xml:get_element(Packet, ?NS_PUSH, 'push') of
        'undefined' -> 'undefined';
        Push -> 
            DataNode = exmpp_xml:get_element(Push, ?NS_PUSH, 'data'),
            Data64 = exmpp_xml:get_cdata(DataNode),
            PrinterId = base64:decode(Data64),
            send_notify(PrinterId, BareJID)
    end.

send_notify(PrinterId, JID) ->
    Payload = props:filter_undefined(
                [{<<"Event-Name">>, <<"push">>}
                ,{<<"Application-Name">>, <<"GCP">>}
                ,{<<"Application-Event">>, <<"Queued-Job">>}
                ,{<<"Application-Data">>, PrinterId}
                ,{<<"JID">>, JID}
                | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
                ]),
    wapi_xmpp:publish_event(Payload).
    
connect(JID, Password) ->
    Session = exmpp_session:start({1,0}),
    Jid = exmpp_jid:parse(JID),
    exmpp_session:auth(Session, Jid, Password, "X-OAUTH2"),
    StreamId  = exmpp_session:connect_TCP(Session, ?XMPP_SERVER, 5222,[{starttls, enabled}]),
    
    try init_session(Session, Password)
    catch
      _:Error -> io:format("got error: ~p~n", [Error]),
         {error, Error}
    end,
    {ok, {Session, Jid}}.

init_session(Session, Password) ->
  try exmpp_session:login(Session,"X-OAUTH2")
  catch
    throw:{auth_error, 'not-authorized'} ->
    exmpp_session:register_account(Session, Password),
    exmpp_session:login(Session)
  end,
  exmpp_session:send_packet(Session, exmpp_presence:set_status(exmpp_presence:available(), "Pubsubber Ready")),
  ok.

disconnect(MySession) ->
  exmpp_session:stop(MySession).