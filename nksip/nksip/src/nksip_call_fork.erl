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

%% @doc Call Fork Management
-module(nksip_call_fork).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/4, cancel/2, response/4]).
-export_type([id/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-type id() :: integer().

-type call() :: nksip_call:call().

-type fork() :: #fork{}.


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts a new Forking Proxy.
-spec start(nksip_call:trans(), nksip:uri_set(), nksip_lib:proplist(),call()) ->
   call().

start(Trans, UriSet, ForkOpts, #call{forks=Forks}=Call) ->
    #trans{id=TransId, class=Class, request=Req, method=Method} = Trans,
    Fork = #fork{
        id = TransId,
        class = Class,
        start = nksip_lib:timestamp(),
        uriset = UriSet,
        request  = Req,
        method = Method,
        opts = ForkOpts,
        uacs = [],
        pending = [],
        responses = [],
        final = false
    },
    ?call_debug("Fork ~p ~p started from UAS", [TransId, Method], Call),
    Call1 = Call#call{forks=[Fork|Forks]},
    next(Fork, Call1).



%% @doc Tries to cancel an ongoing fork.
-spec cancel(id(), call()) ->
   call().

cancel(ForkId, #call{forks=Forks}=Call) ->
    case lists:keyfind(ForkId, #fork.id, Forks) of
        #fork{method='INVITE'}=Fork -> 
            ?call_debug("Fork ~p cancelling requests", [ForkId], Call),
            Fork1 = Fork#fork{uriset=[]},
            cancel_all(Fork1, update(Fork1, Call));
        #fork{method=Method}=Fork -> 
            ?call_debug("Fork ~p cannot cancel ~p", [ForkId, Method], Call),
            Fork1 = Fork#fork{uriset=[]},
            update(Fork1, Call);
        false -> 
            ?call_info("Fork ~p not found for CANCEL", [ForkId], Call),
            Call
    end.


%% @private
-spec next(fork(), call()) ->
   call().

next(#fork{pending=[]}=Fork, Call) ->
    #fork{id=Id, final=Final, method=Method, uriset=UriSet} = Fork,
    case Final of
        false ->
            case UriSet of
                [] when Method=:='ACK' ->
                    delete(Fork, Call);
                [] ->
                    #sipmsg{class={resp, Code}} = Resp = best_response(Fork),
                    ?call_debug("Fork ~p ~p selected ~p response", 
                                [Id, Method, Code], Call),
                    Call1 = send_reply(Resp, Fork, Call),
                    delete(Fork, Call1);
                [Next|Rest] ->
                    ?call_debug("Fork ~p ~p launching next group", [Id, Method], Call),
                    Fork1 = Fork#fork{uriset=Rest},
                    launch(Next, Fork1, update(Fork1, Call))
            end;
        _ ->
            delete(Fork, Call)
    end;

next(#fork{id=Id, method=Method, pending=Pending}, Call) ->
    ?call_debug("Fork ~p ~p waiting, ~p pending: ~p", 
                [Id, Method, length(Pending), Pending], Call),
    Call.


%% @private
-spec launch([nksip:uri()], fork(), call()) ->
   call().

launch([], Fork, Call) ->
    next(Fork, Call);

launch([Uri|Rest], Fork, Call) -> 
    #fork{id=Id, request=Req, method=Method, opts=Opts,
          uacs=UACs, pending=Pending, responses=Resps} = Fork,
    #sipmsg{call_id=CallId} = Req,
    Req1 = Req#sipmsg{ruri=Uri, id=nksip_sipmsg:make_id(req, CallId)},
    #call{next=Next} = Call,
    case nksip_request:is_local_route(Req1) of
        true ->
            ?call_notice("Fork tried to stateful proxy a request to itself: ~s", 
                         [nksip_unparse:uri(Uri)], Call),
            {Resp, _} = nksip_reply:reply(Req, loop_detected),
            Fork1 = Fork#fork{responses=[Resp|Resps]},
            launch(Rest, Fork1, update(Fork1, Call));
        false ->
            ?call_debug("Fork ~p ~p launching to ~s", 
                         [Id, Method, nksip_unparse:uri(Uri)], Call),
            UACOpts = case lists:member(record_route, Opts) of
                true -> [record_route];
                false -> []
            end,
            Call1 = nksip_call_uac_req:request(Req1, UACOpts, {fork, Id}, Call),
            Call2 = Call1#call{next=Next+1},
            Fork1 = case Method of
                'ACK' -> Fork#fork{uacs=[Next|UACs]};
                _ -> Fork#fork{uacs=[Next|UACs], pending=[Next|Pending]}
            end,
            launch(Rest, Fork1, update(Fork1, Call2))
    end.


%% @private Called when a launched UAC has a response
-spec response(id(), integer(), nksip:response(),call()) ->
   call().

response(_, _, #sipmsg{class={resp, Code}}, Call) when Code < 101 ->
    Call;

response(Id, Pos, #sipmsg{vias=[_|Vias]}=Resp, #call{forks=Forks}=Call) ->
    #sipmsg{class={resp, Code}, to_tag=ToTag} = Resp,
    case lists:keyfind(Id, #fork.id, Forks) of
        #fork{pending=Pending, uacs=UACs, method=Method}=Fork ->
            ?call_debug("Fork ~p ~p received ~p (~s)", 
                        [Id, Method, Code, ToTag], Call),
            Resp1 = Resp#sipmsg{vias=Vias},
            case lists:member(Pos, Pending) of
                true ->
                    waiting(Code, Resp1, Pos, Fork, Call);
                false ->
                    case lists:member(Pos, UACs) of
                        true ->
                            ?call_debug("Fork ~p ~p received new response ~p from ~s",
                                       [Id, Method, Code, ToTag], Call),
                            case Code>=200 andalso  Code<300 of
                                true -> send_reply(Resp1, Fork, Call);
                                false -> Call
                            end;
                        false ->
                            ?call_debug("Fork ~p ~p received unexpected response "
                                        "~p from ~s", [Id, Method, Code, ToTag], 
                                        Call),
                            Call
                    end
            end;
        false ->
            ?call_notice("Unknown fork ~p received ~p", [Id, Code], Call),
            Call
    end.


%% @private
-spec waiting(nksip:response_code(), nksip:response(), integer(), fork(), call()) ->
   call().

% 1xx
waiting(Code, Resp, _Pos, #fork{final=Final}=Fork, Call) when Code < 200 ->
    case Final of
        false -> send_reply(Resp, Fork, Call);
        _ -> Call
    end;
    
% 2xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 300 ->
    #fork{final=Final, pending=Pending} = Fork,
    Fork1 = Fork#fork{pending=Pending--[Pos], uriset=[]},
    Call1 = cancel_all(Fork1, Call),
    Fork2 = case Final of
        false -> Fork1#fork{final='2xx'};
        _ -> Fork1
    end,
    Call2 = send_reply(Resp, Fork2, Call1),
    next(Fork2, update(Fork2, Call2));

% 3xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 400 ->
    #fork{
        id = Id,
        final = Final,
        pending = Pending,
        responses = Resps,
        request = #sipmsg{ruri=RUri},
        opts = Opts
    } = Fork,
    #sipmsg{contacts=Contacts} = Resp,
    Fork1 = Fork#fork{pending=Pending--[Pos]},
    case lists:member(follow_redirects, Opts) of
        true when Final=:=false, Contacts =/= [] -> 
            Contacts1 = case RUri#uri.scheme of
                sips -> [Contact || #uri{scheme=sips}=Contact <- Contacts];
                _ -> Contacts
            end,
            ?call_debug("Fork ~p redirect to ~p", 
                       [Id, nksip_unparse:uri(Contacts1)], Call),
            launch(Contacts1, Fork1, update(Fork1, Call));
        _ ->
            Fork2 = Fork1#fork{responses=[Resp|Resps]},
            next(Fork2, update(Fork2, Call))
    end;

% 45xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 600 ->
    #fork{pending=Pending, responses=Resps} = Fork,
    Fork1 = Fork#fork{pending=Pending--[Pos], responses=[Resp|Resps]},
    next(Fork1, update(Fork1, Call));

% 6xx
waiting(Code, Resp, Pos, Fork, Call) when Code >= 600 ->
    #fork{final=Final, pending=Pending} = Fork,
    Fork1 = Fork#fork{pending=Pending--[Pos], uriset=[]},
    Call1 = cancel_all(Fork1, Call),
    case Final of
        false -> 
            Fork2 = Fork1#fork{final='6xx'},
            Call2 = send_reply(Resp, Fork2, Call1),
            next(Fork2, update(Fork2, Call2));
        _ ->
            next(Fork1, update(Fork1, Call1))
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec send_reply(nksip:response(), fork(), call()) ->
   call().

send_reply(Resp, Fork, Call) ->
    #sipmsg{class={resp, Code}} = Resp,
    #fork{id=TransId, method=Method} = Fork,
    #call{trans=Trans} = Call,
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS ->
            ?call_debug("Fork ~p ~p send reply to UAS: ~p", 
                        [TransId, Method, Code], Call),
            {_, Call1} = nksip_call_uas_reply:reply({Resp, []}, UAS, Call),
            Call1;
        _ ->
            ?call_debug("Unknown UAS ~p received fork reply",
                        [TransId], Call),
            Call
    end.


%% @private
-spec best_response(fork()) ->
    nksip:response().

best_response(#fork{request=Req, responses=Resps}) ->
    Sorted = lists:sort([
        if
            Code =:= 401; Code =:= 407 -> {3999, Resp};
            Code =:= 415; Code =:= 420; Code =:= 484 -> {4000, Resp};
            Code =:= 503 -> {5000, Resp#sipmsg{class={resp, 500}}};
            Code >= 600 -> {Code, Resp};
            true -> {10*Code, Resp}
        end
        || #sipmsg{class={resp, Code}}=Resp <- Resps
    ]),
    case Sorted of
        [{3999, Best}|_] ->
            Names = [<<"WWW-Authenticate">>, <<"Proxy-Authenticate">>],
            Headers1 = [
                nksip_lib:delete(Best#sipmsg.headers, Names) |
                [
                    nksip_lib:extract(Headers, Names) || 
                    #sipmsg{class={resp, Code}, headers=Headers}
                    <- Resps, Code=:=401 orelse Code=:=407
                ]
            ],
            Best#sipmsg{headers=lists:flatten(Headers1)};
        [{_, Best}|_] ->
            Best;
        _ ->
            {Best, _} = nksip_reply:reply(Req, temporarily_unavailable),
            Best
    end.


%% @private
-spec cancel_all(fork(), call()) ->
   call().
    
cancel_all(#fork{method='INVITE', pending=[UAC|Rest]}=Fork, Call) ->
    Call1 = nksip_call_uac:cancel(UAC, Call),
    cancel_all(Fork#fork{pending=Rest}, Call1);

cancel_all(_Fork, Call) ->
    Call.


%% @private 
update(#fork{id=Id}=Fork, #call{forks=[#fork{id=Id}|Rest]}=Call) ->
    Call#call{forks=[Fork|Rest]};

update(#fork{id=Id}=Fork, #call{forks=Forks}=Call) ->
    Call#call{forks=lists:keystore(Id, #fork.id, Forks, Fork)}.


%% @private
-spec delete(fork(), call()) ->
   call().

delete(#fork{id=Id, method=Method}, #call{forks=Forks}=Call) ->
    ?call_debug("Fork ~p ~p deleted", [Id, Method], Call),
    Forks1 = lists:keydelete(Id, #fork.id, Forks),
    Call#call{forks=Forks1, hibernate=fork_finished}.



