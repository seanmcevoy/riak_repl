-module(rt_sink_eqc).

-compile(export_all).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


-define(SINK_PORT, 5008).
-define(all_remotes, ["a", "b", "c", "d", "e"]).

-record(state, {
    remotes_available = ?all_remotes,
    sources = [],
    rtq = []
    }).

-record(src_state, {
    pids,
    version,
    done_fun_queue = []
    }).

-record(fake_source, {
    socket,
    clustername,
    version,
    seq = 1,
    skips = 0,
    tcp_bug = undefined
    }).

-record(push_result, {
    rtq_res,
    donefun,
    binary,
    already_routed
}).

prop_test_() ->
    {timeout, 60000, fun() ->
        ?assert(eqc:quickcheck(eqc:numtests(10, ?MODULE:prop_main())))
    end}.

prop_main() ->
    ?FORALL(Cmds, commands(?MODULE),
        aggregate(command_names(Cmds), begin
            {H, S, Res} = run_commands(?MODULE, Cmds),
            Out = pretty_commands(?MODULE, Cmds, {H,S,Res}, Res == ok),
            teardown(),
            unload_mecks(),
            Out
        end)).

unload_mecks() ->
    riak_repl_test_util:maybe_unload_mecks([
        riak_core_ring_manager, riak_core_ring, riak_repl2_rt,
        riak_repl2_rtsink_helper, gen_tcp, fake_source, riak_repl2_rtq,
        riak_repl2_rt_spanning_coord]).

%% ====================================================================
%% Generators (including commands)
%% ====================================================================

