-module(big_nonce_limiter_server_worker).

-behaviour(gen_server).

-export([start_link/2]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("bigfile/include/big.hrl").

-record(state, {
	raw_peer,
	pause_until = 0,
	format = 2
}).

-define(NONCE_LIMITER_UPDATE_VERSION, 67).

%% The frequency in milliseconds of re-resolving the domain name of the client,
%% if the client is configured via the domain name.
%%
%% big_nonce_limiter_server_worker periodically re-resolves and caches the address
%% of the corresponding client such that they can be identified upon request,
%% unless we are configured as a public VDF server.
-define(RE_RESOLVE_PEER_DOMAIN_MS, (30 * 1000)).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link(Name, RawPeer) ->
	gen_server:start_link({local, Name}, ?MODULE, RawPeer, []).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init(RawPeer) ->
	ok = big_events:subscribe(nonce_limiter),
	case big_config:is_public_vdf_server() of
		false ->
			gen_server:cast(self(), re_resolve_peer_domain);
		true ->
			ok
	end,
	{ok, #state{ raw_peer = RawPeer }}.

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_cast(re_resolve_peer_domain, #state{ raw_peer = RawPeer } = State) ->
	case big_peers:resolve_and_cache_peer(RawPeer, vdf_client_peer) of
		{ok, _} ->
			ok;
		Error ->
			?LOG_WARNING([{event, failed_to_re_resolve_peer_domain},
					{error, io_lib:format("~p", [Error])},
					{peer, io_lib:format("~p", [RawPeer])}])
	end,
	big_util:cast_after(?RE_RESOLVE_PEER_DOMAIN_MS, ?MODULE, re_resolve_peer_domain),
	{noreply, State};

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_info({event, nonce_limiter, {computed_output, Args}}, State) ->
	#state{ raw_peer = RawPeer } = State,
	case big_peers:resolve_and_cache_peer(RawPeer, vdf_client_peer) of
		{error, _} ->
			?LOG_WARNING([{event, failed_to_resolve_vdf_client_peer_before_push},
					{raw_peer, io_lib:format("~p", [RawPeer])}]),
			{noreply, State};
		{ok, Peer} ->
			handle_computed_output(Peer, Args, State)
	end;

handle_info({event, nonce_limiter, _Args}, State) ->
	{noreply, State};

handle_info(Message, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {message, Message}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

handle_computed_output(Peer, Args, State) ->
	#state{ pause_until = Timestamp, format = Format } = State,
	{SessionKey, StepNumber, Output, _PartitionUpperBound} = Args,
	CurrentStepNumber = big_nonce_limiter:get_current_step_number(),
	case os:system_time(second) < Timestamp of
		true ->
			{noreply, State};
		false ->
			case StepNumber < CurrentStepNumber of
				true ->
					{noreply, State};
				false ->
					{noreply, push_update(SessionKey, StepNumber, Output, Peer, Format, State)}
			end
	end.

push_update(SessionKey, StepNumber, Output, Peer, Format, State) ->
	Session = big_nonce_limiter:get_session(SessionKey),
	Update = big_nonce_limiter_server:make_partial_nonce_limiter_update(
		SessionKey, Session, StepNumber, Output),
	case Update of
		not_found -> State;
		_ ->
			case big_http_iface_client:push_nonce_limiter_update(Peer, Update, Format) of
				ok ->
					State;
				{ok, Response} ->
					RequestedFormat = Response#nonce_limiter_update_response.format,
					Postpone = Response#nonce_limiter_update_response.postpone,
					SessionFound = Response#nonce_limiter_update_response.session_found,
					RequestedStepNumber = Response#nonce_limiter_update_response.step_number,

					case { 
							RequestedFormat == Format,
							Postpone == 0,
							SessionFound,
							RequestedStepNumber >= StepNumber - 1
					} of
						{false, _, _, _} ->
							%% Client requested a different payload format
							?LOG_DEBUG([{event, vdf_client_requested_different_format},
								{peer, big_util:format_peer(Peer)},
								{format, Format}, {requested_format, RequestedFormat}]),
							push_update(SessionKey, StepNumber, Output, Peer, RequestedFormat,
									State#state{ format = RequestedFormat });
						{true, false, _, _} ->
							%% Client requested we pause updates
							Now = os:system_time(second),
							State#state{ pause_until = Now + Postpone };
						{true, true, false, _} ->
							%% Client requested the full session
							PrevSessionKey = Session#vdf_session.prev_session_key,
							PrevSession = big_nonce_limiter:get_session(PrevSessionKey),
							case push_session(PrevSessionKey, PrevSession, Peer, Format) of
								ok ->
									%% Do not push the new session until the previous
									%% session is in line with our view (i.e., has steps
									%% at least up to StepNumber where the new session begins).
									push_session(SessionKey, Session, Peer, Format);
								fail ->
									ok
							end,
							State;
						{true, true, true, false} ->
							%% Client requested missing steps
							push_session(SessionKey, Session, Peer, Format),
							State;
						_ ->
							%% Client is ahead of the server
							State
					end;
				{error, Error} ->
					log_failure(Peer, SessionKey, Update, Error, []),
					State
			end
	end.

push_session(SessionKey, Session, Peer, Format) ->
	Update = big_nonce_limiter_server:make_full_nonce_limiter_update(SessionKey, Session),
	case Update of
		not_found -> ok;
		_ ->
			case big_http_iface_client:push_nonce_limiter_update(Peer, Update, Format) of
				ok ->
					ok;
				{ok, #nonce_limiter_update_response{ step_number = ClientStepNumber,
						session_found = ReportedSessionFound }} ->
					log_failure(Peer, SessionKey, Update, behind_client,
						[{client_step_number, ClientStepNumber},
						{session_found, ReportedSessionFound}]),
					fail;
				{error, Error} ->
					log_failure(Peer, SessionKey, Update, Error, []),
					fail
			end
	end.

log_failure(Peer, SessionKey, Update, Error, Extra) ->
	{SessionSeed, SessionInterval, NextVDFDifficulty} = SessionKey,
	StepNumber = Update#nonce_limiter_update.session#vdf_session.step_number,
	Log = [{event, failed_to_push_nonce_limiter_update_to_peer},
			{reason, io_lib:format("~p", [Error])},
			{peer, big_util:format_peer(Peer)},
			{session_seed, big_util:encode(SessionSeed)},
			{session_interval, SessionInterval},
			{session_difficulty, NextVDFDifficulty},
			{server_step_number, StepNumber}] ++ Extra,

	case Error of
		behind_client -> ?LOG_DEBUG(Log);
		{shutdown, econnrefused} -> ?LOG_DEBUG(Log);
		{shutdown, timeout} -> ?LOG_DEBUG(Log);
		{shutdown, ehostunreach} -> ?LOG_DEBUG(Log);
		{closed, "The connection was lost."} -> ?LOG_DEBUG(Log);
		timeout -> ?LOG_DEBUG(Log);
		{<<"400">>, <<>>} -> ?LOG_DEBUG(Log);
		{<<"503">>, <<"{\"error\":\"not_joined\"}">>} -> ?LOG_DEBUG(Log);
		_ -> ?LOG_WARNING(Log)
	end.
