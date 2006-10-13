-module(dberl.proxy).

-import(dbus).
-import(error_logger).
-import(gen_server).
-import(io).
-import(lists).

-include("dbus.hrl").

-behaviour(gen_server).

%% api
-export([
	 start_link/3,
	 start_link/4,
	 stop/1,
	 interface/2,
	 call/2,
	 call/3,
	 call/4,
	 cast/3
	]).

%% gen_server callbacks
-export([init/1,
	 code_change/3,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2]).

-record(state, {
	  service,
	  path,
	  node,					% #node()
	  bus,					% bus connection
	  waiting
	 }).

start_link(Bus, Service, Path) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [Bus, Service, Path], []),
    case gen_server:call(Pid, proxy_ready) of
	ok ->
	    {ok, Pid};
	{error, Reason} ->
	    throw(Reason)
    end.

start_link(Bus, Service, Path, Node) when is_record(Node, node) ->
    gen_server:start_link(?MODULE, [Bus, Service, Path, Node], []).

stop(Proxy) ->
    gen_server:cast(Proxy, stop).

interface(Proxy, IfaceName) when is_list(IfaceName) ->
    interface(Proxy, list_to_atom(IfaceName));
interface(Proxy, IfaceName) when is_atom(IfaceName) ->
    Iface = {interface, Proxy, IfaceName},
    {ok, Iface}.


call(Interface, MethodName) ->
    call(Interface, MethodName, []).

call(Interface, MethodName, Args) ->
    call(Interface, MethodName, Args, []).

call({interface, Proxy, IfaceName}, MethodName, Args, Options) ->
%%     io:format("before gen_server call ~p~n", [MethodName]),
    case gen_server:call(Proxy, {method, IfaceName, MethodName, Args, Options}) of
	ok ->
	    ok;
	{ok, Result} ->
	    {ok, Result};
	{error, Reason} ->
	    throw(Reason)
    end.


cast({interface, Proxy, IfaceName}, MethodName, Args) ->
    gen_server:cast(Proxy, {method, IfaceName, MethodName, Args}).

