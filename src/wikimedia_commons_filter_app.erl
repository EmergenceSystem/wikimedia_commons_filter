%%%-------------------------------------------------------------------
%%% @doc Wikimedia Commons media agent.
%%%
%%% Searches commons.wikimedia.org (namespace 6 = File) and returns
%%% image/audio/video media embryos, media_type derived from the file
%%% mime. Keyless.
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(wikimedia_commons_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(API,
    "https://commons.wikimedia.org/w/api.php?action=query&generator=search"
    "&gsrnamespace=6&gsrlimit=12&prop=imageinfo"
    "&iiprop=url%7Cmime%7Cextmetadata&iiurlwidth=320&format=json&origin=*"
    "&gsrsearch=").
-define(UA, "wikimedia_commons_filter/1.0 (EmergenceSystem)").

base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"image">>, <<"photo">>, <<"picture">>,
                                      <<"audio">>, <<"sound">>, <<"video">>,
                                      <<"commons">>, <<"wikimedia">>, <<"media">>].

start(_Type, _Args) ->
    case wikimedia_commons_filter_sup:start_link() of
        {ok, Pid} -> ok = start_pop_and_http(), {ok, Pid};
        Error -> Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(wikimedia_commons_filter_query_listener),
    catch em_pop_sup:stop_node(wikimedia_commons_filter),
    ok.

start_pop_and_http() ->
    PopPort   = application:get_env(wikimedia_commons_filter, pop_port,   9524),
    QueryPort = application:get_env(wikimedia_commons_filter, query_port, 9525),
    Seeds     = application:get_env(wikimedia_commons_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(wikimedia_commons_filter),
    catch cowboy:stop_listener(wikimedia_commons_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(wikimedia_commons_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end, Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => wikimedia_commons_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(wikimedia_commons_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[wikimedia_commons_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

generate_embryo_list(Body) ->
    case extract_query(Body) of
        "" -> [];
        Query ->
            Url = ?API ++ uri_string:quote(Query),
            Headers = [{"User-Agent", ?UA}],
            case httpc:request(get, {Url, Headers},
                               [{timeout, 8000}, {ssl, [{verify, verify_none}]}],
                               [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, RBody}} ->
                    case catch json:decode(RBody) of
                        #{<<"query">> := #{<<"pages">> := Pages}} when is_map(Pages) ->
                            lists:filtermap(fun page_embryo/1, maps:values(Pages));
                        _ -> []
                    end;
                _ -> []
            end
    end.

extract_query(Body) ->
    try json:decode(Body) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map,
                           maps:get(<<"query">>, Map, <<"">>)));
        _ -> binary_to_list(Body)
    catch _:_ -> binary_to_list(Body) end.

page_embryo(#{<<"title">> := Title, <<"imageinfo">> := [II | _]}) ->
    case mtype(maps:get(<<"mime">>, II, <<>>)) of
        undefined -> false;
        Type ->
            Em  = maps:get(<<"extmetadata">>, II, #{}),
            P0 = #{
                <<"media_type">> => Type,
                <<"title">>      => strip_file(Title),
                <<"media_url">>  => maps:get(<<"url">>, II, <<>>),
                <<"url">>        => maps:get(<<"descriptionurl">>, II,
                                    maps:get(<<"url">>, II, <<>>)),
                <<"source">>     => <<"wikimedia commons">>
            },
            P1 = put_opt(P0, <<"thumbnail">>, maps:get(<<"thumburl">>, II, null)),
            P2 = put_opt(P1, <<"license">>,  ex(Em, <<"LicenseShortName">>)),
            P3 = put_opt(P2, <<"author">>,   strip_html(ex(Em, <<"Artist">>))),
            {true, #{<<"properties">> => P3}}
    end;
page_embryo(_) -> false.

mtype(<<"image/", _/binary>>) -> <<"image">>;
mtype(<<"audio/", _/binary>>) -> <<"audio">>;
mtype(<<"video/", _/binary>>) -> <<"video">>;
mtype(_) -> undefined.

strip_file(<<"File:", Rest/binary>>) -> Rest;
strip_file(T) -> T.

ex(Em, Key) ->
    case maps:get(Key, Em, undefined) of
        #{<<"value">> := V} when is_binary(V) -> V;
        _ -> null
    end.

strip_html(null) -> null;
strip_html(B) when is_binary(B) ->
    Stripped = re:replace(B, "<[^>]*>", "", [global, {return, binary}]),
    Trimmed  = string:trim(Stripped),
    case Trimmed of <<>> -> null; _ -> Trimmed end.

put_opt(M, _K, null)      -> M;
put_opt(M, _K, <<>>)      -> M;
put_opt(M, K, V) when is_binary(V) -> M#{K => V};
put_opt(M, _K, _)         -> M.
