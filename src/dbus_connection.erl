%%
%% @copyright 2006-2007 Mikael Magnusson
%% @author Mikael Magnusson <mikma@users.sourceforge.net>
%% @doc
%% Glue module to tcp_conn transport module
%%
%% Messages imlemented by transport modules
%%
%% {received, Conn, Data}
%% {auth_ok, Auth, Sock}

-module(dbus_connection).
-compile([{parse_transform, lager_transform}]).

-behaviour(gen_fsm).

-include("dbus.hrl").

%% api
-export([start_link/1,
	 start_link/2,
	 start_link/3,
	 close/1,
	 auth/1,
	 call/2,
	 cast/2]).

%% gen_fsm callbacks
-export([init/1,
	 code_change/4,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3]).

%% gen_fsm states
-export([connected/3,
	 waiting_initial/3,
	 authenticated/3]).
-export([connected/2,
	 challenged/2,
	 authenticated/2]).

-record(state, {serial   = 0,
		mod,
		sock,
		buf      = <<>>,
		owner,
		state,
		pending           :: term(),  % tid()
		waiting  = []}).

-define(TIMEOUT, 10000).

start_link(BusId) ->
    start_link(BusId, []).

start_link(BusId, Options) ->
    start_link(BusId, Options, self()).

start_link(BusId, Options, Owner) when is_record(BusId, bus_id),
				       is_list(Options),
				       is_pid(Owner) ->
    gen_fsm:start_link(?MODULE, [BusId, Options, Owner], []).

close(Conn) ->
    gen_fsm:send_all_state_event(Conn, close).

-spec call(pid(), term()) -> {ok, term()} | {error, term()}.
call(Conn, Header) ->
    lager:info("connection:call Conn= ~p, Header= ~p", [Conn,Header]),
    {Pid, Header1} = gen_fsm:sync_send_event(Conn, {call, Header}),
    lager:info("connection:call Pid=~p , Header=~p",[Pid, Header1]),
    receive
   	    {authenticated, Pid, Header1} ->
   	        lager:info("connection:call ok"),
   	        {ok, Header1};
   	    {error, Res} ->
   	         lager:info("connection:call error"),
   	         {error, Res}
    after ?TIMEOUT ->
   	    lager:info("connection:call timeout"),
   	    {error, timeout}
    end.	    

-spec cast(pid(), term()) -> ok | {error, term()}.
cast(Conn, Header) ->
    gen_fsm:send_event(Conn, Header).

auth(Conn) ->
    {Pid, Tag} = gen_fsm:sync_send_event(Conn, auth),
    lager:info("connection:auth/1 Pid=~p,Tag=~p",[Pid, Tag]),
    receive
        {authenticated, Pid, Tag} ->
            lager:info("connection:auth/1 ok Pid = ~p, Tag= ~p",[Pid, Tag]),
            {ok, {authenticated, Pid, Tag}};
        {error, Res} ->
            lager:info("connection:auth/1 error"),
            {error, Res}
    end.

