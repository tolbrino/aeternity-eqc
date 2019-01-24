%%% @author Thomas Arts <thomas@SpaceGrey.lan>
%%% @copyright (C) 2019, Thomas Arts
%%% @doc
%%%
%%%      Start a second epoch node with old code using something like:
%%%            ./rebar3 as test shell --sname oldepoch@localhost --apps ""
%%%            we need the test profile to assure that the cookie is set to aeternity_cookie
%%%            The test profile has a name and a cookie set in {dist_node, ...}
%%% @end
%%% Created : 23 Jan 2019 by Thomas Arts <thomas@SpaceGrey.lan>

-module(tx_primops_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-compile([export_all, nowarn_export_all]).
-define(REMOTE_NODE, 'oldepoch@localhost').
-define(Patron, <<1, 1, 0:240>>).

-record(account, {key, amount, nonce, name}).

%% -- State and state functions ----------------------------------------------
initial_state() ->
    #{accounts => []}.

%% -- Generators -------------------------------------------------------------

%% -- Common pre-/post-conditions --------------------------------------------
command_precondition_common(_S, _Cmd) ->
    true.

precondition_common(_S, _Call) ->
    true.

postcondition_common(_S, _Call, _Res) ->
    true.

%% -- Operations -------------------------------------------------------------

%% --- Operation: init ---
init_pre(S) ->
    not maps:is_key(trees, S).

init_args(_S) ->
    [aetx_env:tx_env(0, 1)].

init(_) ->
    Trees = rpc(aec_trees, new_without_backend, [], fun hash_equal/2),
    EmptyAccountTree = rpc(aec_trees, accounts, [Trees]),
    Account = rpc(aec_accounts, new, [?Patron, 1200000]), 
    AccountTree = rpc(aec_accounts_trees, enter, [Account, EmptyAccountTree]),
    InitialTrees = rpc(aec_trees, set_accounts, [Trees, AccountTree], fun hash_equal/2),
    put(trees, InitialTrees),
    InitialTrees.

init_next(S, _Value, [TxEnv]) ->
    S#{trees => init, 
       tx_env => TxEnv, 
       accounts => [#account{key = ?Patron, amount = 1200000, nonce = 1, name = "patron"}]}.

%% --- Operation: mine ---
mine_pre(S) ->
    maps:is_key(trees, S).

mine_args(#{tx_env := TxEnv}) ->
    Height = aetx_env:height(TxEnv),
    [Height].

mine_pre(#{tx_env := TxEnv}, [H]) ->
    aetx_env:height(TxEnv) == H.

mine(Height) ->
    Trees = get(trees),
    NewTrees = rpc(aec_trees, perform_pre_transformations, [Trees, Height + 1], fun hash_equal/2),
    put(trees, NewTrees),
    NewTrees.

mine_next(#{tx_env := TxEnv} = S, _Value, [H]) ->
    S#{tx_env => aetx_env:set_height(TxEnv, H + 1)}.


%% --- Operation: spend ---
spend_pre(S) ->
    maps:is_key(trees, S).

spend_args(#{accounts := Accounts, tx_env := Env}) ->
    ?LET([Sender, Receiver], 
         vector(2, gen_account_pubkey(Accounts)),
         ?LET(Amount, nat(), 
              [Env, Sender, Receiver,
               #{sender_id => aec_id:create(account, Sender#account.key), 
                 recipient_id => aec_id:create(account, Receiver#account.key), 
                 amount => Amount, 
                 fee => choose(1, 100), 
                 nonce => Sender#account.nonce,
                 payload => utf8()},
               true  %% adapt depending on generation
              ])).

spend(Env, _Sender, _Receiver, Tx, _Correct) ->
    {ok, AeTx} = rpc(aec_spend_tx, new, [Tx]),
    {_CB, SpendTx} = aetx:specialize_callback(AeTx),
    Trees = get(trees),

    %% old version
    Remote = 
        case rpc:call(?REMOTE_NODE, aec_spend_tx, check, [SpendTx, Trees, Env], 1000) of
            {ok, Ts} ->
                rpc:call(?REMOTE_NODE, aec_spend_tx, process, [SpendTx, Ts, Env], 1000);
            OldError ->
                OldError
        end,

    Local = rpc:call(node(), aec_spend_tx, process, [SpendTx, Trees, Env], 1000),
    case Local of
        {ok, NewTrees} -> put(trees, NewTrees);
        _ -> ok
    end,
    eq_rpc(Local, Remote, fun hash_equal/2).


spend_next(#{accounts := Accounts} = S, _Value, 
           [_Env, SAccount, RAccount, Tx, Correct]) ->

    if Correct ->
            %% SAccount = lists:keyfind(Sender, #account.name, Accounts),
            %% RAccount = lists:keyfind(Receiver, #account.name, Accounts),
            S#{accounts => 
                   (Accounts -- [RAccount, SAccount]) ++ 
                   [SAccount#account{amount = SAccount#account.amount - maps:get(amount,Tx) - maps:get(fee, Tx), 
                                     nonce = maps:get(nonce, Tx) + 1},
                    RAccount#account{amount = maps:get(amount,Tx) + RAccount#account.amount}]};  %% add to end of list
       not Correct -> 
            S
    end.

spend_post(_S, [_Env, _, _, _Tx, Correct], Res) ->
    case Res of
        {error, _} when Correct -> false;
        _ -> true
    end.


spend_features(S, [_Env, _, _, _Tx, Correct], _Res) ->
    [{spend_accounts, length(maps:get(accounts, S))}, 
     {spend_correct, Correct}].





%% -- Property ---------------------------------------------------------------
prop_tx_primops() ->
    ?FORALL(Cmds, commands(?MODULE),
    ?TIMEOUT(3000,
    begin
        io:format("Pinging ~p~n", [?REMOTE_NODE]),

        pong = net_adm:ping(?REMOTE_NODE),
        io:format("Start run test ~p~n", [Cmds]),

        {H, S, Res} = run_commands(Cmds),
        Height = 
            case maps:get(tx_env, S, undefined) of
                undefined -> 0;
                TxEnv -> aetx_env:height(TxEnv)
            end,
        io:format("Did run test"),
        check_command_names(Cmds,
            measure(length, commands_length(Cmds),
            measure(height, Height,
            aggregate(call_features(H),
                pretty_commands(?MODULE, Cmds, {H, S, Res},
                                Res == ok)))))
    end)).

bugs() -> bugs(10).

bugs(N) -> bugs(N, []).

bugs(Time, Bugs) ->
    more_bugs(eqc:testing_time(Time, prop_tx_primops()), 20, Bugs).


%% --- local helpers ------

strict_equal(X, Y) ->
     case X == Y of 
         true -> X; 
         false -> exit({different, X, Y}) 
     end.

hash_equal(X, Y) ->
     case {X, Y} of 
         {{ok, L}, {ok, R}} -> 
             case aec_trees:hash(L) == aec_trees:hash(R) of
                 true -> X;
                 false -> exit({hash_differs, X, Y})
             end;
         {E, E} -> E;
         _ -> exit({different, X, Y}) 
     end.
 
rpc(Module, Fun, Args) ->
    rpc(Module, Fun, Args, fun(X,Y) -> strict_equal(X, Y) end).

rpc(Module, Fun, Args, InterpretResult) ->
    Local = rpc:call(node(), Module, Fun, Args, 1000),
    Remote = rpc:call(?REMOTE_NODE, Module, Fun, Args, 1000),
    eq_rpc(Local, Remote, InterpretResult).

eq_rpc(Local, Remote, InterpretResult) ->
    case {Local, Remote} of
        {{badrpc, {'EXIT', {E1, _}}},{badrpc, {'EXIT', {E2, _}}}} when E1 == E2 ->
            Local;
        _ ->
            InterpretResult(Local, Remote)
    end.
    
%% -- Generators -------------------------------------------------------------


gen_account_pubkey(Accounts) ->
    oneof(Accounts ++ 
              [ ?LAZY(#account{key = binary(32), amount = 0, nonce = 0, name = unique_name(Accounts) })]).

unique_name(Accounts) ->
    ?LET([W], 
         ?SUCHTHAT([Word], 
                   eqc_erlang_program:words(1), lists:keyfind(Word, #account.name, Accounts) == false), 
         W).