command(S) ->
    frequency(
        [{1, {call, ?MODULE, connect_from_v1, [remote_name(S)]}} || S#state.remotes_available /= []] ++
        [{1, {call, ?MODULE, connect_from_v2, [remote_name(S)]}} || S#state.remotes_available /= []] ++
        [{1, {call, ?MODULE, connect_from_v2_2, [remote_name(S)]}} || S#state.remotes_available /= []] ++
        [{2, {call, ?MODULE, disconnect, [elements(S#state.sources)]}} || S#state.sources /= []] ++
        [{5, {call, ?MODULE, source_push_spanning, [elements(S#state.sources), elements(S#state.sources), elements(S#state.sources), g_connected(), int(), g_routed_list()]}} || length(S#state.sources) > 1] ++
        [{5, {call, ?MODULE, sink_push_spanning, [elements(S#state.sources), elements(S#state.sources), elements(S#state.sources), g_connected(), int(), g_routed_list()]}} || length(S#state.sources) > 1] ++
        [{5, {call, ?MODULE, push_object, [elements(S#state.sources), g_riak_object(), g_unique(["sink_cluster" | ?all_remotes])]}} || S#state.sources /= []] ++
        [{3, {call, ?MODULE, call_donefun, ?LET({Remote, Source}, elements(S#state.sources),[{Remote, Source}, g_donefun(Source#src_state.done_fun_queue)])}} || S#state.sources /= []]
        ).

g_riak_object() ->
    ?LET({Bucket, Key, Content}, {binary(), binary(), binary()}, riak_object:new(Bucket, Key, Content)).

g_donefun([]) ->
    empty;
g_donefun(DoneFuns) ->
    Max = length(DoneFuns),
    choose(1, Max).

g_unique(Possibilites) ->
    ?LET(List, list(elements(Possibilites)), lists:usort(List)).

g_connected() ->
    oneof([connect, disconnect, disconnect_all]).

g_routed_list() ->
    g_unique(["sink_cluster" | ?all_remotes]).

remote_name(#state{remotes_available = []}) ->
    erlang:error(no_name_available);
remote_name(#state{remotes_available = Remotes}) ->
    oneof(Remotes).

precondition(_S, {call, _, call_donefun, [_Src, empty]}) ->
    false;
precondition(_S, {call, _, call_donefun, [{_Remote, Src}, Nth]}) ->
    case lists:nth(Nth, Src#src_state.done_fun_queue) of
        called ->
            false;
        _ ->
            true
    end;
precondition(#state{sources = []}, {call, _, disconnect, _Args}) ->
    false;
precondition(#state{sources = Sources}, {call, _, disconnect, [{Remote, _}]}) ->
    is_tuple(lists:keyfind(Remote, 1, Sources));
precondition(S, {call, _, push_object, _Args}) ->
    S#state.sources /= [];
precondition(S, {call, _, source_push_spanning, [_Using, {Name, _SrcState}, {Name, _SrcState}, _Connect, _Vsn, _RouteList]}) ->
    false;
precondition(S, {call, _, sink_push_spanning, [_Using, {Name, _SrcState}, {Name, _SrcState2}, _Conect, _VSn, _RouteList]}) ->
    false;
precondition(S, {call, _, Connect, [Remote]}) when Connect == connect_from_v1; Connect == connect_from_v2; Connect == connect_from_v2_2 ->
    lists:member(Remote, S#state.remotes_available);
precondition(S, {call, _, Connect, [#src_state{done_fun_queue = []}, _]}) ->
    false;
precondition(_S, _Call) ->
    true.

%% ====================================================================
%% state generation
%% ====================================================================

initial_state() ->
    teardown(),
    setup(),
    #state{}.

teardown() ->
    % we will be resetting many mecks, which link to this, but we don't
    % want to kill our test process.
    process_flag(trap_exit, true),
    % read out messages that may be left over from a previous run
%    read_all_rt_bugs(),
%    read_all_fake_rtq_bugs(),
    % murder and restore all processes/mecks
    stateful:stop(),
    riak_repl_test_util:kill_and_wait(riak_repl2_rt),
    riak_repl_test_util:kill_and_wait(riak_core_service_manager),
    riak_repl_test_util:kill_and_wait(riak_repl2_rtsink_conn_sup, kill),
    riak_repl2_rtsink_conn_sup:start_link(),
    riak_repl_test_util:kill_and_wait(riak_core_tcp_mon).

setup() ->
    riak_core_tcp_mon:start_link(),
    stateful:reset(),
    stateful:set(base_test_pid, self()),
    abstract_ring_manager(),
    abstract_ranch(),
    abstract_rtsink_helper(),
    abstract_spanning_coord(),
    riak_repl_test_util:abstract_gen_tcp(),
    bug_rt(),
    start_service_manager(),
    riak_repl2_rtsink_conn:register_service(),
    abstract_fake_source(),
    abstract_source_conn_sup(),
    start_fake_rtq().

next_state(S, Res, {call, _, connect_from_v1, [Remote]}) ->
    SrcState = #src_state{pids = Res, version = {1,0}},
    next_state_connect(Remote, SrcState, S);

next_state(S, Res, {call, _, connect_from_v2, [Remote]}) ->
    SrcState = #src_state{pids = Res, version = {2,0}},
    next_state_connect(Remote, SrcState, S);

next_state(S, Res, {call, _, connect_from_v2_2, [Remote]}) ->
    SrcState = #src_state{pids = Res, version = {2,2}},
    next_state_connect(Remote, SrcState, S);

next_state(S, _Res, {call, _, disconnect, [{Remote, _}]}) ->
    Sources2 = lists:keydelete(Remote, 1, S#state.sources),
    Avails = [Remote | S#state.remotes_available],
    S#state{sources = Sources2, remotes_available = Avails};

next_state(S, Res, {call, _, push_object, [{Remote, SrcState}, _RiakObj, PreviouslyRouted]}) ->
    case SrcState#src_state.version of
        {1,_} ->
            DoneQueue2 = SrcState#src_state.done_fun_queue ++ [{call, ?MODULE, extract_queue_object, [Res]}],
            SrcState2 = SrcState#src_state{done_fun_queue = DoneQueue2},
            Sources2 = lists:keystore(Remote, 1, S#state.sources, {Remote, SrcState2}),
            S#state{sources = Sources2};
        {2,_} ->
            case lists:member(Remote, PreviouslyRouted) of
                true ->
                    S;
                false ->
                    DoneQueue2 = SrcState#src_state.done_fun_queue ++ [{call, ?MODULE, extract_queue_object, [Res]}],
                    SrcState2 = SrcState#src_state{done_fun_queue = DoneQueue2},
                    Sources2 = lists:keystore(Remote, 1, S#state.sources, {Remote, SrcState2}),
                    S#state{sources = Sources2}
            end
    end;

next_state(S, _Res, {call, _, call_donefun, [{_Remote, #src_state{done_fun_queue = []}}, empty]}) ->
    S;
next_state(S, _Res, {call, _, call_donefun, [{Remote, SrcState}, DoneFunN]}) ->
    case lists:nth(DoneFunN, SrcState#src_state.done_fun_queue) of
        called ->
            S;
        _ ->
            {Head, [_Nix | Tail]} = lists:split(DoneFunN - 1, SrcState#src_state.done_fun_queue),
            DoneFun2 = Head ++ [called] ++ Tail,
            SrcState2 = SrcState#src_state{done_fun_queue = DoneFun2},
            Sources2 = lists:keystore(Remote, 1, S#state.sources, {Remote, SrcState2}),
            S#state{sources = Sources2}
    end;

next_state(S, _Res, {call, _, source_push_spanning, _Args}) ->
    S;

next_state(S, _Res, {call, _, sink_push_spanning, _Args}) ->
    S.

next_state_connect(Remote, SrcState, State) ->
    Sources = State#state.sources,
    Sources2 = lists:keystore(Remote, 1, Sources, {Remote, SrcState}),
    Avails = lists:delete(Remote, State#state.remotes_available),
    State#state{sources = Sources2, remotes_available = Avails}.

extract_queue_object(PushResult) ->
    #push_result{donefun = {ok, DoneFun}, already_routed = AlreadyRouted, binary = RiakObj} = PushResult,
    {DoneFun, RiakObj, AlreadyRouted}.

%% ====================================================================
%% postcondition
%% ====================================================================

postcondition(_S, {call, _, connect_from_v1, [_Remote]}, {error, _Reses}) ->
    false;
postcondition(_S, {call, _, connect_from_v1, [_Remote]}, {Source, Sink}) ->
    Out = is_pid(Source) andalso is_pid(Sink),
    case Out of
        true ->
            ok;
        _ ->
            ok
    end,
    Out;
postcondition(_S, {call, _, connect_from_v2, [_Remote]}, {error, _Reses}) ->
    false;
postcondition(_S, {call, _, connect_from_v2, [_Remote]}, {Source, Sink}) ->
    Out = is_pid(Source) andalso is_pid(Sink),
    case Out of
        true ->
            ok;
        _ ->
            ok
    end,
    Out;
postcondition(_S, {call, _, connect_from_v2_2, [_Remote]}, {error, _Reses}) ->
    false;
postcondition(_S, {call, _, connect_from_v2_2, [_Remote]}, {Source, Sink}) ->
    if
        is_pid(Source) andalso is_pid(Sink) ->
            Lives = is_process_alive(Source) andalso is_process_alive(Sink),
            if
                Lives ->
                    true;
                true ->
                    ?debugFmt("Either Source or sink is dead:~n"
                        "    Source: ~p~n"
                        "    Sink: ~p", [is_process_alive(Source), is_process_alive(Sink)]),
                    false
            end;
        true ->
            ?debugFmt("Either source or sink is not a pid:~n"
                "    Source: ~p~n"
                "    Sink: ~p", [Source, Sink]),
            false
    end;

postcondition(_S, {call, _, disconnect, [_Remote]}, {Source, Sink}) ->
    Out = not ( is_process_alive(Source) orelse is_process_alive(Sink) ),
    case Out of
        true ->
            ok;
        _ ->
            ok
    end,
    Out;

postcondition(_S, {call, _, push_object, [{_Remote, #src_state{version = {1,_}} = SrcState}, _RiakObj, _AlreadyRouted]}, Reses) ->
    #push_result{rtq_res = RTQRes, donefun = HelperRes} = Reses,
    case RTQRes of
        {error, timeout} ->
            case HelperRes of
                {ok, _Other} ->
                    {Source, Sink} = SrcState#src_state.pids,
                    is_process_alive(Source) andalso is_process_alive(Sink);
                _HelperWhat ->
                    false
            end;
        _QWhat ->
            false
    end;
postcondition(S, {call, _, push_object, [{Remote, #src_state{version = {2,_}} = SrcState}, RiakObj, AlreadyRouted]}, Res) ->
    RTQRes = Res#push_result.rtq_res,
    HelperRes = Res#push_result.donefun,
    Routed = lists:member(Remote, Res#push_result.already_routed),
    case {Routed, RTQRes, HelperRes} of
        {true, {error, timeout}, {error, timeout}} ->
            true;
        {false, {error, timeout}, {ok, _DoneFun}} ->
            true;
        _ ->
            false
    end;
postcondition(_S, {call, _, push_object, _Args}, {error, _What}) ->
    false;
postcondition(S, {call, _, source_push_spanning, [{Using,_}, {FromCluster, _}, {ToCluster, _}, _Connect, _Vsn, _Routed]}, {error, too_old}) ->
    {Using, RealUsing} = lists:keyfind(Using, 1, S#state.sources),
    % it's okay, we wouldn't expect it anyway for older versions
    RealUsing#src_state.version < {2,2};
postcondition(S, {call, _, source_push_spanning, [Using, {FromCluster, _}, {ToCluster, _}, Connect, Vsn, Routed]}, Res) ->
    Expected = case Connect of
        disconnect_all ->
            {FromCluster, undefined, Connect, Vsn, Routed};
        _ ->
            {FromCluster, ToCluster, Connect, Vsn, Routed}
    end,
    case Res of
        Expected ->
            true;
        _ ->
            ?debugFmt("source_push_spanning failed~n"
                "    Using: ~p~n"
                "    Expected: ~p~n"
                "    Res: ~p", [Using, Expected, Res]),
            false
    end;
postcondition(S, {call, _, sink_push_spanning, [{Using,_}, {FromCluster, _}, {ToCluster, _}, Connect, Vsn, Routed]}, Res) ->
    {Using, RealUsing} = lists:keyfind(Using, 1, S#state.sources),
    case {Res, RealUsing#src_state.version} of
        {{error, timeout}, SrcVsn} when SrcVsn < {2,2} ->
            true;
        {{ok, Binary}, SrcVsn} when SrcVsn >= {2,2} ->
            {ok, Frame, _Cont} = riak_repl2_rtframe:decode(Binary),
            Expected = {spanning_update, {FromCluster, ToCluster, Connect, Vsn, Routed}},
            case Frame of
                Expected ->
                    true;
                _ ->
                    ?debugFmt("Got Frame does not match expected~n"
                        "    Frame: ~p~n"
                        "    Expected: ~p", [Frame, Expected]),
                    false
            end;
        _ ->
            ?debugFmt("Result did not meet any expectation~n"
                "    Res: ~p~n"
                "    RealUsing (version): ~p", [Res, RealUsing#src_state.version]),
            false
    end;
postcondition(_S, {call, _, call_donefun, [{_Remote, #src_state{done_fun_queue = []}}, _NthDoneFun]}, {ok, empty}) ->
    true;
postcondition(_S, {call, _, call_donefun, [{Remote, SrcState}, NthDoneFun]}, Res) ->
    DoneFun = lists:nth(NthDoneFun, SrcState#src_state.done_fun_queue),
    case DoneFun of
        called ->
            true;
        {_DoneFun, RiakObj, AlreadyRouted} ->
            PreviousDones = lists:sublist(SrcState#src_state.done_fun_queue, NthDoneFun - 1),
            Version = SrcState#src_state.version,
            Binary = riak_repl_util:to_wire(w1, [RiakObj]),
            AllCalled = lists:all(fun(called) -> true; (_) -> false end, PreviousDones),
            case {Version, Res} of
                {{2,_}, {{ok, {push, _NumItems, Binary, Meta}}, {ok, TcpBin}}} when AllCalled ->
                    Routed = orddict:fetch(routed_clusters, Meta),
                    Got = ordsets:from_list(Routed),
                    Expected = ordsets:from_list([Remote | AlreadyRouted]),
                    Frame = riak_repl2_rtframe:decode(TcpBin),
                    case {Got, Frame} of
                        {Expected, {ok, {ack, _SomeSeq}, <<>>}} ->
                            true;
                        _ ->
                            false
                    end;
                {{2,_}, {{ok, {push, _NumItems, Binary, Meta}}, {error, timeout}}} ->
                    Routed = orddict:fetch(routed_clusters, Meta),
                    Got = ordsets:from_list(Routed),
                    Expected = ordsets:from_list([Remote | AlreadyRouted]),
                    Got =:= Expected;
                {{1,_}, {{error, timeout}, {ok, TCPBin}}} when AllCalled ->
                    case riak_repl2_rtframe:decode(TCPBin) of
                        {ok, {ack, _SomeSeq}, <<>>} ->
                            true;
                        FrameDecode ->
                            false
                    end;
                {{1,_}, {{error, timeout}, {error, timeout}}} ->
                    true;
                _ ->
                    ?debugFmt("No valid returns on call_donefun~n"
                        "    DoneFun: ~p~n"
                        "    NthDoneFun: ~p~n"
                        "    AllCalled: ~p~n"
                        "    Res: ~p~n"
                        "    Remote: ~p~n"
                        "    SrcState ~p~n", [DoneFun, NthDoneFun, AllCalled, Res, Remote, SrcState]),
                    false
            end
    end;

postcondition(_S, _C, _R) ->
    ?debugMsg("Fall through post condition"),
    true.

%% ====================================================================
%% test callbacks
%% ====================================================================

connect_from_v1(Remote) ->
    connect_from({1,0}, Remote).

connect_from_v2(Remote) ->
    connect_from({2,0}, Remote).

connect_from_v2_2(Remote) ->
    connect_from({2,2}, Remote).

connect_from(Version, Remote) ->
    case connect_source(Version, Remote) of
        {ok, {SourcePid, SinkPid}} ->
            {SourcePid, SinkPid};
        Else ->
            Else
    end.

disconnect({_Remote, State}) ->
    {Source, Sink} = State#src_state.pids,
    riak_repl_test_util:kill_and_wait(Source),
    riak_repl_test_util:wait_for_pid(Sink),
    {Source, Sink}.

push_object({_Remote, #src_state{version = {2,_}} = SrcState}, RiakObj, AlreadyRouted) ->
    {Source, _Sink} = SrcState#src_state.pids,
    ok = fake_source_push_obj(Source, RiakObj, AlreadyRouted),
    RTQRes = read_fake_rtq_bug(),
    HelperRes = read_rtsink_helper_donefun(),
    #push_result{rtq_res = RTQRes, donefun = HelperRes, binary = RiakObj, already_routed = AlreadyRouted};

push_object({_Remote, SrcState}, Binary, AlreadyRouted) ->
    {Source, _Sink} = SrcState#src_state.pids,
    ok = fake_source_push_obj(Source, Binary, AlreadyRouted),
    RTQRes = read_fake_rtq_bug(),
    HelperRes = read_rtsink_helper_donefun(),
    #push_result{rtq_res = RTQRes, donefun = HelperRes, binary = Binary, already_routed = AlreadyRouted}.

source_push_spanning(Using, From, To, Connect, Vsn, Routed) ->
    {_Name, #src_state{pids = {UsingPid, _}}} = Using,
    {FromName, _} = From,
    {ToName, _} = To,
    Stateful1 = fake_source_source_push_spanning(UsingPid, FromName, ToName, Connect, Vsn, Routed),
    stateful:set(last_spanning, Stateful1),
    % TODO change to use non-hard coded wait
    timer:sleep(10),
    stateful:get(last_spanning).

sink_push_spanning(Using, From, To, Connect, Vsn, Routed) ->
    {_Name, #src_state{pids = {SrcPid, SinkPid}}} = Using,
    {FromName, _} = From,
    {ToName, _} = To,
    riak_repl2_rtsink_conn:spanning_update(FromName, ToName, Connect, Vsn, Routed, SinkPid),
    fake_source_tcp_bug(SrcPid).

call_donefun({_Remote, #src_state{done_fun_queue = []}}, empty) ->
    {ok, empty};
call_donefun({_Remote, SrcState}, NthDoneFun) ->
    {DoneFun, _Bin, _AlreadyRouted} = lists:nth(NthDoneFun, SrcState#src_state.done_fun_queue),
    DoneFun(),
    {Source, _Sink} = SrcState#src_state.pids,
    AckRes = fake_source_tcp_bug(Source),
    RTQRes = read_fake_rtq_bug(),
    {RTQRes,AckRes}.

%% ====================================================================
%% helpful utility functions
%% ====================================================================

abstract_ranch() ->
    riak_repl_test_util:reset_meck(ranch, [no_link]),
    meck:expect(ranch, accept_ack, fun(_Listener) -> ok end),
    meck:expect(ranch, start_listener, fun(_IpPort, _MaxListeners, _RanchTCP, RanchOpts, _Module, _SubProtos) ->
        riak_repl_test_util:kill_and_wait(sink_listener),
        %?debugMsg("ranch start listener"),
        IP = proplists:get_value(ip, RanchOpts),
        Port = proplists:get_value(port, RanchOpts),
        Pid = proc_lib:spawn_link(?MODULE, sink_listener, [IP, Port, RanchOpts]),
        register(sink_listener, Pid),
        {ok, Pid}
    end).

abstract_ring_manager() ->
    riak_repl_test_util:reset_meck(riak_core_ring_manager, [no_link, passthrough]),
    meck:expect(riak_core_ring_manager, get_my_ring, fun() ->
        {ok, fake_ring}
    end),
    riak_repl_test_util:reset_meck(riak_core_ring, [no_link, passthrough]),
    meck:expect(riak_core_ring, get_meta, fun
        (symbolic_clustername, fake_ring) ->
            Self = self(),
            case stateful:get(base_test_pid) of
                Self ->
                    {ok, stateful:get(current_clustername)};
                Other ->
                    {ok, "sink_cluster"}
            end;
        (_Key, fake_ring) ->
            undefined;
        (Key, Ring) ->
            meck:passthrough([Key, Ring])
    end).

abstract_rtsink_helper() ->
    riak_repl_test_util:reset_meck(riak_repl2_rtsink_helper, [no_link]),
    ReturnTo = self(),
    meck:expect(riak_repl2_rtsink_helper, start_link, fun(_Parent) ->
        {ok, sink_helper}
    end),
    meck:expect(riak_repl2_rtsink_helper, stop, fun(sink_helper) ->
        ok
    end),
    meck:expect(riak_repl2_rtsink_helper, write_objects, fun(sink_helper, _BinObjs, DoneFun, _Ver) ->
        ReturnTo ! {rtsink_helper, done_fun, DoneFun},
        ok
    end).

abstract_source_conn_sup() ->
    riak_repl_test_util:reset_meck(riak_repl2_rtsource_conn_sup, [no_link]),
    meck:expect(riak_repl2_rtsource_conn_sup, enabled, fun() -> [] end).

abstract_spanning_coord() ->
    riak_repl_test_util:reset_meck(riak_repl2_rt_spanning_coord, [no_link]),
    Self = self(),
    meck:expect(riak_repl2_rt_spanning_coord, continue_chain, fun(From, To, Action, Vsn, Routed) ->
        stateful:set(last_spanning, {From, To, Action, Vsn, Routed}),
        ok
    end).

read_rtsink_helper_donefun() ->
    read_rtsink_helper_donefun(3000).

read_rtsink_helper_donefun(Timeout) ->
    receive
        {rtsink_helper, done_fun, DoneFun} ->
            {ok, DoneFun}
    after Timeout ->
        {error, timeout}
    end.

sink_listener(Ip, Port, Opts) ->
    {ok, Sock} = gen_tcp:listen(Port, [{ip, Ip}, binary, {reuseaddr, true}, {active, false} | Opts]),
    sink_listener(Sock).

sink_listener(ListenSock) ->
    {ok, Socket} = gen_tcp:accept(ListenSock),
    %?debugMsg("post accept"),
    {ok, Pid} = riak_core_service_mgr:start_link(sink_listener, Socket, gen_tcp, []),
    gen_tcp:controlling_process(Socket, Pid),
    sink_listener(ListenSock).

wait_for_sink_pid() ->
    wait_for_sink_pid(3000).

wait_for_sink_pid(Timeout) ->
    receive
        {sink_pid, Pid, Socket} ->
            ?debugMsg("got sink pid"),
            {ok, {Pid, Socket}}
    after Timeout ->
        ?debugMsg("sink pid wait timed out"),
        {error, timeout}
    end.

bug_rt() ->
    riak_repl_test_util:reset_meck(riak_repl2_rt, [no_link, passthrough]),
    WhoToTell = self(),
    meck:expect(riak_repl2_rt, register_sink, fun(SinkPid) ->
        WhoToTell ! {sink_pid, SinkPid},
        meck:passthrough([SinkPid])
    end),
    riak_repl_test_util:kill_and_wait(riak_repl2_rt),
    riak_repl2_rt:start_link().

read_rt_bug() ->
    read_rt_bug(3000).

read_rt_bug(Timeout) ->
    receive
        {sink_pid, Pid} ->
            {ok, Pid}
    after Timeout ->
        {error, timeout}
    end.

read_all_rt_bugs() ->
    LastRead = read_rt_bug(0),
    read_all_rt_bugs(LastRead).

read_all_rt_bugs({error, timeout}) ->
    ok;
read_all_rt_bugs(_PreviousRead) ->
    read_all_rt_bugs(read_rt_bug(0)).

start_service_manager() ->
    riak_repl_test_util:kill_and_wait(riak_core_service_manager),
    riak_core_service_mgr:start_link({"127.0.0.1", ?SINK_PORT}).

abstract_fake_source() ->
    riak_repl_test_util:reset_meck(fake_source, [no_link, non_strict]),
    meck:expect(fake_source, connected, fun(Socket, Transport, Endpoint, Proto, Pid, Props) ->
        Transport:controlling_process(Socket, Pid),
        gen_server:call(Pid, {connected, Socket, Endpoint, Proto})
    end).

start_fake_rtq() ->
    WhoToTell = self(),
    riak_repl_test_util:kill_and_wait(fake_rtq),
    riak_repl_test_util:reset_meck(riak_repl2_rtq, [no_link, passthrough]),
    Pid = proc_lib:spawn_link(?MODULE, fake_rtq, [WhoToTell]),
    register(fake_rtq, Pid),
    meck:expect(riak_repl2_rtq, push, fun(NumItems, Bin, Meta) ->
        gen_server:cast(fake_rtq, {push, NumItems, Bin, Meta})
    end),
    {ok, Pid}.

fake_rtq(Bug) ->
    fake_rtq(Bug, []).

fake_rtq(Bug, Queue) ->
    receive
        {'$gen_cast', {push, NumItems, Bin, Meta} = Got} ->
            Bug ! Got,
            Queue2 = [{NumItems, Bin, Meta} | Queue],
            fake_rtq(Bug, Queue2);
        Else ->
            ok
    end.

read_fake_rtq_bug() ->
    read_fake_rtq_bug(5000).

read_fake_rtq_bug(Timeout) ->
    receive
        {push, _NumItems, _Bin, _Metas} = Got ->
            {ok, Got}
    after Timeout ->
        {error, timeout}
    end.

read_all_fake_rtq_bugs() ->
    read_all_fake_rtq_bugs(read_fake_rtq_bug(0)).

read_all_fake_rtq_bugs({error, timeout}) ->
    ok;
read_all_fake_rtq_bugs(_) ->
    read_all_fake_rtq_bugs(read_fake_rtq_bug(0)).

connect_source(Version, Remote) ->
    stateful:set(current_clustername, Remote),
    bug_rt(),
    Pid = proc_lib:spawn_link(?MODULE, fake_source_loop, [undefined, Version, Remote]),
    TcpOptions = [{keepalive, true}, {nodelay, true}, {packet, 0},
        {active, false}],
    ClientSpec = {{realtime, [Version]}, {TcpOptions, fake_source, Pid}},
    IpPort = {{127,0,0,1}, ?SINK_PORT},
    ConnRes = riak_core_connection:sync_connect(IpPort, ClientSpec),
    ok = fake_source_wait_connected(Pid),
    case read_rt_bug() of
        {ok, Sink} ->
            % wait for the socket to get set
            timer:sleep(100),
            {ok, {Pid, Sink}};
        {error, timeout} ->
            {error, sink_timeout}
    end.

fake_source_push_obj(Source, Binary, AlreadyRouted) ->
    gen_server:call(Source, {push, Binary, AlreadyRouted}).

fake_source_source_push_spanning(Source, From, To, disconnect_all, Vsn, Routed) when To =/= undefined ->
    fake_source_source_push_spanning(Source, From, undefined, disconnect_all, Vsn, Routed);

fake_source_source_push_spanning(Source, From, To, Connect, Vsn, Routed) ->
    Msg = {spanning_update, From, To, Connect, Vsn, Routed},
    try gen_server:call(Source, Msg) of
        Res -> Res
    catch
        exit:{timeout,_} ->
            {error, timeout};
        exit:{function_clause,_} ->
            {error, function_clause}
    end.

fake_source_tcp_bug(Source) ->
    try gen_server:call(Source, bug) of
        Res -> Res
    catch
        exit:{timeout, _} ->
            {error, timeout}
    end.

fake_source_wait_connected(Pid) ->
    gen_server:call(Pid, waiting_connected).

fake_source_loop(undefined, Version, Cluster) ->
    State = #fake_source{version = Version, clustername = Cluster},
    fake_source_loop(State).

fake_source_loop(#fake_source{socket = undefined} = State) ->
    #fake_source{version = Version} = State,
    {Major, _Minor} = Version,
    receive
        {'$gen_call', From, {connected, Socket, _EndPoint, {realtime, {Major,_}, {Major,_}}}} ->
            inet:setopts(Socket, [{active, once}]),
            gen_server:reply(From, ok),
            case State#fake_source.socket of
                undefined ->
                    ok;
                F ->
                    gen_server:reply(From, ok)
            end,
            fake_source_loop(State#fake_source{socket = Socket});
        {'$gen_call', From, waiting_connected} ->
            fake_source_loop(State#fake_source{socket = From});
        {'$gen_call', From, Aroo} ->
            gen_server:reply(From, {error, badcall}),
            ?debugFmt("Fake Source ~p exiting due to bad call from ~p: ~p", [self(), From, Aroo]),
            exit({badcall, Aroo});
        What ->
            fake_source_loop(State)
    end;
fake_source_loop(State) ->
    receive
        {'$gen_call', From, waiting_connected} ->
            gen_server:reply(From, ok),
            fake_source_loop(State);
        {'$gen_call', From, {push, RiakObj, _AlreadyRouted}} when State#fake_source.version == {1,0} ->
            #fake_source{socket = Socket, seq = Seq} = State,
            Binary = riak_repl_util:to_wire(w0, [RiakObj]),
            Payload = riak_repl2_rtframe:encode(objects, {Seq, Binary}),
            gen_tcp:send(Socket, Payload),
            gen_server:reply(From, ok),
            fake_source_loop(State#fake_source{seq = Seq + 1});
        {'$gen_call', From, {push, RiakObj, AlreadyRouted}} when State#fake_source.version >= {2,0} ->
            #fake_source{seq = Seq, clustername = ClusterName} = State,
            Skips2 = case lists:member(ClusterName, AlreadyRouted) of
                true ->
                    State#fake_source.skips + 1;
                false ->
                    Socket = State#fake_source.socket,
                    Meta = orddict:from_list([{skip_count, State#fake_source.skips}, {routed_clusters, [ClusterName | AlreadyRouted]}]),
                    Binary = riak_repl_util:to_wire(w1, [RiakObj]),
                    Payload = riak_repl2_rtframe:encode(objects_and_meta, {Seq, Binary, Meta}),
                    gen_tcp:send(Socket, Payload),
                    0
            end,
            gen_server:reply(From, ok),
            fake_source_loop(State#fake_source{seq = Seq + 1, skips = Skips2});
        {'$gen_call', From, {spanning_update, _FromName, _ToName, _Connect, _Vsn, _Routed}} when State#fake_source.version < {2,2} ->
            gen_server:reply(From, {error, too_old}),
            fake_source_loop(State);
        {'$gen_call', From, {spanning_update, FromName, ToName, Connect, Vsn, Routed}} ->
            Payload = riak_repl2_rtframe:encode(spanning_update, {FromName, ToName, Connect, Vsn, Routed}),
            gen_tcp:send(State#fake_source.socket, Payload),
            gen_server:reply(From, ok),
            fake_source_loop(State);
        {'$gen_call', From, bug} ->
            NewBug = case State#fake_source.tcp_bug of
                {data, Bin} ->
                    gen_server:reply(From, {ok, Bin}),
                    undefined;
                _ ->
                    {bug, From}
            end,
            fake_source_loop(State#fake_source{tcp_bug = NewBug});
        {'$gen_call', From, Aroo} ->
            gen_server:reply(From, {error, badcall}),
            ?debugFmt("Fake Source ~p exiting due to bad call from ~p: ~p", [self(), From, Aroo]),
            exit({badcall, Aroo});
        {tcp, Socket, Bin} ->
            %?debugFmt("tcp nom: ~p", [Bin]),
            #fake_source{socket = Socket} = State,
            inet:setopts(Socket, [{active, once}]),
            NewBug = case State#fake_source.tcp_bug of
                {bug, From} ->
                    gen_server:reply(From, {ok, Bin}),
                    undefined;
                _ ->
                    {data, Bin}
            end,
            fake_source_loop(State#fake_source{tcp_bug = NewBug});
        {tcp_closed, Socket} when Socket == State#fake_source.socket ->
            ok;
        What ->
            fake_source_loop(State)
    end.

-endif.
-endif. % EQC
