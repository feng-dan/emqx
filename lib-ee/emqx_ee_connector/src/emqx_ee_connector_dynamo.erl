%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ee_connector_dynamo).

-behaviour(emqx_resource).

-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-export([roots/0, fields/1]).

%% `emqx_resource' API
-export([
    callback_mode/0,
    is_buffer_supported/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_batch_query/3,
    on_query_async/4,
    on_batch_query_async/4,
    on_get_status/2
]).

-export([
    connect/1,
    do_get_status/1,
    do_async_reply/2,
    worker_do_query/4,
    worker_do_get_status/1
]).

-import(hoconsc, [mk/2, enum/1, ref/2]).

-define(DYNAMO_HOST_OPTIONS, #{
    default_port => 8000
}).

-ifdef(TEST).
-export([execute/2]).
-endif.

%%=====================================================================
%% Hocon schema
roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, config)}}].

fields(config) ->
    [
        {url, mk(binary(), #{required => true, desc => ?DESC("url")})}
        | add_default_username(
            emqx_connector_schema_lib:relational_db_fields()
        )
    ].

add_default_username(Fields) ->
    lists:map(
        fun
            ({username, OrigUsernameFn}) ->
                {username, add_default_fn(OrigUsernameFn, <<"root">>)};
            (Field) ->
                Field
        end,
        Fields
    ).

add_default_fn(OrigFn, Default) ->
    fun
        (default) -> Default;
        (Field) -> OrigFn(Field)
    end.

%%========================================================================================
%% `emqx_resource' API
%%========================================================================================

callback_mode() -> async_if_possible.

is_buffer_supported() -> false.

on_start(
    InstanceId,
    #{
        url := Url,
        username := Username,
        password := Password,
        database := Database,
        pool_size := PoolSize
    } = Config
) ->
    ?SLOG(info, #{
        msg => "starting_dynamo_connector",
        connector => InstanceId,
        config => emqx_misc:redact(Config)
    }),

    {Schema, Server} = get_host_schema(to_str(Url)),
    {Host, Port} = emqx_schema:parse_server(Server, ?DYNAMO_HOST_OPTIONS),

    Options = [
        {config, #{
            host => Host,
            port => Port,
            username => to_str(Username),
            password => to_str(Password),
            schema => Schema
        }},
        {pool_size, PoolSize}
    ],

    Templates = parse_template(Config),
    State = #{
        poolname => InstanceId,
        database => Database,
        templates => Templates
    },
    case emqx_plugin_libs_pool:start_pool(InstanceId, ?MODULE, Options) of
        ok ->
            {ok, State};
        Error ->
            Error
    end.

on_stop(InstanceId, #{poolname := PoolName} = _State) ->
    ?SLOG(info, #{
        msg => "stopping_dynamo_connector",
        connector => InstanceId
    }),
    emqx_plugin_libs_pool:stop_pool(PoolName).

on_query(InstanceId, Query, State) ->
    do_query(InstanceId, Query, handover, State).

on_query_async(InstanceId, Query, Reply, State) ->
    do_query(
        InstanceId,
        Query,
        {handover_async, {?MODULE, do_async_reply, [Reply]}},
        State
    ).

%% we only support batch insert
on_batch_query(InstanceId, [{send_message, _} | _] = Query, State) ->
    do_query(InstanceId, Query, handover, State);
on_batch_query(_InstanceId, Query, _State) ->
    {error, {unrecoverable_error, {invalid_request, Query}}}.

%% we only support batch insert
on_batch_query_async(InstanceId, [{send_message, _} | _] = Query, Reply, State) ->
    do_query(
        InstanceId,
        Query,
        {handover_async, {?MODULE, do_async_reply, [Reply]}},
        State
    );
on_batch_query_async(_InstanceId, Query, _Reply, _State) ->
    {error, {unrecoverable_error, {invalid_request, Query}}}.

on_get_status(_InstanceId, #{poolname := Pool}) ->
    Health = emqx_plugin_libs_pool:health_check_ecpool_workers(Pool, fun ?MODULE:do_get_status/1),
    status_result(Health).

do_get_status(Conn) ->
    %% because the dynamodb driver connection process is the ecpool worker self
    %% so we must call the checker function inside the worker
    ListTables = ecpool_worker:exec(Conn, {?MODULE, worker_do_get_status, []}, infinity),
    case ListTables of
        {ok, _} -> true;
        _ -> false
    end.

worker_do_get_status(_) ->
    erlcloud_ddb2:list_tables().

status_result(_Status = true) -> connected;
status_result(_Status = false) -> connecting.

%%========================================================================================
%% Helper fns
%%========================================================================================

do_query(
    InstanceId,
    Query,
    ApplyMode,
    #{poolname := PoolName, templates := Templates, database := Database} = State
) ->
    ?TRACE(
        "QUERY",
        "dynamo_connector_received",
        #{connector => InstanceId, query => Query, state => State}
    ),
    Result = ecpool:pick_and_do(
        PoolName,
        {?MODULE, worker_do_query, [Database, Query, Templates]},
        ApplyMode
    ),

    case Result of
        {error, Reason} ->
            ?tp(
                dynamo_connector_query_return,
                #{error => Reason}
            ),
            ?SLOG(error, #{
                msg => "dynamo_connector_do_query_failed",
                connector => InstanceId,
                query => Query,
                reason => Reason
            }),
            Result;
        _ ->
            ?tp(
                dynamo_connector_query_return,
                #{result => Result}
            ),
            Result
    end.

