%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private Call UAC Management: Reply
-module(nksip_call_uac_reply).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([reply/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec reply({req, nksip:request()} | {resp, nksip:response()} | {error, term()},
            nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

reply({req, Req}, #trans{from={srv, From}, method='ACK', opts=Opts}, Call) ->
    Async = lists:member(async, Opts),
    Get = lists:member(get_request, Opts),
    if
        Async, Get -> fun_call({req, Req}, Opts);
        Async -> fun_call(ok, Opts);
        Get -> gen_server:reply(From, {req, Req});
        not Get -> gen_server:reply(From, ok)
    end,
    Call;

reply({req, Req}, #trans{from={srv, _From}, opts=Opts}, Call) ->
    case lists:member(get_request, Opts) of
        true -> fun_call({req, Req}, Opts);
        false ->  ok
    end,
    Call;

reply({resp, Resp}, #trans{from={srv, From}, opts=Opts}, Call) ->
    #sipmsg{class={resp, Code}} = Resp,
    Async = lists:member(async, Opts),
    if
        Code < 101 -> ok;
        Async -> fun_call(fun_response(Resp, Opts), Opts);
        Code < 200 -> fun_call(fun_response(Resp, Opts), Opts);
        Code >= 200 -> gen_server:reply(From, fun_response(Resp, Opts))
    end,
    Call;

reply({error, Error}, #trans{from={srv, From}, opts=Opts}, Call) ->
    case lists:member(async, Opts) of
        true -> fun_call({error, Error}, Opts);
        false -> gen_server:reply(From, {error, Error})
    end,
    Call;

reply({resp, Resp}, #trans{id=Id, from={fork, ForkId}}, Call) ->
    nksip_call_fork:response(ForkId, Id, Resp, Call);

reply(_Resp, _UAC, Call) ->
    Call.


%% @private
fun_call(Msg, Opts) ->
    case nksip_lib:get_value(callback, Opts) of
        Fun when is_function(Fun, 1) -> spawn(fun() -> Fun(Msg) end);
        _ -> ok
    end.


fun_response(#sipmsg{class={resp, Code}, cseq_method=Method}=Resp, Opts) ->
    case lists:member(get_response, Opts) of
        true ->
            {resp, Resp};
        false ->
            Fields0 = case Method of
                'INVITE' -> [{dialog_id, nksip_dialog:id(Resp)}];
                _ -> []
            end,
            Values = case nksip_lib:get_value(fields, Opts, []) of
                [] ->
                    Fields0;
                Fields when is_list(Fields) ->
                    Fields0 ++ lists:zip(Fields, nksip_sipmsg:fields(Resp, Fields));
                _ ->
                    Fields0
            end,
            {ok, Code, Values}
    end.

