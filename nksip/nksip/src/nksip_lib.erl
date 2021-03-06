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

%% @doc Common library utility funcions
-module(nksip_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([tokenize/2, untokenize/1]).
-export([cseq/0, luid/0, lhash/1, uid/0, hash/1]).
-export([get_local_ips/0, find_main_ip/0, find_main_ip/1]).
-export([timestamp/0, l_timestamp/0, l_timestamp_to_float/1]).
-export([timestamp_to_local/1, timestamp_to_gmt/1]).
-export([local_to_timestamp/1, gmt_to_timestamp/1]).
-export([get_value/2, get_value/3, get_binary/2, get_binary/3, get_list/2, get_list/3]).
-export([get_integer/2, get_integer/3]).
-export([to_binary/1, to_list/1, to_integer/1, to_ip/1, is_string/1]).
-export([to_lower/1, to_upper/1]).
-export([bjoin/1, bjoin/2, hex/1, extract/2, delete/2, bin_last/2]).
-export([cancel_timer/1, msg/2]).

-export_type([proplist/0, timestamp/0, l_timestamp/0, token/0, token_list/0]).

-include("nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% Standard Proplist
-type proplist() :: [atom() | binary() | {atom()|binary(), term()}].

%% System timestamp
-type timestamp() :: non_neg_integer().
-type l_timestamp() :: non_neg_integer().


%% Token representation in SIP Header
-type token() :: {Name::binary(), Opts::proplist()}.

%% Internal tokenizer result
-type token_list() :: [{string()} | char()].



%% ===================================================================
%% Public
%% =================================================================

%% @doc Scans an `string()' or `binary()' for tokens.
%%  
%%  The string is first partitioned in lines using `","' as separator, and each line
%%  will be a term in the resulting arrary. For each line, each token is found using 
%%  whitespace as separator, and returned as `{string()}'. 
%%
%%  Depending on `Class', new separators are used: (`<>:@;=?&' for `uri', 
%% `/:;=' for `via', `:=' for `token' and `=' for `equal').
%%
%%  Any part enclosed in double quotes is returned as a token, including the
%%  quotes.  Any part enclosed in `<' and `>' is processed, but the `<' and `>' 
%%  separators are included in the returned list and no `","' is processed inside.
%%  <br/><br/>
%%  Example: 
%%
%%  ```tokenize(<<"this is \"an, example\", and; this < is ; other, bye> ">>, uri)'''
%%  returns
%%  ```
%%  [
%%      [{"this"},{"is"},{"\"an, example\""}],
%%      [{"and"},$;,{"this"},$<,{"is"},$;,{"other"}],
%%      [{"bye"},$>]
%%  ]
%%  '''
%%
-spec tokenize(Input, Class) -> [token_list()]
    when Input :: binary() | string(), Class :: none|uri|via|token|equal.

tokenize(Bin, Class) when is_binary(Bin) ->
    tokenize(binary_to_list(Bin), Class);

tokenize([], _) ->
    [];

tokenize(List, Class) when is_list(List), is_atom(Class) -> 
    tokenize(List, none, Class, [], [], []);

tokenize(_, _) ->
    [].


tokenize([Ch|Rest], Quote, Class, Chs, Words, Lines) -> 
    if
        Ch=:=$", Quote=:=none, Chs=:=[] ->  % Only after WS or token (Chs==[])
            tokenize(Rest, double, Class, [$"], Words, Lines);
        Ch=:=$", Quote=:=double  ->
            Words1 = [{lists:reverse([$"|Chs])}|Words],
            tokenize(Rest, none, Class, [], Words1, Lines);
        Ch=:=$,, Quote=:=none, Chs=:=[] ->
            tokenize(Rest, none, Class, [], [], [lists:reverse(Words)|Lines]);
        Ch=:=$,, Quote=:=none ->
            Words1 = [{lists:reverse(Chs)}|Words],
            tokenize(Rest, none, Class, [], [], [lists:reverse(Words1)|Lines]);
        (Ch=:=32 orelse Ch=:=9) andalso Quote=:=none ->
            case Chs of
                [] -> tokenize(Rest, Quote, Class, [], Words, Lines);
                _ -> tokenize(Rest, Quote, Class, [], [{lists:reverse(Chs)}|Words], Lines)
            end;
        Class=/=[] andalso Quote=:=none ->
            case is_token(Ch, Class) of
                true when Chs=:=[] -> 
                    tokenize(Rest, Quote, Class, [], [Ch|Words], Lines);
                true -> 
                    tokenize(Rest, Quote, Class, [], [Ch, {lists:reverse(Chs)}|Words], Lines);
                false ->
                    tokenize(Rest, Quote, Class, [Ch|Chs], Words, Lines)
            end;
        true ->
            tokenize(Rest, Quote, Class, [Ch|Chs], Words, Lines)
    end;

tokenize([], Quote, Class, Chs, Words, Lines) -> 
    if
        Quote=:=double -> 
            tokenize([$"], double, Class, Chs, Words, Lines);
        Chs=:=[] -> 
            lists:reverse([lists:reverse(Words)|Lines]);
        true ->
            Words1 = [{lists:reverse(Chs)}|Words],
            lists:reverse([lists:reverse(Words1)|Lines])
    end.

%% @private
is_token($<, none) -> false;
is_token($<, uri) -> true;
is_token($>, uri) -> true;
is_token($:, uri) -> true;
is_token($@, uri) -> true;
is_token($;, uri) -> true;
is_token($=, uri) -> true;
is_token($?, uri) -> true;
is_token($&, uri) -> true;
is_token($/, via) -> true;
is_token($:, via) -> true;
is_token($;, via) -> true;
is_token($=, via) -> true;
is_token($;, token) -> true;
is_token($=, token) -> true;
is_token($=, equal) -> true;
is_token(_, _) -> false.


%% @doc Serializes a `token_list()' list
-spec untokenize([token_list()]) -> 
    iolist().

untokenize(Lines) ->
    untokenize_lines(Lines, []).

untokenize_lines([Line|Rest], Acc) ->
    untokenize_lines(Rest, [$,, untokenize_words(Line, [])|Acc]);
untokenize_lines([], [$,|Acc]) ->
    lists:reverse(Acc);
untokenize_lines([], []) ->
    [].

untokenize_words([{Word1}, {Word2}|Rest], Acc) ->
    untokenize_words([{Word2}|Rest], [32, Word1|Acc]);
untokenize_words([{Word1}|Rest], Acc) ->
    untokenize_words(Rest, [Word1|Acc]);
untokenize_words([Sep|Rest], Acc) ->
    untokenize_words(Rest, [Sep|Acc]);
untokenize_words([], Acc) ->
    lists:reverse(Acc).


%% @doc Generates an incrementing-each-second 31 bit integer.
%% It will not wrap around until until {{2080,1,19},{3,14,7}} GMT.
-spec cseq() -> 
    non_neg_integer().

cseq() ->
    case binary:encode_unsigned(timestamp()-1325376000) of  % Base is 1/1/2012
        <<_:1, CSeq:31>> -> ok;
        <<_:9, CSeq:31>> -> ok
    end,
    CSeq.   


%% @doc Generates a new printable random UUID.
-spec luid() -> 
    binary().

luid() ->
    lhash({make_ref(), os:timestamp()}).


%% @doc Generates a new printable SHA hash binary over `Base' (using 160 bits).
-spec lhash(term()) -> 
    binary().

lhash(Base) -> 
    <<I:160/integer>> = crypto:sha(term_to_binary(Base)),
    case encode_integer(I) of
        Hash when byte_size(Hash) =:= 27 -> Hash;
        Hash -> <<(binary:copy(<<"Z">>, 27-byte_size(Hash)))/binary, Hash/binary>>
    end.


%% @doc Generates a new random tag.
-spec uid() -> 
    binary().

uid() ->
    hash({make_ref(), os:timestamp()}).

%% @doc Generates a new random tag based on a value.
-spec hash(term()) -> 
    binary().

hash(Base) ->
    encode_integer(erlang:phash2([Base], 4294967296)).


%% @doc Get all local network ips.
-spec get_local_ips() -> 
    [inet:ip4_address()].

get_local_ips() ->
    {ok, All} = inet:getifaddrs(),
    lists:flatten([
        [{A,B,C,D} || {A,B,C,D} <- proplists:get_all_values(addr, Data)]
        || {_, Data} <- All
    ]).


%% @doc Equivalent to `find_main_ip(auto)'.
-spec find_main_ip() -> 
    inet:ip4_address().

find_main_ip() ->
    find_main_ip(auto).


%% @doc Finds the <i>best</i> local IP.
%% If a network interface is supplied (as "en0") it returns its ip.
%% If `auto' is used, probes `eth0', `eth1', `en0' and `en1'. If none is available returns 
%% any other of the host's addresses.
-spec find_main_ip(auto|string()) -> 
    inet:ip4_address().

find_main_ip(NetInterface) ->
    {ok, All} = inet:getifaddrs(),
    case NetInterface of
        auto ->
            IFaces = ["eth0", "eth1", "en0", "en1" | proplists:get_keys(All)],
            find_main_ip(IFaces, All);
        _ ->
            find_main_ip([NetInterface], All)   
    end.


%% @private
find_main_ip([], _) ->
    error(not_ip_found);

find_main_ip([IFace|R], All) ->
    Data = get_value(IFace, All, []),
    Flags = get_value(flags, Data, []),
    case lists:member(up, Flags) andalso lists:member(running, Flags) of
        true ->
            Addrs = lists:zip(
                proplists:get_all_values(addr, Data),
                proplists:get_all_values(netmask, Data)),
            case find_real_ip(Addrs) of
                error -> find_main_ip(R, All);
                Ip -> Ip
            end;
        false ->
            find_main_ip(R, All)
    end.

%% @private
find_real_ip([]) ->
    error;

find_real_ip([{{A,B,C,D}, Netmask}|_]) when Netmask =/= {255,255,255,255} ->
    {A,B,C,D};

find_real_ip([_|R]) ->
    find_real_ip(R).


% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).
-define(SECONDS_FROM_GREGORIAN_BASE_TO_EPOCH, (1970*365+478)*24*60*60).


%% @doc Gets an second-resolution timestamp
-spec timestamp() -> timestamp().

timestamp() ->
    {MegaSeconds, Seconds, _} = os:timestamp(),
    MegaSeconds*1000000 + Seconds.


%% @doc Gets an microsecond-resolution timestamp
-spec l_timestamp() -> l_timestamp().

l_timestamp() ->
    {N1, N2, N3} = os:timestamp(),
    (N1 * 1000000 + N2) * 1000000 + N3.


%% @doc Converts a `timestamp()' to a local `datetime()'.
-spec timestamp_to_local(timestamp()) -> 
    calendar:datetime().

timestamp_to_local(Secs) ->
    calendar:now_to_local_time({0, Secs, 0}).


%% @doc Converts a `timestamp()' to a gmt `datetime()'.
-spec timestamp_to_gmt(timestamp()) -> 
    calendar:datetime().

timestamp_to_gmt(Secs) ->
    calendar:now_to_universal_time({0, Secs, 0}).

%% @doc Generates a float representing `HHMMSS.MicroSecs' for a high resolution timer.
-spec l_timestamp_to_float(l_timestamp()) -> 
    float().

l_timestamp_to_float(LStamp) ->
    Timestamp = trunc(LStamp/1000000),
    {_, {H,Mi,S}} = nksip_lib:timestamp_to_local(Timestamp),
    Micro = LStamp-Timestamp*1000000,
    H*10000+Mi*100+S+(Micro/1000000).


%% @doc Converts a local `datetime()' to a `timestamp()',
-spec gmt_to_timestamp(calendar:datetime()) -> 
    timestamp().

gmt_to_timestamp(DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime) - 62167219200.


%% @doc Converts a gmt `datetime()' to a `timestamp()'.
-spec local_to_timestamp(calendar:datetime()) -> 
    timestamp().

local_to_timestamp(DateTime) ->
    case calendar:local_time_to_universal_time_dst(DateTime) of
        [First, _] -> gmt_to_timestamp(First);
        [Time] -> gmt_to_timestamp(Time);
        [] -> 0
    end.



%% @doc Equivalent to `proplists:get_value/2' but faster.
-spec get_value(term(), list()) -> 
    term().

get_value(Key, List) ->
    get_value(Key, List, undefined).


%% @doc Requivalent to `proplists:get_value/3' but faster.
-spec get_value(term(), list(), term()) -> 
    term().

get_value(Key, List, Default) ->
    case lists:keyfind(Key, 1, List) of
        {_, Value} -> Value;
        _ -> Default
    end.


%% @doc Similar to `get_value(Key, List, <<>>)' but converting the result into
%% a `binary()'.
-spec get_binary(term(), list()) -> 
    binary().

get_binary(Key, List) ->
    to_binary(get_value(Key, List, <<>>)).


%% @doc Similar to `get_value(Key, List, Default)' but converting the result into
%% a `binary()'.
-spec get_binary(term(), list(), term()) -> 
    binary().

get_binary(Key, List, Default) ->
    to_binary(get_value(Key, List, Default)).


%% @doc Similar to `get_value(Key, List, [])' but converting the result into a `list()'.
-spec get_list(term(), list()) -> 
    list().

get_list(Key, List) ->
    to_list(get_value(Key, List, [])).


%% @doc Similar to `get_value(Key, List, Default)' but converting the result
%% into a `list()'.
-spec get_list(term(), list(), term()) -> 
    list().

get_list(Key, List, Default) ->
    to_list(get_value(Key, List, Default)).


%% @doc Similar to `get_value(Key, List, 0)' but converting the result into 
%% an `integer()' or `error'.
-spec get_integer(term(), list()) -> 
    integer() | error. 

get_integer(Key, List) ->
    to_integer(get_value(Key, List, 0)).


%% @doc Similar to `get_value(Key, List, Default)' but converting the result into
%% a `integer()' or `error'.
-spec get_integer(term(), list(), term()) -> 
    integer() | error.

get_integer(Key, List, Default) ->
    to_integer(get_value(Key, List, Default)).


%% @doc Converts anything into a `binary()'. Can convert ip addresses also.
-spec to_binary(term()) -> 
    binary().

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, latin1);
to_binary(I) when is_integer(I) -> list_to_binary(erlang:integer_to_list(I));
to_binary(#uri{}=Uri) -> nksip_unparse:uri(Uri);
to_binary(#via{}=Via) -> nksip_unparse:via(Via);
to_binary({A,B,C,D}=Address) 
    when is_integer(A), is_integer(B), is_integer(C), is_integer(D) ->
    list_to_binary(inet_parse:ntoa(Address));
to_binary({A,B,C,D,E,F,G,H}=Address) 
    when is_integer(A), is_integer(B), is_integer(C), is_integer(D),
    is_integer(E), is_integer(F), is_integer(G), is_integer(H) ->
    list_to_binary(inet_parse:ntoa(Address));
to_binary(N) -> 
    msg("~p", [N]).


%% @doc Converts anything into a `string()'.
-spec to_list(string()|binary()|atom()|integer()) -> 
    string().

to_list(L) when is_list(L) -> L;
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(I) when is_integer(I) -> erlang:integer_to_list(I).


%% @doc Converts anything into a `integer()' or `error'.
-spec to_integer(integer()|binary()|string()) ->
    integer() | error.

to_integer(I) when is_integer(I) -> 
    I;
to_integer(B) when is_binary(B) -> 
    to_integer(binary_to_list(B));
to_integer(L) when is_list(L) -> 
    case catch list_to_integer(L) of
        I when is_integer(I) -> I;
        _ -> error
    end;
to_integer(_) ->
    error.


%% @doc Converts a `list()' or `binary()' into a `inet:ip_address()' or `error'.
-spec to_ip(string() | binary()) ->
    {ok, inet:ip_address()} | error.

to_ip(Address) when is_binary(Address) ->
    to_ip(binary_to_list(Address));

to_ip(Address) when is_list(Address) ->
    case inet_parse:address(Address) of
        {ok, Ip} -> {ok, Ip};
        _ -> error
    end.


% @doc converts a `string()' or `binary()' to a lower `binary()'.
-spec to_lower(string()|binary()|atom()) ->
    binary().

to_lower(List) when is_list(List) -> 
    list_to_binary(string:to_lower(List));
to_lower(Other) -> 
    to_lower(to_list(Other)).


% @doc converts a `string()' or `binary()' to an upper `binary()'.
-spec to_upper(string()|binary()|atom()) ->
    binary().
    
to_upper(List) when is_list(List) -> 
    list_to_binary(string:to_upper(List));
to_upper(Other) -> 
    to_upper(to_list(Other)).


%% @doc Generates a printable string from a big number using base 62.
-spec encode_integer(integer()) ->
    binary().

encode_integer(Int) ->
    list_to_binary(integer_to_list(Int, 62, [])).


%% @private
-spec integer_to_list(integer(), integer(), string()) -> 
    string().

integer_to_list(I0, Base, R0) ->
    D = I0 rem Base,
    I1 = I0 div Base,
    R1 = if 
        D >= 36 -> [D-36+$a|R0];
        D >= 10 -> [D-10+$A|R0];
        true -> [D+$0|R0]
    end,
    if 
        I1 =:= 0 -> R1;
       true -> integer_to_list(I1, Base, R1)
    end.


%% @doc Extracts all elements in `Proplist' having key `KeyOrKeys' or having key in 
%% `KeyOrKeys' if `KeyOrKeys' is a list.
-spec extract([term()], term() | [term()]) ->
    [term()].

extract(PropList, KeyOrKeys) ->
    Fun = fun(Term) ->
        if
            is_tuple(Term), is_list(KeyOrKeys) -> 
                lists:member(element(1, Term), KeyOrKeys);
            is_tuple(Term) ->
                element(1, Term) =:= KeyOrKeys;
            is_list(KeyOrKeys) -> 
                lists:member(Term, KeyOrKeys);
            Term =:= KeyOrKeys ->
                true;
            true ->
                false
        end
    end,
    lists:filter(Fun, PropList).


%% @doc Deletes all elements in `Proplist' having key `KeyOrKeys' or having key in 
%% `KeyOrKeys' if `KeyOrKeys' is a list.
-spec delete([term()], term() | [term()]) ->
    [term()].

delete(PropList, KeyOrKeys) ->
    Fun = fun(Term) ->
        if
            is_tuple(Term), is_list(KeyOrKeys) -> 
                not lists:member(element(1, Term), KeyOrKeys);
            is_tuple(Term) ->
                element(1, Term) =/= KeyOrKeys;
            is_list(KeyOrKeys) -> 
                not lists:member(Term, KeyOrKeys);
            Term =/= KeyOrKeys ->
                true;
            true ->
                false
        end
    end,
    lists:filter(Fun, PropList).


% @doc Checks if `Term' is a `string()' or `[]'.
-spec is_string(Term::term()) -> 
    boolean().

is_string([]) -> true;
is_string([F|R]) when is_integer(F) -> is_string(R);
is_string(_) -> false.


%% @doc Joins each element in `List' into a `binary()' using `<<",">>' as separator.
-spec bjoin(List::[term()]) ->
    binary().

bjoin(List) ->
    bjoin(List, <<",">>).

%% @doc Join each element in `List' into a `binary()', using the indicated `Separator'.
-spec bjoin(List::[term()], Separator::binary()) -> 
    binary().

bjoin([], _J) ->
    <<>>;
bjoin([Term], _J) ->
    to_binary(Term);
bjoin([First|Rest], J) ->
    bjoin2(Rest, to_binary(First), J).

bjoin2([[]|Rest], Acc, J) ->
    bjoin2(Rest, Acc, J);
bjoin2([Next|Rest], Acc, J) ->
    bjoin2(Rest, <<Acc/binary, J/binary, (to_binary(Next))/binary>>, J);
bjoin2([], Acc, _J) ->
    Acc.


%% @private
-spec hex(binary()|string()) -> 
    binary().

hex(B) when is_binary(B) -> hex(binary_to_list(B), []);
hex(S) -> hex(S, []).


%% @private
hex([], Res) -> list_to_binary(lists:reverse(Res));
hex([N|Ns], Acc) -> hex(Ns, [digit(N rem 16), digit(N div 16)|Acc]).


%% @private
digit(D) when (D >= 0) and (D < 10) -> D + 48;
digit(D) -> D + 87.


%% @doc Gets the subbinary after `Char'.
-spec bin_last(char(), binary()) ->
    binary().

bin_last(Char, Bin) ->
    case binary:match(Bin, <<Char>>) of
        {First, 1} -> binary:part(Bin, First+1, byte_size(Bin)-First-1);
        _ -> <<>>
    end.



%% @doc Cancels and existig timer.
-spec cancel_timer(reference()|undefined) ->
    false | integer().

cancel_timer(Ref) when is_reference(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive {timeout, Ref, _} -> 0
            after 0 -> false 
            end;
        RemainingTime ->
            RemainingTime
    end;

cancel_timer(_) ->
    false.


%% @private
-spec msg(string(), [term()]) -> 
    binary().

msg(Msg, Vars) ->
    case catch list_to_binary(io_lib:format(Msg, Vars)) of
        {'EXIT', _} -> <<"Msg parser error">>;
        Result -> Result
    end.



%% ===================================================================
%% EUnit tests
%% ===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

bjoin_test() ->
    ?assertMatch(<<"hi">>, bjoin([<<"hi">>], <<"any">>)),
    ?assertMatch(<<"hianyhi">>, bjoin([<<"hi">>, <<"hi">>], <<"any">>)),
    ?assertMatch(<<"hi1_hi2_hi3">>, bjoin([<<"hi1">>, <<"hi2">>, <<"hi3">>], <<"_">>)).

tokenize_test() -> 
    R1 = [
        [{"this"}, {"is"}, {"\"an, example\""}],
        [{"and"}, $;, {"this"}, $<, {"is"}, $;, {"\" other, \""}, {"bye"}, $>]
    ],
    ?assert(
        R1=:=tokenize("this is \"an, example\", and; this < is ; \" other, \" bye> ", uri)),
    ?assertMatch("this is \"an, example\",and;this<is;\" other, \" bye>",
        lists:flatten(untokenize(R1))).

-endif.