%%
%% gen_server callbacks
%%
init([Bus, Service, Path, Node]) ->
%%     io:format("~p ~p: init~n", [?MODULE, ?LINE]),
    {ok, #state{bus=Bus, service=Service, path=Path, node=Node}};

init([Bus, Service, Path]) ->
%%     io:format("~p ~p: init ~p ~p~n", [?MODULE, ?LINE, Service, Path]),
    Header = introspect:build_introspect(Service, Path),
    ok = dbus:call(Bus, Header, introspect),
    {ok, #state{bus=Bus, service=Service, path=Path}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call({method, IfaceName, MethodName, Args, Options}, From, State) ->
    io:format("in gen_server call ~p~n", [MethodName]),

    Method =
	case find_interface(IfaceName, State#state.node) of
	    {ok, Iface} ->
		case find_method(MethodName, Iface) of
		    {ok, Method1} ->
			Method1;
		    error ->
			{error, {'org.freedesktop.DBus.UnknownMethod',  [MethodName]}}
		end;
	    error ->
		{error, {'org.freedesktop.DBus.UnknownInterface',  [IfaceName]}}
	end,

    case Method of
	{error, _}=Error ->
	    {reply, Error, State}; 
	_ ->
	    do_method(IfaceName, Method, Args, Options, From, State)
    end;

handle_call(proxy_ready, From, State) ->
    case State#state.node of
	undefined ->
	    {noreply, State#state{waiting=From}};
	_ ->
	    {reply, ok, State}
    end;
handle_call(Request, _From, State) ->
    error_logger:error_msg("Unhandled call in ~p: ~p~n", [?MODULE, Request]),
    {reply, ok, State}.


handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in ~p: ~p~n", [?MODULE, Request]),
    {noreply, State}.


handle_info({reply, Header, introspect}, State) ->
    Body = Header#header.body,
    [XmlBody] = Body,
    Node = introspect:from_xml_string(XmlBody),
%%     error_logger:info_msg("introspect ~p: ~p~n", [?MODULE, Node]),

    case State#state.waiting of
	undefined ->
	    ignore;
	From ->
	    gen_server:reply(From, ok)
    end,

    {noreply, State#state{node=Node,waiting=undefined}};

handle_info({error, Header, introspect}, State) ->
%%     Body = Header#header.body,
    error_logger:info_msg("Error in introspect ~p: ~n", [?MODULE]),

    [_Type1, ErrorName] = message:header_fetch(?HEADER_ERROR_NAME, Header),
    ErrorName1 = list_to_atom(ErrorName#variant.value),

    case State#state.waiting of
	undefined ->
	    ignore;
	From ->
	    gen_server:reply(From, {error, {ErrorName1, Header#header.body}})
    end,

    {stop, normal, State};

handle_info({reply, Header, {tag, From, Options}}, State) ->
    error_logger:info_msg("Reply ~p: ~p~n", [?MODULE, From]),
    reply(From, {ok, Header}, Options),
    {noreply, State};

handle_info({error, Header, {tag, From, Options}}, State) ->
    error_logger:info_msg("Error ~p: ~p~n", [?MODULE, From]),

    [_Type1, ErrorName] = message:header_fetch(?HEADER_ERROR_NAME, Header),
    ErrorName1 = list_to_atom(ErrorName#variant.value),

    reply(From, {error, {ErrorName1, Header#header.body}}, Options),
    {noreply, State};

handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in ~p: ~p~n", [?MODULE, Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    terminated.

reply(From, Reply, Options) ->
    case lists:keysearch(reply, 1, Options) of
	{value, {reply, Pid, Ref}} ->
	    Pid ! {reply, Ref, Reply};
	_ ->
	    gen_server:reply(From, Reply)
    end,
    ok.

do_method(IfaceName, Method, Args, Options, From, State) ->
    MethodName = Method#method.name,
    Signature = Method#method.in_sig,
    Types = Method#method.in_types,
    error_logger:info_msg("Call ~p: ~p ~p~n", [?MODULE, From, Signature]),
    Service = State#state.service,
    Path = State#state.path,
    Bus = State#state.bus,

    Headers = [
	       [?HEADER_PATH, #variant{type=object_path, value=Path}],
	       [?HEADER_INTERFACE, #variant{type=string, value=IfaceName}],
	       [?HEADER_MEMBER, #variant{type=string, value=MethodName}],
	       [?HEADER_DESTINATION, #variant{type=string, value=Service}],
	       [?HEADER_SIGNATURE, #variant{type=signature, value=Signature}]
	      ],

%%     io:format("before marshal~n"),
    case catch marshaller:marshal_list(Types, Args) of
	{ok, Body, _Pos} ->
	    Header = #header{type=?TYPE_METHOD_CALL,
			     headers=Headers,
			     body=Body},

%% 	    io:format("before call~n"),
	    ok = dbus:call(Bus, Header, {tag, From, Options}),
%% 	    io:format("after call~n"),
	    case lists:keysearch(reply, 1, Options) of
		{value, {reply, _Pid, _Ref}} ->
%% 		    io:format("reply ok~n"),
		    {reply, ok, State};
		_ ->
		    {noreply, State}
	    end;
	{'EXIT', Reason} ->
%% 	    io:format("exit call~n"),
	    {reply, {error, {'org.freedesktop.DBus.InvalidParameters', Reason}}, State}
    end.


fetch_interface(IfaceName, Node) ->
    {ok, Iface} = find_interface(IfaceName, Node),
    Iface.

find_interface(IfaceName, Node) ->
    Fun = fun(E) ->
		  case E of
		      #interface{name=IfaceName} -> true;
		      _ -> false
		  end
	  end,
    case lists:filter(Fun, Node#node.interfaces) of
	[Iface|_] ->
	    {ok, Iface};
	[] ->
	    error
    end.

fetch_method(MethodName, Node) ->
    {ok, Method} = find_method(MethodName, Node),
    Method.

find_method(MethodName, Iface) ->
    Fun = fun(E) ->
		  case E of
		      #method{name=MethodName} -> true;
		      _ -> false
		  end
	  end,
    case lists:filter(Fun, Iface#interface.methods) of
	[Method|_] ->
	    {ok, Method};
	[] ->
	    error
    end.