worker_do_query(_Client, Database, Query0, Templates) ->
    try
        Query = apply_template(Query0, Templates),
        execute(Query, Database)
    catch
        _Type:Reason ->
            {error, {unrecoverable_error, {invalid_request, Reason}}}
    end.

%% some simple query commands for authn/authz or test
execute({insert_item, Msg}, Database) ->
    Item = convert_to_item(Msg),
    erlcloud_ddb2:put_item(Database, Item);
execute({delete_item, Key}, Database) ->
    erlcloud_ddb2:delete_item(Database, Key);
execute({get_item, Key}, Database) ->
    erlcloud_ddb2:get_item(Database, Key);
%% commands for data bridge query or batch query
execute({send_message, Msg}, Database) ->
    Item = convert_to_item(Msg),
    erlcloud_ddb2:put_item(Database, Item);
execute([{put, _} | _] = Msgs, Database) ->
    %% type of batch_write_item argument :: batch_write_item_request_items()
    %% batch_write_item_request_items() :: maybe_list(batch_write_item_request_item())
    %% batch_write_item_request_item() :: {table_name(), list(batch_write_item_request())}
    %% batch_write_item_request() :: {put, item()} | {delete, key()}
    erlcloud_ddb2:batch_write_item({Database, Msgs}).

connect(Opts) ->
    #{
        username := Username,
        password := Password,
        host := Host,
        port := Port,
        schema := Schema
    } = proplists:get_value(config, Opts),
    erlcloud_ddb2:configure(Username, Password, Host, Port, Schema),

    %% The dynamodb driver uses caller process as its connection process
    %% so at here, the connection process is the ecpool worker self
    {ok, self()}.

parse_template(Config) ->
    Templates =
        case maps:get(template, Config, undefined) of
            undefined -> #{};
            <<>> -> #{};
            Template -> #{send_message => Template}
        end,

    parse_template(maps:to_list(Templates), #{}).

parse_template([{Key, H} | T], Templates) ->
    ParamsTks = emqx_plugin_libs_rule:preproc_tmpl(H),
    parse_template(
        T,
        Templates#{Key => ParamsTks}
    );
parse_template([], Templates) ->
    Templates.

to_str(List) when is_list(List) ->
    List;
to_str(Bin) when is_binary(Bin) ->
    erlang:binary_to_list(Bin).

get_host_schema("http://" ++ Server) ->
    {"http://", Server};
get_host_schema("https://" ++ Server) ->
    {"https://", Server};
get_host_schema(Server) ->
    {"http://", Server}.

apply_template({Key, Msg} = Req, Templates) ->
    case maps:get(Key, Templates, undefined) of
        undefined ->
            Req;
        Template ->
            {Key, emqx_plugin_libs_rule:proc_tmpl(Template, Msg)}
    end;
%% now there is no batch delete, so
%% 1. we can simply replace the `send_message` to `put`
%% 2. convert the message to in_item() here, not at the time when calling `batch_write_items`,
%%    so we can reduce some list map cost
apply_template([{send_message, _Msg} | _] = Msgs, Templates) ->
    lists:map(
        fun(Req) ->
            {_, Msg} = apply_template(Req, Templates),
            {put, convert_to_item(Msg)}
        end,
        Msgs
    ).

convert_to_item(Msg) when is_map(Msg), map_size(Msg) > 0 ->
    maps:fold(
        fun
            (_K, <<>>, AccIn) ->
                AccIn;
            (K, V, AccIn) ->
                [{convert2binary(K), convert2binary(V)} | AccIn]
        end,
        [],
        Msg
    );
convert_to_item(MsgBin) when is_binary(MsgBin) ->
    Msg = emqx_json:decode(MsgBin),
    convert_to_item(Msg);
convert_to_item(Item) ->
    erlang:throw({invalid_item, Item}).

convert2binary(Value) when is_atom(Value) ->
    erlang:atom_to_binary(Value, utf8);
convert2binary(Value) when is_binary(Value); is_number(Value) ->
    Value;
convert2binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
convert2binary(Value) when is_map(Value) ->
    emqx_json:encode(Value).

do_async_reply(Result, {ReplyFun, [Context]}) ->
    ReplyFun(Context, Result).
