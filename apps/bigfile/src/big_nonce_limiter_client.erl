-module(big_nonce_limiter_client).

-behaviour(gen_server).

-export([start_link/0, maybe_request_sessions/1]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_config.hrl").

-record(state, {
	remote_servers,
	latest_session_keys = #{},
	%% request_sessions is set to true when the node is unable to validate a block due
	%% to a gap in its cached step numbers. When true, the node will query the full
	%% session and previous session from a VDF server.
	request_sessions = false
}).

-define(PULL_FREQUENCY_MS, 800).
-define(NO_UPDATE_PULL_FREQUENCY_MS, 200).
-define(PULL_THROTTLE_MS, 200).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Look at the session key of the last update from the VDF server we are currently
%% working with and in case it does not match the given session key, request complete
%% sessions from this VDF server.
%%
%% The client may need this additional request around a VDF reset when a new session is
%% created but the previous session is not completed because the VDF server instantiated
%% the new session before sending the last computed output(s) of the previous session to
%% the client.
maybe_request_sessions(SessionKey) ->
	gen_server:cast(?MODULE, {maybe_request_sessions, SessionKey}).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	case big_config:use_remote_vdf_server() andalso big_config:pull_from_remote_vdf_server() of
		false ->
			ok;
		true ->
			gen_server:cast(?MODULE, pull)
	end,
	{ok, Config} = application:get_env(bigfile, config),
	Now =  erlang:system_time(millisecond),
	RawPeersWithTimestamp = queue:from_list([{RawPeer, Now-?PULL_THROTTLE_MS}
			|| RawPeer <- Config#config.nonce_limiter_server_trusted_peers]),
	{ok, #state{ remote_servers = RawPeersWithTimestamp }}.

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_cast(pull, State) ->
	#state{ remote_servers = Q } = State,
	{{value, {RawPeer, Timestamp}}, Q2} = queue:out(Q),
	Now = erlang:system_time(millisecond),
	RotatedServers = queue:in({RawPeer, Now}, Q2),
	case Now < Timestamp + ?PULL_THROTTLE_MS of
		true ->
			big_util:cast_after(?PULL_THROTTLE_MS, ?MODULE, pull),
			{noreply, State};
		false ->
			case big_peers:resolve_and_cache_peer(RawPeer, vdf_server_peer) of
				{error, _} ->
					?LOG_WARNING([{event, failed_to_resolve_peer},
							{raw_peer, io_lib:format("~p", [RawPeer])}]),
					gen_server:cast(?MODULE, pull),
					%% Push the peer to the back of the queue.
					{noreply, State#state{ remote_servers = RotatedServers }};
				{ok, Peer} ->
					case big_http_iface_client:get_vdf_update(Peer) of
						{ok, Update} ->
							#nonce_limiter_update{ session_key = SessionKey,
									session = #vdf_session{
											step_number = SessionStepNumber } } = Update,
							State2 = update_latest_session_key(Peer, SessionKey, State),
							UpdateResponse =
								big_nonce_limiter:apply_external_update(Update, Peer),

							SessionFound = case UpdateResponse of
								#nonce_limiter_update_response{ session_found = false } ->
									false;
								_ ->
									true
							end,
							RequestSessions = (
								State2#state.request_sessions == true orelse
								not SessionFound
							),

							case RequestSessions of
								true ->
									case fetch_and_apply_session_and_previous_session(Peer) of
										{error, _} ->
											gen_server:cast(?MODULE, pull),
											{noreply, State2#state{
													remote_servers = RotatedServers }};
										_ ->
											big_util:cast_after(?PULL_FREQUENCY_MS,
													?MODULE, pull),
											{noreply, State2#state{ request_sessions = false }}
									end;
								false ->
									case UpdateResponse of
										ok ->
											big_util:cast_after(?PULL_FREQUENCY_MS, ?MODULE, pull),
											{noreply, State2};
										#nonce_limiter_update_response{ step_number = StepNumber }
												when StepNumber > SessionStepNumber ->
											%% We are ahead of the server - may be, it is not
											%% the fastest server in the list so try another one,
											%% if there are more servers in the configuration
											%% and they are not on timeout.
											gen_server:cast(?MODULE, pull),
											{noreply, State2#state{
													remote_servers = RotatedServers }};
										#nonce_limiter_update_response{ step_number = StepNumber }
												when StepNumber == SessionStepNumber ->
											%% We are in sync with the server. Re-try soon.
											big_util:cast_after(?NO_UPDATE_PULL_FREQUENCY_MS,
													?MODULE, pull),
											{noreply, State2};
										_ ->
											%% We have received a partial session, but there's a gap
											%% in the step numbers, e.g., the update we received is at
											%% step 100, but our last seen step was 90.
											case fetch_and_apply_session(Peer) of
												{error, _} ->
													gen_server:cast(?MODULE, pull),
													{noreply, State2#state{
															remote_servers = RotatedServers }};
												_ ->
													big_util:cast_after(?PULL_FREQUENCY_MS,
															?MODULE, pull),
													{noreply, State2}
											end
									end
							end;
						{error, not_found} ->
							?LOG_WARNING([{event, failed_to_fetch_vdf_update},
									{peer, big_util:format_peer(Peer)},
									{error, not_found}]),
							%% The server might be restarting.
							%% Try another one, if there are any.
							gen_server:cast(?MODULE, pull),
							{noreply, State#state{ remote_servers = RotatedServers }};
						{error, Reason} ->
							?LOG_WARNING([{event, failed_to_fetch_vdf_update},
									{peer, big_util:format_peer(Peer)},
									{error, io_lib:format("~p", [Reason])}]),
							%% Try another server, if there are any.
							gen_server:cast(?MODULE, pull),
							{noreply, State#state{ remote_servers = RotatedServers }}
					end
			end
	end;

handle_cast({maybe_request_sessions, SessionKey}, State) ->
	#state{ remote_servers = Q } = State,
	{{value, {RawPeer, _Timestamp}}, Q2} = queue:out(Q),
	Now = erlang:system_time(millisecond),
	RotatedServers = queue:in({RawPeer, Now}, Q2),
	case big_peers:resolve_and_cache_peer(RawPeer, vdf_server_peer) of
		{error, _} ->
			%% Push the peer to the back of the queue. We'll also wait and see if another
			%% `maybe_request_sessions` message comes in before we fetch the full session.
			{noreply, State#state{ remote_servers = RotatedServers }};
		{ok, Peer} ->
			case get_latest_session_key(Peer, State) of
				SessionKey ->
					%% No reason to make extra requests. And don't rotate the peers.
					{noreply, State};
				_ ->
					%% Ensure the current and previous sessions are fetched and applied on
					%% the next `pull` message.
					{noreply, State#state{ request_sessions = true }}
			end
	end;

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_info(Message, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {message, Message}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

fetch_and_apply_session_and_previous_session(Peer) ->
	case big_http_iface_client:get_vdf_session(Peer) of
		{ok, #nonce_limiter_update{ session = #vdf_session{
				prev_session_key = PrevSessionKey } } = Update} ->
			case big_http_iface_client:get_previous_vdf_session(Peer) of
				{ok, #nonce_limiter_update{ session_key = PrevSessionKey } = Update2} ->
					big_nonce_limiter:apply_external_update(Update2, Peer),
					big_nonce_limiter:apply_external_update(Update, Peer);
				{ok, _} ->
					%% The session should have just changed, retry.
					fetch_and_apply_session_and_previous_session(Peer);
				{error, Reason} = Error ->
					?LOG_WARNING([{event, failed_to_fetch_previous_vdf_session},
						{peer, big_util:format_peer(Peer)},
						{error, io_lib:format("~p", [Reason])}]),
					Error
			end;
		{error, Reason2} = Error2 ->
			?LOG_WARNING([{event, failed_to_fetch_vdf_session},
				{peer, big_util:format_peer(Peer)},
				{error, io_lib:format("~p", [Reason2])}]),
			Error2
	end.

fetch_and_apply_session(Peer) ->
	case big_http_iface_client:get_vdf_session(Peer) of
		{ok, Update} ->
			big_nonce_limiter:apply_external_update(Update, Peer);
		{error, Reason} = Error ->
			?LOG_WARNING([{event, failed_to_fetch_vdf_session},
					{peer, big_util:format_peer(Peer)},
					{error, io_lib:format("~p", [Reason])}]),
			Error
	end.

get_latest_session_key(Peer, State) ->
	#state{ latest_session_keys = Map } = State,
	maps:get(Peer, Map, not_found).

update_latest_session_key(Peer, SessionKey, State) ->
	#state{ latest_session_keys = Map } = State,
	State#state{ latest_session_keys = maps:put(Peer, SessionKey, Map) }.
