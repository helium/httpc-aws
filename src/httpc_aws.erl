%% ====================================================================
%% @author Gavin M. Roy <gavinmroy@gmail.com>
%% @copyright 2016, Gavin M. Roy
%% @doc httpc_aws client library
%% @end
%% ====================================================================
-module(httpc_aws).

-behavior(gen_server).

%% API exports
-export([delete/4,
         get/3, get/4,
         post/5, put/5,
         request/6, request/7, request/8,
         set_credentials/3,
         set_region/2]).

%% gen-server exports
-export([start_link/0,
         init/1,
         terminate/2,
         code_change/3,
         handle_call/3,
         handle_cast/2,
         handle_info/2]).

%% Export all for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-define(REQUEST_TIMEOUT, 120000).

-include("httpc_aws.hrl").

%%====================================================================
%% exported wrapper functions
%%====================================================================

-spec delete(Pid :: pid(),
             Service :: string(),
             Path :: file:filename_all(),
             Headers :: headers()) -> result().
%% @doc Perform a HTTP DELETE request to the AWS API for the specified service. The
%%      response will automatically be decoded if it is either in JSON or XML
%%      format.
%% @end
delete(Pid, Service, Path, Headers) ->
  request(Pid, Service, delete, Path, "", Headers).

-spec get(Pid :: pid(),
          Service :: string(),
          Path :: path()) -> result().
%% @doc Perform a HTTP GET request to the AWS API for the specified service. The
%%      response will automatically be decoded if it is either in JSON or XML
%%      format.
%% @end
get(Pid, Service, Path) ->
  get(Pid, Service, Path, []).


-spec get(Pid :: pid(),
          Service :: string(),
          Path :: path(),
          Headers :: headers()) -> result().
%% @doc Perform a HTTP GET request to the AWS API for the specified service. The
%%      response will automatically be decoded if it is either in JSON or XML
%%      format.
%% @end
get(Pid, Service, Path, Headers) ->
  request(Pid, Service, get, Path, "", Headers).


-spec post(Pid :: pid(),
           Service :: string(),
           Path :: path(),
           Body :: body(),
           Headers :: headers()) -> result().
%% @doc Perform a HTTP Post request to the AWS API for the specified service. The
%%      response will automatically be decoded if it is either in JSON or XML
%%      format.
%% @end
post(Pid, Service, Path, Body, Headers) ->
  request(Pid, Service, post, Path, Body, Headers).

-spec put(Pid :: pid(),
          Service :: string(),
          Path :: path(),
          Body :: body(),
          Headers :: headers()) -> result().
%% @doc Perform a HTTP Put request to the AWS API for the specified service. The
%%      response will automatically be decoded if it is either in JSON or XML
%%      format.
%% @end
put(Pid, Service, Path, Body, Headers) ->
  request(Pid, Service, put, Path, Body, Headers).

-spec request(Pid :: pid(),
              Service :: string(),
              Method :: method(),
              Path :: file:filename_all(),
              Body :: body(),
              Headers :: headers()) -> result().
%% @doc Perform a HTTP request to the AWS API for the specified service. The
%%      response will automatically be decoded if it is either in JSON or XML
%%      format.
%% @end
request(Pid, Service, Method, Path, Body, Headers) ->
  gen_server:call(Pid, {request, Service, Method, Headers, Path, Body, [], undefined}).


-spec request(Pid :: pid(),
              Service :: string(),
              Method :: method(),
              Path :: file:filename_all(),
              Body :: body(),
              Headers :: headers(),
              HTTPOptions :: http_options()) -> result().
%% @doc Perform a HTTP request to the AWS API for the specified service. The
%%      response will automatically be decoded if it is either in JSON or XML
%%      format.
%% @end
request(Pid, Service, Method, Path, Body, Headers, HTTPOptions) ->
  gen_server:call(Pid, {request, Service, Method, Headers, Path, Body, HTTPOptions, undefined}).


-spec request(Pid :: pid(),
              Service :: string(),
              Method :: method(),
              Path :: file:filename_all(),
              Body :: body(),
              Headers :: headers(),
              HTTPOptions :: http_options(),
              Endpoint :: host()) -> result().
%% @doc Perform a HTTP request to the AWS API for the specified service, overriding
%%      the endpoint URL to use when invoking the API. This is useful for local testing
%%      of services such as DynamoDB. The response will automatically be decoded
%%      if it is either in JSON or XML format.
%% @end
request(Pid, Service, Method, Path, Body, Headers, HTTPOptions, Endpoint) ->
  gen_server:call(Pid, {request, Service, Method, Headers, Path, Body, HTTPOptions, Endpoint}).


