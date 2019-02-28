%%--------------------------------------------------------------------
%% Copyright (c) 2013-2013-2019 EMQ Enterprise, Inc. (http://emqtt.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_alarm_handler_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

-include_lib("common_test/include/ct.hrl").

-include("emqx_mqtt.hrl").
-include("emqx.hrl").

all() -> [t_alarm_handler, t_logger_handler].

init_per_suite(Config) ->
    [start_apps(App, {SchemaFile, ConfigFile}) ||
        {App, SchemaFile, ConfigFile}
            <- [{emqx, local_path("priv/emqx.schema"),
                       local_path("etc/emqx.conf")}]],
    Config.

end_per_suite(_Config) ->
    application:stop(emqx).

local_path(RelativePath) ->
    filename:join([get_base_dir(), RelativePath]).

get_base_dir() ->
    {file, Here} = code:is_loaded(?MODULE),
    filename:dirname(filename:dirname(Here)).

start_apps(App, {SchemaFile, ConfigFile}) ->
    read_schema_configs(App, {SchemaFile, ConfigFile}),
    set_special_configs(App),
    application:ensure_all_started(App).

read_schema_configs(App, {SchemaFile, ConfigFile}) ->
    ct:pal("Read configs - SchemaFile: ~p, ConfigFile: ~p", [SchemaFile, ConfigFile]),
    Schema = cuttlefish_schema:files([SchemaFile]),
    Conf = conf_parse:file(ConfigFile),
    NewConfig = cuttlefish_generator:map(Schema, Conf),
    Vals = proplists:get_value(App, NewConfig, []),
    [application:set_env(App, Par, Value) || {Par, Value} <- Vals].

set_special_configs(_App) ->
    ok.

with_connection(DoFun) ->
    {ok, Sock} = emqx_client_sock:connect({127, 0, 0, 1}, 1883,
                                          [binary, {packet, raw}, {active, false}],
                                          3000),
    try
        DoFun(Sock)
    after
        emqx_client_sock:close(Sock)
    end.

t_alarm_handler(_) ->
    with_connection(
        fun(Sock) ->
            emqx_client_sock:send(Sock,
                                  raw_send_serialize(
                                      ?CONNECT_PACKET(
                                          #mqtt_packet_connect{
                                          proto_ver  = ?MQTT_PROTO_V5}),
                                      #{version => ?MQTT_PROTO_V5}
                                  )),
            {ok, Data} = gen_tcp:recv(Sock, 0),
            {ok, ?CONNACK_PACKET(?RC_SUCCESS), _} = raw_recv_parse(Data, ?MQTT_PROTO_V5),

            Topic1 = emqx_topic:systop(<<"alarms/alarm_for_test/alert">>),
            Topic2 = emqx_topic:systop(<<"alarms/alarm_for_test/clear">>),
            SubOpts = #{rh => 1, qos => ?QOS_2, rap => 0, nl => 0, rc => 0},
            emqx_client_sock:send(Sock, 
                                  raw_send_serialize(
                                      ?SUBSCRIBE_PACKET(
                                          1, 
                                          [{Topic1, SubOpts},
                                           {Topic2, SubOpts}]), 
                                      #{version => ?MQTT_PROTO_V5})),

            {ok, Data2} = gen_tcp:recv(Sock, 0),
            {ok, ?SUBACK_PACKET(1, #{}, [2, 2]), _} = raw_recv_parse(Data2, ?MQTT_PROTO_V5),

            alarm_handler:set_alarm({alarm_for_test, #alarm{id = alarm_for_test,
                                                            severity = error,
                                                            title="alarm title",
                                                            summary="alarm summary"}}),

            {ok, Data3} = gen_tcp:recv(Sock, 0),

            {ok, ?PUBLISH_PACKET(?QOS_0, Topic1, _, _), _} = raw_recv_parse(Data3, ?MQTT_PROTO_V5),

            ?assertEqual(true, lists:keymember(alarm_for_test, 1, emqx_alarm_handler:get_alarms())),

            alarm_handler:clear_alarm(alarm_for_test),

            {ok, Data4} = gen_tcp:recv(Sock, 0),

            {ok, ?PUBLISH_PACKET(?QOS_0, Topic2, _, _), _} = raw_recv_parse(Data4, ?MQTT_PROTO_V5),

            ?assertEqual(false, lists:keymember(alarm_for_test, 1, emqx_alarm_handler:get_alarms()))

        end).

t_logger_handler(_) ->
    %% Meck supervisor report
    logger:log(error, #{label => {supervisor, start_error}, 
                        report => [{supervisor, {local, tmp_sup}}, 
                                   {errorContext, shutdown}, 
                                   {reason, reached_max_restart_intensity}, 
                                   {offender, [{pid, meck},
                                               {id, meck},
                                               {mfargs, {meck, start_link, []}},
                                               {restart_type, permanent},
                                               {shutdown, 5000},
                                               {child_type, worker}]}]}, 
               #{logger_formatter => #{title => "SUPERVISOR REPORT"},
                 report_cb => fun logger:format_otp_report/1}),
    ?assertEqual(true, lists:keymember(supervisor_report, 1, emqx_alarm_handler:get_alarms())).

raw_send_serialize(Packet) ->
    emqx_frame:serialize(Packet).

raw_send_serialize(Packet, Opts) ->
    emqx_frame:serialize(Packet, Opts).

raw_recv_parse(P, ProtoVersion) ->
    emqx_frame:parse(P, {none, #{max_packet_size => ?MAX_PACKET_SIZE,
                                 version         => ProtoVersion}}).

