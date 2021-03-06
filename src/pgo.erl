%%% ---------------------------------------------------------------------------
%%% @author Tristan Sloughter <t@crashfast.com>
%%%
%%% @doc Postgres driver and pool for Erlang.
%%%
%%% This module provides functions for interacting with a pool and
%%  querying the database.
%%% @end
%%% ---------------------------------------------------------------------------
-module(pgo).

-export([start_pool/2,
         query/1,
         query/2,
         query/3,
         transaction/1,
         transaction/2,
         checkout/1,
         checkin/2,
         break/1]).

-include("pgo_internal.hrl").

-export_type([result/0,
              pool_ref/0,
              conn/0,
              error/0]).
-type conn() :: pgo_pool:conn().
-type pool_ref() :: pgo_pool:ref().
-type result() :: #{command := atom(),
                    num_rows := integer(),
                    rows := list()} | {error, error()}.

-type error() :: {pgo_error, #{error_field() => binary()}}.

-type pool() :: atom().

-type pool_opt() :: {size, integer()}
                  | {host, string()}
                  | {port, integer()}
                  | {user, string()}
                  | {password, string()}
                  | {database, string()}.
-type pool_config() :: [pool_opt()].

%% @doc Starts connection pool as a child of pgo_sup.
-spec start_pool(pool(), pool_config()) -> {ok, pid()}.
start_pool(Name, PoolConfig) ->
    pgo_sup:start_child(Name, PoolConfig).

%% @equiv query(default, Query)
-spec query(iodata()) -> result().
query(Query) ->
    query(default, Query).

%% @doc Executes a simple query either on a Pool or a provided connection.
-spec query(conn() | pool(), iodata()) -> result().
query(Conn=#conn{}, Query) ->
    pgo_handler:simple_query(Conn, Query);
query(Pool, Query) when is_atom(Pool) ->
    SpanCtx = oc_trace:start_span(<<"pgo:query/2">>, ocp:current_span_ctx(),
                                  #{attributes => #{<<"query">> => Query}}),
    {ok, Ref, Conn} = checkout(Pool),
    try
        pgo_handler:simple_query(Conn, Query)
    after
        checkin(Ref, Conn),
        oc_trace:finish_span(SpanCtx)
    end;
query(Query, Params) ->
    query(default, Query, Params).

%% @doc Executes an extended query either on a Pool or a provided connection.
-spec query(conn() | pool(), iodata(), list()) -> result().
query(Conn=#conn{}, Query, Params) ->
    pgo_handler:extended_query(Conn, Query, Params);
query(Pool, Query, Params) ->
    SpanCtx = oc_trace:start_span(<<"pgo:query/3">>, ocp:current_span_ctx(),
                                  #{attributes => #{<<"query">> => Query}}),
    {ok, Ref, Conn} = checkout(Pool),
    try
        pgo_handler:extended_query(Conn, Query, Params)
    after
        checkin(Ref, Conn),
        oc_trace:finish_span(SpanCtx)
    end.

%% @equiv transaction(default, Fun)
-spec transaction(fun((conn()) -> any())) -> any().
transaction(Fun) ->
    transaction(default, Fun).

%% @doc Runs a function, passing it a connection, in a SQL transaction.
-spec transaction(pool(), fun((conn()) -> any())) -> any().
transaction(Pool, Fun) ->
    case get(pgo_transaction_connection) of
        undefined ->
            SpanCtx = oc_trace:start_span(<<"pgo:transaction/2">>, ocp:current_span_ctx(), #{}),
            {ok, Ref, Conn} = checkout(Pool),
            try
                #{command := 'begin'} = pgo_handler:simple_query(Conn, "BEGIN"),
                put(pgo_transaction_connection, Conn),
                Result = Fun(Conn),
                #{command := 'commit'} = pgo_handler:simple_query(Conn, "COMMIT"),
                Result
            catch
                Class:Reason ->
                    pgo_handler:simple_query(Conn, "ROLLBACK"),
                    erlang:raise(Class, Reason, erlang:get_stacktrace())
            after
                checkin(Ref, Conn),
                erase(pgo_transaction_connection),
                oc_trace:finish_span(SpanCtx)
            end;
        Conn ->
            %% already in a transaction
            Fun(Conn)
    end.

%% @doc Returns a connection from the pool.
-spec checkout(pool()) -> {ok, pool_ref(), conn()} | {error, any()}.
checkout(Pool) ->
    pgo_pool:checkout(Pool, [{queue, false}]).

%% @doc Return a checked out connection to its pool
-spec checkin(pool_ref(), conn()) -> ok.
checkin(Ref, Conn) ->
    pgo_pool:checkin(Ref, Conn, []).

%% @doc Disconnects the socket held by this reference.
-spec break(conn()) -> ok.
break(Conn) ->
    pgo_connection:break(Conn).