-spec set_credentials(pid(), access_key(), secret_access_key()) -> ok.
%% @doc Manually set the access credentials for requests. This should
%%      be used in cases where the client application wants to control
%%      the credentials instead of automatically discovering them from
%%      configuration or the AWS Instance Metadata service.
%% @end
set_credentials(Pid, AccessKey, SecretAccessKey) ->
  gen_server:call(Pid, {set_credentials, AccessKey, SecretAccessKey}).


-spec set_region(Pid :: pid(), Region :: string()) -> ok.
%% @doc Manually set the AWS region to perform API requests to.
%% @end
set_region(Pid, Region) ->
  gen_server:call(Pid, {set_region, Region}).


%%====================================================================
%% gen_server functions
%%====================================================================

start_link() ->
  gen_server:start_link(?MODULE, [], []).


-spec init(list()) -> {ok, state()}.
init([]) ->
  {ok, Region} = httpc_aws_config:region(),
  {_, State} = load_credentials(#state{region = Region}),
  {ok, State}.

terminate(_, _) ->
  ok.

code_change(_, _, State) ->
  {ok, State}.

handle_call({request, Service, Method, Headers, Path, Body, Options, Host}, _From, State) ->
  {Response, NewState} = perform_request(State, Service, Method, Headers, Path, Body, Options, Host),
  {reply, Response, NewState};

handle_call(get_state, _, State) ->
  {reply, {ok, State}, State};

handle_call(refresh_credentials, _, State) ->
  {Reply, NewState} = load_credentials(State),
  {reply, Reply, NewState};

handle_call({set_credentials, AccessKey, SecretAccessKey}, _, State) ->
  {reply, ok, State#state{access_key = AccessKey,
                          secret_access_key = SecretAccessKey,
                          security_token = undefined,
                          expiration = undefined,
                          error = undefined,
                          region = State#state.region}};

handle_call({set_region, Region}, _, State) ->
  {reply, ok, State#state{access_key = State#state.access_key,
                         secret_access_key = State#state.secret_access_key,
                         security_token = State#state.security_token,
                         expiration = State#state.expiration,
                         error = State#state.error,
                         region = Region}};

handle_call(_Request, _From, State) ->
  {noreply, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

%%====================================================================
%% Internal functions
%%====================================================================

-spec endpoint(State :: state(), Host :: string(),
               Service :: string(), Path :: string()) -> string().
%% @doc Return the endpoint URL, either by constructing it with the service
%%      information passed in or by using the passed in Host value.
%% @ednd
endpoint(#state{region = Region}, undefined, Service, Path) ->
  lists:flatten(["https://", endpoint_host(Region, Service), Path]);
endpoint(_, Host, _, Path) ->
  lists:flatten(["https://", Host, Path]).


-spec endpoint_host(Region :: region(), Service :: string()) -> host().
%% @doc Construct the endpoint hostname for the request based upon the service
%%      and region.
%% @end
endpoint_host(Region, Service) ->
  lists:flatten(string:join([Service, Region, endpoint_tld(Region)], ".")).


-spec endpoint_tld(Region :: region()) -> host().
%% @doc Construct the endpoint hostname TLD for the request based upon the region.
%%      See https://docs.aws.amazon.com/general/latest/gr/rande.html#ec2_region for details.
%% @end
endpoint_tld("cn-north-1") ->
    "amazonaws.com.cn";
endpoint_tld("cn-northwest-1") ->
    "amazonaws.com.cn";
endpoint_tld(_Other) ->
    "amazonaws.com".


-spec format_response(Response :: httpc_result()) -> result().
%% @doc Format the httpc response result, returning the request result data
%% structure. The response body will attempt to be decoded by invoking the
%% maybe_decode_body/2 method.
%% @end
format_response({ok, {{_Version, 200, _Message}, Headers, Body}}) ->
  {ok, {Headers, maybe_decode_body(get_content_type(Headers), Body)}};
format_response({ok, {{_Version, 204, _Message}, Headers, _Body}}) ->
  {ok, {Headers, []}};
format_response({ok, {{_Version, StatusCode, Message}, Headers, Body}}) when StatusCode >= 400 ->
  {error, Message, {Headers, maybe_decode_body(get_content_type(Headers), Body)}};
format_response({error, Reason}) ->
  {error, Reason, undefined}.

-spec get_content_type(Headers :: headers()) -> {Type :: string(), Subtype :: string()}.
%% @doc Fetch the content type from the headers and return it as a tuple of
%%      {Type, Subtype}.
%% @end
get_content_type(Headers) ->
  Value = case proplists:get_value("content-type", Headers, undefined) of
    undefined ->
      proplists:get_value("Content-Type", Headers, "text/xml");
    Other -> Other
  end,
  parse_content_type(Value).


-spec has_credentials(state()) -> true | false.
%% @doc check to see if there are credentials made available in the current state
%%      returning false if not or if they have expired.
%% @end
has_credentials(#state{error = Error}) when Error /= undefined -> false;
has_credentials(#state{access_key = Key}) when Key /= undefined -> true;
has_credentials(_) -> false.


-spec expired_credentials(Expiration :: expiration() | undefined) -> true | false.
%% @doc Indicates if the date that is passed in has expired.
%% end
expired_credentials(undefined) -> false;
expired_credentials(Expiration) ->
  Now = calendar:datetime_to_gregorian_seconds(local_time()),
  Expires = calendar:datetime_to_gregorian_seconds(Expiration),
  Now >= Expires.


-spec load_credentials(State :: state()) -> {ok | error, state()}.
%% @doc Load the credentials using the following order of configuration precedence:
%%        - Environment variables
%%        - Credentials file
%%        - EC2 Instance Metadata Service
%% @end
load_credentials(#state{region = Region}) ->
  load_credentials(httpc_aws_config:credentials(), Region).

-spec load_credentials(security_credentials() | sc_error(), Region :: region() | undefined) -> {ok | error, state()}.
load_credentials({ok, AccessKey, SecretAccessKey, Expiration, SecurityToken}, Region) ->
      {ok, #state{region = Region,
                  error = undefined,
                  access_key = AccessKey,
                  secret_access_key = SecretAccessKey,
                  expiration = Expiration,
                  security_token = SecurityToken}};
load_credentials({error, Reason}, Region) ->
      error_logger:error_msg("Could not load AWS credentials from environment variables, AWS_CONFIG_FILE, AWS_SHARED_CREDENTIALS_FILE or EC2 metadata endpoint: ~p.~n", [Reason]),
      {error, #state{region = Region,
                     error = Reason,
                     access_key = undefined,
                     secret_access_key = undefined,
                     expiration = undefined,
                     security_token = undefined}}.

-spec local_time() -> calendar:datetime().
%% @doc Return the current local time.
%% @end
local_time() ->
  [Value] = calendar:local_time_to_universal_time_dst(calendar:local_time()),
  Value.


-spec maybe_decode_body(ContentType :: {nonempty_string(), nonempty_string()}, Body :: body()) -> list() | body().
%% @doc Attempt to decode the response body based upon the mime type that is
%%      presented.
%% @end.
maybe_decode_body({"application", "x-amz-json-1.0"}, Body) ->
  httpc_aws_json:decode(Body);
maybe_decode_body({"application", "json"}, Body) ->
  httpc_aws_json:decode(Body);
maybe_decode_body({_, "xml"}, Body) ->
  httpc_aws_xml:parse(Body);
maybe_decode_body(_ContentType, Body) ->
  Body.


-spec parse_content_type(ContentType :: string()) -> {Type :: string(), Subtype :: string()}.
%% @doc parse a content type string returning a tuple of type/subtype
%% @end
parse_content_type(ContentType) ->
  Parts = string:tokens(ContentType, ";"),
  [Type, Subtype] = string:tokens(lists:nth(1, Parts), "/"),
  {Type, Subtype}.


-spec perform_request(State :: state(),
                      Service :: string(),
                      Method :: method(),
                      Headers :: headers(),
                      Path :: file:filename_all(),
                      Body :: body(),
                      Options :: http_options(),
                      Host :: host())
    -> {Result :: result(), NewState :: state()}.
%% @doc Make the API request and return the formatted response.
%% @end
perform_request(State, Service, Method, Headers, Path, Body, Options, Host) ->
  perform_request_has_creds(has_credentials(State), State, Service, Method,
                            Headers, Path, Body, Options, Host).


-spec perform_request_has_creds(true | false,
                                State :: state(),
                                Service :: string(),
                                Method :: method(),
                                Headers :: headers(),
                                Path :: file:filename_all(),
                                Body :: body(),
                                Options :: http_options(),
                                Host :: host())
    -> {Result :: result(), NewState :: state()}.
%% @doc Invoked after checking to see if there are credentials. If there are,
%%      validate they have not or will not expire, performing the request if not,
%%      otherwise return an error result.
%% @end
perform_request_has_creds(true, State, Service, Method, Headers, Path, Body, Options, Host) ->
  perform_request_creds_expired(expired_credentials(State#state.expiration), State,
                                Service, Method, Headers, Path, Body, Options, Host);
perform_request_has_creds(false, State, _, _, _, _, _, _, _) ->
  perform_request_creds_error(State).


-spec perform_request_creds_expired(true | false,
                                    State :: state(),
                                    Service :: string(),
                                    Method :: method(),
                                    Headers :: headers(),
                                    Path :: file:filename_all(),
                                    Body :: body(),
                                    Options :: http_options(),
                                    Host :: host())
  -> {Result :: result(), NewState :: state()}.
%% @doc Invoked after checking to see if the current credentials have expired.
%%      If they haven't, perform the request, otherwise try and refresh the
%%      credentials before performing the request.
%% @end
perform_request_creds_expired(false, State, Service, Method, Headers, Path, Body, Options, Host) ->
  perform_request_with_creds(State, Service, Method, Headers, Path, Body, Options, Host);
perform_request_creds_expired(true, State, Service, Method, Headers, Path, Body, Options, Host) ->
  perform_request_creds_refreshed(load_credentials(State), Service, Method, Headers, Path, Body, Options, Host).


-spec perform_request_creds_refreshed({ok | error, State :: state()},
                                      Service :: string(),
                                      Method :: method(),
                                      Headers :: headers(),
                                      Path :: file:filename_all(),
                                      Body :: body(),
                                      Options :: http_options(),
                                      Host :: host())
    -> {Result :: result(), NewState :: state()}.
%% @doc If it's been determined that there are credentials but they have expired,
%%      check to see if the credentials could be loaded and either make the request
%%      or return an error.
%% @end
perform_request_creds_refreshed({ok, State}, Service, Method, Headers, Path, Body, Options, Host) ->
  perform_request_with_creds(State, Service, Method, Headers, Path, Body, Options, Host);
perform_request_creds_refreshed({error, State}, _, _, _, _, _, _, _) ->
  perform_request_creds_error(State).


-spec perform_request_with_creds(State :: state(),
                                 Service :: string(),
                                 Method :: method(),
                                 Headers :: headers(),
                                 Path :: file:filename_all(),
                                 Body :: body(),
                                 Options :: http_options(),
                                 Host :: host())
    -> {Result :: result(), NewState :: state()}.
%% @doc Once it is validated that there are credentials to try and that they have not
%%      expired, perform the request and return the response.
%% @end
perform_request_with_creds(State, Service, Method, Headers, Path, Body, Options, Host) ->
  URI = endpoint(State, Host, Service, Path),
  SignedHeaders = sign_headers(State, Service, Method, URI, Headers, Body),
  ContentType = proplists:get_value("content-type", SignedHeaders, undefined),
  perform_request_with_creds(State, Method, URI, SignedHeaders, ContentType, Body, Options).


-spec perform_request_with_creds(State :: state(),
                                 Method :: method(),
                                 URI :: string(),
                                 Headers :: headers(),
                                 ContentType :: string() | undefined,
                                 Body :: body(),
                                 Options :: http_options())
    -> {Result :: result(), NewState :: state()}.
%% @doc Once it is validated that there are credentials to try and that they have not
%%      expired, perform the request and return the response.
%% @end
perform_request_with_creds(State, Method, URI, Headers, undefined, "", Options) when Method /= put, Method /= post ->
  Response = httpc:request(Method, {URI, Headers}, Options, []),
  {format_response(Response), State};
perform_request_with_creds(State, Method, URI, Headers, ContentType, Body, Options) ->
  Response = httpc:request(Method, {URI, Headers, ContentType, Body}, Options, []),
  {format_response(Response), State}.


-spec perform_request_creds_error(State :: state()) -> {{error, {credentials, any()}}, NewState :: state()}.
%% @doc Return the error response when there are not any credentials to use with
%%      the request.
%% @end
perform_request_creds_error(State) ->
  {{error, {credentials, State#state.error}}, State}.


-spec sign_headers(State :: state(),
                   Service :: string(),
                   Method :: method(),
                   URI :: string(),
                   Headers :: headers(),
                   Body :: body()) -> headers().
%% @doc Build the signed headers for the API request.
%% @end
sign_headers(#state{access_key = AccessKey,
                    secret_access_key = SecretKey,
                    security_token = SecurityToken,
                    region = Region}, Service, Method, URI, Headers, Body) ->
  httpc_aws_sign:headers(#request{access_key = AccessKey,
                                  secret_access_key = SecretKey,
                                  security_token = SecurityToken,
                                  region = Region,
                                  service = Service,
                                  method = Method,
                                  uri = URI,
                                  headers = Headers,
                                  body = Body}).
