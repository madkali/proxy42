-module(proxy42_authenticate_middleware).
-behaviour(cowboyku_middleware).
-export([execute/2]).

execute(Req, Env) ->
  {Log, Req1} = cowboyku_req:meta(logging, Req),
  Log1 = vegur_req_log:stamp(pre_auth, Log),
  Req2 = cowboyku_req:set_meta(logging, Log1, Req1),
  {InterfaceModule, HandlerState, Req3} = vegur_utils:get_interface_module(Req2),
  % Authconfig is a list of tuples {Type, Key, Mode}
  % Type can be header or qs (Query string)
  % Key should be name of header or query parameter depending on Type
  % Mode can be keep or strip, and will decide if the header or query param
  % will be consumed by us or retained in the request.
  {AuthConfig, Req4, HandlerState1} = InterfaceModule:auth_config(Req3, HandlerState),
  {Strategy, StrategyConfig} = AuthConfig,
  HeadersAndQueryParams = apply(Strategy, auth_parameters, [StrategyConfig]),
  AuthInfoRev = lists:foldl(
                  fun (X, Acc) -> [extract(X, Req4) | Acc] end,
                  [],
                  HeadersAndQueryParams),
  AuthInfo = lists:reverse(AuthInfoRev),
  Req5 = Req4,
  {AuthResult, Req6, HandlerState3} = InterfaceModule:auth(AuthInfo, Req5, HandlerState1),
  Req7 = vegur_utils:set_handler_state(HandlerState3, Req6),
  case AuthResult of
    allow -> {ok, Req7, Env};
    {rate_limit, User} -> handle_rate_limit(User, Req7, Env);
    deny -> {error, 403, Req7}
  end.


handle_rate_limit(User, Req, Env) ->
  {InterfaceModule, HandlerState, Req1} = vegur_utils:get_interface_module(Req),
  {RL, HandlerState1} = InterfaceModule:rate_limit(User, Req1, HandlerState),
  Req2 = vegur_utils:set_handler_state(HandlerState1, Req1),
  case RL of
    allow ->
      {ok, Req2, Env};
    {allow, Limit, Remaining, Reset} ->
      % BCP 178 deprecates X- prefix in headers.
      % https://tools.ietf.org/html/bcp178
      L = str(Limit), Rem = str(Remaining), Rst = str(Reset),
      Req3 = cowboyku_req:set_resp_header(<<"RateLimit-Limit">>, L, Req2),
      Req4 = cowboyku_req:set_resp_header(<<"RateLimit-Remaining">>, Rem, Req3),
      Req5 = cowboyku_req:set_resp_header(<<"RateLimit-Reset">>, Rst, Req4),
      {ok, Req5, Env};
    deny ->
      {error, 429, Req2};
    {deny, RetryAfter} ->
      RA = str(RetryAfter),
      Req3 = cowboyku_req:set_resp_header(<<"Retry-After">>, RA, Req2),
      {error, 429, Req3}
  end.

extract({header, Header, Mode}, Req) ->
  {Val, _Req} =  cowboyku_req:header(Header, Req),
  % Can be undefined
  {header, Header, Val};
extract({query, Param, Mode}, Req) ->
  %% TODO handle mode
  % Can be undefined
  Val = cowboyku_req:qs_val(Param, Req),
  {query, Param, Val}.

str(X) when is_integer(X) -> erlang:integer_to_binary(X);
str(X) when is_binary(X) -> X;
str(X) when is_list(X) -> X.