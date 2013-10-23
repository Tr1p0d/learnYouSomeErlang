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

%% @doc UAC process helper functions
-module(nksip_uac_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([make/5, make_cancel/1, make_ack/2, make_ack/1, is_stateless/2]).
-include("nksip.hrl").
 

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Generates a new request.
%% See {@link nksip_uac} for the decription of most options.
-spec make(nksip:app_id(), nksip:method(), nksip:user_uri(), 
           nksip_lib:proplist(), nksip_lib:proplist()) ->    
    {ok, nksip:request(), nksip_lib:proplist()} | {error, Error} when
    Error :: invalid_uri | invalid_from | invalid_to | invalid_route |
             invalid_contact | invalid_cseq.

make(AppId, Method, Uri, Opts, AppOpts) ->
    FullOpts = Opts++AppOpts,
    try
        case nksip_parse:uris(Uri) of
            [RUri] -> ok;
            _ -> RUri = throw(invalid_uri)
        end,
        case nksip_parse:uris(nksip_lib:get_value(from, FullOpts)) of
            [From] -> ok;
            _ -> From = throw(invalid_from) 
        end,
        case nksip_lib:get_value(to, FullOpts) of
            undefined -> 
                To = RUri#uri{port=0, opts=[], 
                                headers=[], ext_opts=[], ext_headers=[]};
            as_from -> 
                To = From;
            ToOther -> 
                case nksip_parse:uris(ToOther) of
                    [To] -> ok;
                    _ -> To = throw(invalid_to) 
                end
        end,
        case nksip_lib:get_value(route, FullOpts, []) of
            [] ->
                Routes = [];
            RouteSpec ->
                case nksip_parse:uris(RouteSpec) of
                    [] -> Routes = throw(invalid_route);
                    Routes -> ok
                end
        end,
        case nksip_lib:get_value(contact, FullOpts, []) of
            [] ->
                Contacts = [];
            ContactSpec ->
                case nksip_parse:uris(ContactSpec) of
                    [] -> Contacts = throw(invalid_contact);
                    Contacts -> ok
                end
        end,
        case nksip_lib:get_binary(call_id, Opts) of
            <<>> -> CallId = nksip_lib:luid();
            CallId -> ok
        end,
        CSeq = case nksip_lib:get_value(cseq, Opts) of
            undefined -> nksip_config:cseq();
            UCSeq when is_integer(UCSeq), UCSeq > 0 -> UCSeq;
            _ -> throw(invalid_cseq)
        end,
        CSeq1 = case nksip_lib:get_integer(min_cseq, Opts) of
            MinCSeq when MinCSeq > CSeq -> MinCSeq;
            _ -> CSeq
        end,
        case nksip_lib:get_value(tag, From#uri.ext_opts) of
            undefined -> 
                FromTag = nksip_lib:uid(),
                FromOpts = [{tag, FromTag}|From#uri.ext_opts];
            FromTag -> 
                FromOpts = From#uri.ext_opts
        end,
        case nksip_lib:get_binary(user_agent, FullOpts) of
            <<>> -> UserAgent = <<"NkSIP ", ?VERSION>>;
            UserAgent -> ok
        end,
        Headers = 
                proplists:get_all_values(pre_headers, FullOpts) ++
                nksip_lib:get_value(headers, FullOpts, []) ++
                proplists:get_all_values(post_headers, FullOpts),
        Body = nksip_lib:get_value(body, Opts, <<>>),
        Headers1 = nksip_headers:update(Headers, [
            {default_single, <<"User-Agent">>, UserAgent},
            case lists:member(make_allow, FullOpts) of
                true -> {default_single, <<"Allow">>, nksip_sipapp_srv:allowed(AppOpts)};
                false -> []
            end,
            case lists:member(make_supported, FullOpts) of
                true -> {default_single, <<"Supported">>, ?SUPPORTED};
                false -> []
            end,
            case lists:member(make_accept, FullOpts) of
                true -> {default_single, <<"Accept">>, ?ACCEPT};
                false -> []
            end,
            case lists:member(make_date, FullOpts) of
                true -> {default_single, <<"Date">>, nksip_lib:to_binary(
                                                    httpd_util:rfc1123_date())};
                false -> []
            end
        ]),
        ContentType = case nksip_lib:get_binary(content_type, Opts) of
            <<>> when is_record(Body, sdp) -> [{<<"application/sdp">>, []}];
            <<>> when not is_binary(Body) -> [{<<"application/nksip.ebf.base64">>, []}];
            <<>> -> [];
            ContentTypeSpec -> nksip_parse:tokens([ContentTypeSpec])
        end,
         Req = #sipmsg{
            id = nksip_sipmsg:make_id(req, CallId),
            class = {req, nksip_parse:method(Method)},
            app_id = AppId,
            ruri = nksip_parse:uri2ruri(RUri),
            vias = [],
            from = From#uri{ext_opts=FromOpts},
            to = To,
            call_id = CallId,
            cseq = CSeq1,
            cseq_method = Method,
            forwards = 70,
            routes = Routes,
            contacts = Contacts,
            headers = Headers1,
            content_type = ContentType,
            body = Body,
            from_tag = FromTag,
            to_tag = nksip_lib:get_binary(tag, To#uri.ext_opts),
            transport = #transport{},
            data = [],
            start = nksip_lib:l_timestamp()
        },
        Opts1 = make_remove_opts(Opts, []),
        Opts2 = case lists:member(make_contact, Opts) of
            false when Method=='INVITE', Contacts=:=[] -> [make_contact|Opts1];
            _ -> Opts1
        end,
        {ok, Req, Opts2}
    catch
        throw:Throw -> {error, Throw}
    end.


%% @private
make_remove_opts([], Acc) ->
    lists:reverse(Acc);

make_remove_opts([{Tag, _}|Rest], Acc)
    when Tag==from; Tag==to; Tag==route; Tag==contact; Tag==call_id; Tag==cseq;
         Tag==min_cseq; Tag==user_agent; Tag==pre_headers; Tag==post_headers; 
         Tag==headers; Tag==body; Tag==content_type; Tag==expires ->
    make_remove_opts(Rest, Acc);

make_remove_opts([Tag|Rest], Acc) 
    when Tag==make_allow; Tag==make_supported; Tag==make_accept; Tag==make_date;
         Tag==unregister; Tag==unregister_all;
         Tag==active; Tag==inactive; Tag==hold ->
    make_remove_opts(Rest, Acc);

make_remove_opts([Tag|Rest], Acc) ->
    make_remove_opts(Rest, [Tag|Acc]).


%% @doc Generates a <i>CANCEL</i> request from an <i>INVITE</i> request.
-spec make_cancel(nksip:request()) ->
    nksip:request().

make_cancel(#sipmsg{class={req, _}, call_id=CallId, vias=[Via|_], headers=Hds}=Req) ->
    Req#sipmsg{
        class = {req, 'CANCEL'},
        id = nksip_sipmsg:make_id(req, CallId),
        cseq_method = 'CANCEL',
        forwards = 70,
        vias = [Via],
        headers = nksip_lib:extract(Hds, <<"Route">>),
        contacts = [],
        content_type = [],
        body = <<>>,
        data = []
    }.


%% @doc Generates an <i>ACK</i> request from an <i>INVITE</i> request and a response
-spec make_ack(nksip:request(), nksip:response()) ->
    nksip:request().

make_ack(Req, #sipmsg{to=To, to_tag=ToTag}) ->
    make_ack(Req#sipmsg{to=To, to_tag=ToTag}).


%% @private
-spec make_ack(nksip:request()) ->
    nksip:request().

make_ack(#sipmsg{vias=[Via|_], call_id=CallId}=Req) ->
    Req#sipmsg{
        class = {req, 'ACK'},
        id = nksip_sipmsg:make_id(req, CallId),
        vias = [Via],
        cseq_method = 'ACK',
        forwards = 70,
        routes = [],
        contacts = [],
        headers = [],
        content_type = [],
        body = <<>>,
        data = []
    }.



%% @doc Checks if a response is a stateless response
-spec is_stateless(nksip:response(), binary()) ->
    boolean().

is_stateless(Resp, GlobalId) ->
    #sipmsg{vias=[#via{opts=Opts}|_]} = Resp,
    case nksip_lib:get_binary(branch, Opts) of
        <<"z9hG4bK", Branch/binary>> ->
            StatelessId = nksip_lib:hash({Branch, GlobalId, stateless}),
            case nksip_lib:get_binary(nksip, Opts) of
                StatelessId -> true;
                _ -> false
            end;
        _ ->
            false
    end.