%%
%% gen_fsm callbacks
%%
init([#bus_id{scheme=tcp,options=BusOptions}, Options, Owner]) ->
    true = link(Owner),
    {Host, Port} = case {lists:keysearch(host, 1, BusOptions),
			 lists:keysearch(port, 1, BusOptions)} of
		       {{value, {host, Host1}}, {value, {port,Port1}}} ->
			   {Host1, Port1};
		       _ ->
			   throw(no_host_or_port)
		   end,

    {ok, Sock} = dbus_transport_tcp:connect(Host, Port, Options),
    ok = auth(Sock, [{auth, cookie}]),
    {ok, waiting_data, #state{sock=Sock, owner=Owner, pending=ets:new(pending, [private])}};

init([#bus_id{scheme=unix, options=BusOptions}, Options, Owner]) ->
    true = link(Owner),
    {ok, Sock} = dbus_transport_unix:connect(BusOptions, Options),
    %ok = auth(Sock, [{auth, external}]),
    {ok, connected, #state{sock=Sock, owner=Owner, pending=ets:new(pending, [private])}}.


code_change(_OldVsn, _StateName, State, _Extra) ->
    {ok, State}.


handle_sync_event(_Evt, _From, StateName, State) ->
    {reply, ok, StateName, State}.


handle_event(close, _StateName, #state{sock=Sock}=State) ->
    ok = dbus_transport:close(Sock),
    {stop, normal, State#state{sock=undefined}};

handle_event(Evt, StateName, State) ->
    lager:error("Unhandled event: ~p~n", [Evt]),
    {next_state, StateName, State}.

handle_info({received, <<"DATA ", Line/binary>>}, waiting_initial, #state{sock=Sock, waiting=[{Pid, Header}]}=State) ->
    lager:info("handle_info DATA disconnected"),
    {stop, {error, disconnected}, State};

handle_info({received, <<"DATA ", Line/binary>>}, authenticated, #state{sock=Sock, waiting=[{Pid, Header}]}=State) ->
    lager:info("connection:handle_info DATA"),
    Bin = dbus_hex:from(strip_eol(Line)),
    case binary:split(Bin, <<$\ >>, [global]) of
	    [Context, CookieId, ServerChallenge] ->
	        lager:debug("Received authentication data: ~p,~p,~p ~n", [Context, CookieId, ServerChallenge]),
	        case read_cookie(CookieId) of
		        error ->
		            {stop, {error, {no_cookie, CookieId}}, State};
		        {ok, Cookie} ->
		        	Challenge = calc_challenge(),
		            Response = calc_response(ServerChallenge, Challenge, Cookie), 
		            ok = dbus_transport:send(Sock, <<"DATA ", Response/binary, "\r\n">>),
		            Pid ! {authenticated, Pid, Header},
		            {next_state, waiting_ok, State}	            
	        end;
	    _ ->
            {stop, {error, invalid_data}, State}
    end;

handle_info({received, <<"REJECTED ", _Line/binary>>}, StateName, #state{sock=Sock}=State) ->
    lager:info("handle_info REJECTED disconnected"),
    {stop, {error, disconnected}, State};

handle_info({received, <<"OK ", Line/binary>>}, waiting_initial, #state{sock=Sock, waiting=[{Pid, Tag}]}=State) ->
    lager:info("connection:handle_info OK Line = ~p", [Line]),
    Guid = strip_eol(Line),
    lager:debug("GUID ~p~n", [Guid]),    
    ok = dbus_transport:setopts(Sock, [binary, {packet, raw}]),
    ok = dbus_transport:send(Sock, <<"BEGIN \r\n">>),
    Pid ! {authenticated, Pid, Tag},
    {next_state, authenticated, State};
    
handle_info({received, <<"OK ", Line/binary>>}, authenticated, #state{sock=Sock, waiting=[{Pid, Header}]}=State) ->
    lager:info("connection:handle_info OK Line = ~p", [Line]),
    Guid = strip_eol(Line),
    lager:debug("GUID ~p~n", [Guid]),    
    ok = dbus_transport:setopts(Sock, [binary, {packet, raw}]),
    ok = dbus_transport:send(Sock, <<"BEGIN \r\n">>),
    Pid ! {authenticated, Pid, Header},
    {next_state, authenticated, State};

handle_info({received, <<"ERROR", _Line/binary>>}, StateName, #state{sock=Sock}=State) ->
    lager:info("connection:handle_info ERROR disconencted"),
    {stop, {error, disconnected}, State};

handle_info({received, Data}, StateName, #state{buf=Buf}=State) ->
    lager:info("connection:handle_info {recervied,data} Data = ~p, StateName= ~p",[Data,StateName]),
    {ok, Msgs, Rest} = dbus_marshaller:unmarshal_data(<<Buf/binary, Data/binary>>),
    case handle_messages(Msgs, State#state{buf=Rest}) of
	    {ok, State2} ->
	        {next_state, StateName, State2};
	    {error, Err, State2} ->
	        {stop, {error, Err}, State2}
    end;

handle_info(Info, _StateName, State) ->
    lager:error("Unhandled info in: ~p~n", [Info]),
    {stop, {error, unexpected_message}, State}.


terminate(_Reason, _StateName, #state{sock=Sock}) ->
    case Sock of
	    undefined -> ignore;
	    _ -> dbus_connection:close(Sock)
    end,
    terminated.

%%%
%%% gen_fsm states
%%%

connected(auth, {Pid, Tag}, #state{sock=Sock}=State) ->
    case auth(Sock, [{auth, external}]) of
        ok ->
            lager:info("connection:auth_connected ok"),
            {reply, {Pid, Tag}, waiting_initial, State#state{waiting=[{Pid, Tag}]}};
        error ->
            lager:info("connection:auth_connected error"),
            {reply, {error, waiting_initial}, connected, State}
    end;
    

connected(_Evt, _From, State) ->
    lager:info("connection: connected error"),
    {reply, {error, waiting_authentication}, connected, State}.
    
waiting_initial(auth, {Pid, Tag}, #state{sock=Sock}=State) ->
    lager:info("connection:waiting_initial auth"),
    {reply, {Pid, Tag}, waiting_initial, State#state{waiting=[{Pid, Tag}]}};
    
waiting_initial({call, Header}, {Pid, _Tag}, #state{sock=Sock}=State) ->
    lager:info("connection:waiting_initial call"),
    {reply, {Pid, Header}, waiting_initial, State#state{waiting=[{Pid, Header}]}};
    
   
waiting_initial(_Evt, _From, State) ->
    lager:info("connection:waiting_initial error"),
    {reply, {error, waiting_initial}, waiting_initial, State}.
    
authenticated({call, #header{}=Header}, {Pid, _Tag}, #state{sock=Sock, serial=S}=State) ->
    lager:info("connection:authenticated call"),
    {ok, Data} = dbus_marshaller:marshal_message(Header#header{serial=S}),
    ok = dbus_transport:send(Sock, Data),
    {reply, {Pid, Header}, authenticated, State#state{waiting=[{Pid, Header}]}};
    
authenticated(_Evt, _From, State) ->
    lager:info("connection: authenticated error"),
    {reply, {error, authenticated}, authenticated, State}.

connected(Evt, #state{waiting=W}=State) ->
    {next_state, connected, State#state{waiting=[Evt|W]}}.

challenged(Evt, #state{waiting=W}=State) ->
    {next_state, challenged, State#state{waiting=[Evt|W]}}.

authenticated(#header{}=Header, #state{sock=Sock, serial=S}=State) ->
    {ok, Data} = dbus_marshaller:marshal_message(Header#header{serial=S}),
    ok = dbus_transport:send(Sock, Data),
    {noreply, authenticated, State#state{serial=S+1}}.

%%%
%%% Priv
%%%
handle_messages([], State) ->
    {ok, State};
handle_messages([#header{type=Type}=Header | R], State) ->
    case handle_message(Type, Header, State) of
	    {ok, State2} ->
	         handle_messages(R, State2);
	    {error, Err} ->
	        {error, Err}
    end.
handle_message(?TYPE_METHOD_RETURN, Header, #state{pending=Pending}=State) ->
    {_, SerialHdr} = dbus_message:header_fetch(?HEADER_REPLY_SERIAL, Header),
    Serial = SerialHdr#variant.value,
    case ets:lookup(Pending, Serial) of
	    [{Serial, Pid}] ->
	        Pid ! {reply, Header},
	        ets:delete(Pending, Serial),
	        {ok, State};
	    [_] ->
	        lager:debug("Unexpected message: ~p~n", [Serial]),
	        {error, unexpected_message, State}
    end;

handle_message(?TYPE_ERROR, Header, #state{pending=Pending}=State) ->
    {_, SerialHdr} = dbus_message:header_fetch(?HEADER_REPLY_SERIAL, Header),
    Serial = SerialHdr#variant.value,
    case ets:lookup(Pending, Serial) of
	    [{Serial, Pid}] ->
	        Pid ! {error, Header},
	        ets:delete(Pending, Serial),
	        {ok, State};
	    [_] ->
	        lager:debug("Unexpected message: ~p~n", [Serial]),
	        {error, unexpected_message, State}
    end;

handle_message(?TYPE_METHOD_CALL, Header, #state{owner=Owner}=State) ->
    Owner ! {dbus_method_call, Header, self()},
    {ok, State};

handle_message(?TYPE_SIGNAL, Header, #state{owner=Owner}=State) ->
    Owner ! {dbus_signal, Header, self()},
    {ok, State};

handle_message(Type, Header, State) ->
    lager:debug("Ignore ~p ~p~n", [Type, Header]),
    {error, unexpected_message, State}.


flush_waiting(#state{waiting=[]}) ->
    ok;

flush_waiting(#state{sock=Sock, serial=S, waiting=[Header | W]}=State) ->
    {ok, Data} = dbus_marshaller:marshal_message(Header#header{serial=S}),
    ok = dbus_transport:send(Sock, Data),
    flush_waiting(State#state{serial=S+1, waiting=W}).


auth(Sock, Opts) ->
    lager:info("connection: auth/2 ok"),
    User = os:getenv("USER"),
    ok = dbus_transport:send(Sock, <<0>>),
    Auth_type =
	case lists:keysearch(auth, 1, Opts) of
	    {value, {auth, Type}} ->
	        Type;
	    false ->
	        detect
	end,
    AuthBin =
	case Auth_type of
	    external ->
	        lager:info("connection:auth external"),
	        <<"AUTH EXTERNAL 31303030\r\n">>;
	    cookie ->
		    HexUser = dbus_hex:to(User),
		    <<"AUTH DBUS_COOKIE_SHA1 ", HexUser/binary, "\r\n">>;
	    detect ->
	        <<"AUTH\r\n">>
	end,
    dbus_transport:send(Sock, AuthBin).

calc_challenge() ->
    {MegaSecs, Secs, _MicroSecs} = now(),
    UnixTime = MegaSecs * 1000000 + Secs,
    BinTime = integer_to_binary(UnixTime),
    dbus_hex:to(<<"Hello ", BinTime/binary>>).


calc_response(ServerChallenge, Challenge, Cookie) ->
    A1 = ServerChallenge ++ ":" ++ Challenge ++ ":" ++ Cookie,
    lager:debug("A1: ~p~n", [A1]),
    DigestHex = dbus_hex:to(crypto:hash(sha, A1)),
    <<Challenge/binary, " ", DigestHex/binary>>.


read_cookie(CookieId) ->
    Home = os:getenv("HOME"),
    Name = Home ++ "/.dbus-keyrings/org_freedesktop_general",
    {ok, File} = file:open(Name, [read, binary]),
    Result = read_cookie(File, CookieId),
    ok = file:close(File),
    Result.


read_cookie(Device, CookieId) ->
    case io:get_line(Device, "") of
	eof ->
	    error;
	Line ->
	    case binary:split(strip_eol(Line), <<$\ >>, [global]) of
		[CookieId1, _Time, Cookie] ->
		    if
			CookieId == CookieId1 ->
			    {ok, Cookie};
			true ->
			    read_cookie(Device, CookieId)
		    end;
		_ ->
		    error
	    end
    end.

strip_eol(Bin) ->
    strip_eol(Bin, <<>>).

strip_eol(<<>>, Acc) ->
    Acc;
strip_eol(<<$\r, Rest/binary>>, Acc) ->
    strip_eol(Rest, Acc);
strip_eol(<<$\n, Rest/binary>>, Acc) ->
    strip_eol(Rest, Acc);
strip_eol(<<C:8, Rest/binary>>, Acc) ->
    strip_eol(Rest, <<C, Acc/binary>>).
