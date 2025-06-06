%%% @doc A process fetching the weave data from the network and from the local
%%% storage modules, one chunk (or a range of chunks) at a time. The workers
%%% are coordinated by big_data_sync_worker_master. The workers do not update the
%%% storage - updates are handled by big_data_sync_* processes.
-module(big_data_sync_worker).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_consensus.hrl").
-include_lib("bigfile/include/big_config.hrl").
-include_lib("bigfile/include/big_data_sync.hrl").

-record(state, {
	name = undefined,
	request_packed_chunks = false
}).

 %% # of messages to cast to big_data_sync at once. Each message carries at least 1 chunk worth
 %% of data (256 KiB). Since there are dozens or hundreds of workers, if each one posts too
 %% many messages at once it can overload the available memory.
-define(READ_RANGE_MESSAGES_PER_BATCH, 40).

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link(Name) ->
	gen_server:start_link({local, Name}, ?MODULE, Name, []).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init(Name) ->
	{ok, Config} = application:get_env(bigfile, config),
	{ok, #state{
		name = Name,
		request_packed_chunks = Config#config.data_sync_request_packed_chunks
	}}.

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_cast({read_range, Args}, State) ->
	case read_range(Args) of
		recast ->
			ok;
		ReadResult ->
			gen_server:cast(big_chunk_copy,
				{task_completed, {read_range, {State#state.name, ReadResult, Args}}})
	end,
	{noreply, State};

handle_cast({sync_range, Args}, State) ->
	StartTime = erlang:monotonic_time(),
	SyncResult = sync_range(Args, State),
	EndTime = erlang:monotonic_time(),
	case SyncResult of
		recast ->
			ok;
		_ ->
			gen_server:cast(big_data_sync_worker_master, {task_completed,
				{sync_range, {State#state.name, SyncResult, Args, EndTime-StartTime}}})
	end,
	{noreply, State};

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_info(_Message, State) ->
	{noreply, State}.

terminate(Reason, _State) ->
	?LOG_INFO([{event, terminate}, {module, ?MODULE}, {reason, io_lib:format("~p", [Reason])}]),
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

read_range({Start, End, _OriginStoreID, _TargetStoreID})
		when Start >= End ->
	ok;
read_range({Start, End, _OriginStoreID, TargetStoreID} = Args) ->
	case big_data_sync:is_chunk_cache_full() of
		false ->
			case big_data_sync:is_disk_space_sufficient(TargetStoreID) of
				true ->
					?LOG_DEBUG([{event, read_range}, {pid, self()},
						{size_mb, (End - Start) / ?MiB}, {args, Args}]),
					read_range2(?READ_RANGE_MESSAGES_PER_BATCH, Args);
				_ ->
					big_util:cast_after(30000, self(), {read_range, Args}),
					recast
			end;
		_ ->
			big_util:cast_after(200, self(), {read_range, Args}),
			recast
	end.

read_range2(0, Args) ->
	big_util:cast_after(1000, self(), {read_range, Args}),
	recast;
read_range2(_MessagesRemaining,
		{Start, End, _OriginStoreID, _TargetStoreID})
		when Start >= End ->
	ok;
read_range2(MessagesRemaining, {Start, End, OriginStoreID, TargetStoreID}) ->
	CheckIsRecordedAlready =
		case big_sync_record:is_recorded(Start + 1, big_data_sync, TargetStoreID) of
			{true, _} ->
				case big_sync_record:get_next_unsynced_interval(Start, End, big_data_sync,
						TargetStoreID) of
					not_found ->
						ok;
					{_, Start2} ->
						read_range2(MessagesRemaining,
								{Start2, End, OriginStoreID, TargetStoreID})
				end;
			_ ->
				false
		end,
	IsRecordedInTheSource =
		case CheckIsRecordedAlready of
			ok ->
				ok;
			recast ->
				ok;
			false ->
				case big_sync_record:is_recorded(Start + 1, big_data_sync, OriginStoreID) of
					{true, Packing} ->
						{true, Packing};
					SyncRecordReply ->
						?LOG_ERROR([{event, cannot_read_requested_range},
								{origin_store_id, OriginStoreID},
								{missing_start_offset, Start + 1},
								{end_offset, End},
								{target_store_id, TargetStoreID},
								{sync_record_reply, io_lib:format("~p", [SyncRecordReply])}])
				end
		end,
	ReadChunkMetadata =
		case IsRecordedInTheSource of
			ok ->
				ok;
			{true, Packing2} ->
				{Packing2, big_data_sync:get_chunk_by_byte(Start + 1, OriginStoreID)}
		end,
	case ReadChunkMetadata of
		ok ->
			ok;
		{_, {error, invalid_iterator}} ->
			%% get_chunk_by_byte looks for a key with the same prefix or the next
			%% prefix. Therefore, if there is no such key, it does not make sense to
			%% look for any key smaller than the prefix + 2 in the next iteration.
			PrefixSpaceSize = trunc(math:pow(2,
					?OFFSET_KEY_BITSIZE - ?OFFSET_KEY_PREFIX_BITSIZE)),
			Start3 = ((Start div PrefixSpaceSize) + 2) * PrefixSpaceSize,
			read_range2(MessagesRemaining,
					{Start3, End, OriginStoreID, TargetStoreID});
		{_, {error, Reason}} ->
			?LOG_ERROR([{event, failed_to_query_chunk_metadata}, {offset, Start + 1},
					{reason, io_lib:format("~p", [Reason])}]);
		{_, {ok, _Key, {AbsoluteOffset, _, _, _, _, _, _}}} when AbsoluteOffset > End ->
			ok;
		{Packing3, {ok, _Key, {AbsoluteOffset, ChunkDataKey, TXRoot, DataRoot, TXPath,
				RelativeOffset, ChunkSize}}} ->
			ReadChunk = big_data_sync:read_chunk(AbsoluteOffset, ChunkDataKey, OriginStoreID),
			case ReadChunk of
				not_found ->
					big_data_sync:invalidate_bad_data_record(
						AbsoluteOffset, ChunkSize, OriginStoreID, read_range_chunk_not_found),
					read_range2(MessagesRemaining-1,
							{Start + ChunkSize, End, OriginStoreID, TargetStoreID});
				{error, Error} ->
					?LOG_ERROR([{event, failed_to_read_chunk},
							{absolute_end_offset, AbsoluteOffset},
							{chunk_data_key, big_util:encode(ChunkDataKey)},
							{reason, io_lib:format("~p", [Error])}]),
					read_range2(MessagesRemaining,
							{Start + ChunkSize, End, OriginStoreID, TargetStoreID});
				{ok, {Chunk, DataPath}} ->
					case big_sync_record:is_recorded(AbsoluteOffset, big_data_sync,
							OriginStoreID) of
						{true, Packing3} ->
							big_data_sync:increment_chunk_cache_size(),
							UnpackedChunk =
								case Packing3 of
									unpacked ->
										Chunk;
									_ ->
										none
								end,
							Args = {DataRoot, AbsoluteOffset, TXPath, TXRoot, DataPath,
									Packing3, RelativeOffset, ChunkSize, Chunk,
									UnpackedChunk, TargetStoreID, ChunkDataKey},
							gen_server:cast(big_data_sync:name(TargetStoreID),
									{pack_and_store_chunk, Args}),
							read_range2(MessagesRemaining-1,
								{Start + ChunkSize, End, OriginStoreID, TargetStoreID});
						{true, _DifferentPacking} ->
							%% Unlucky timing - the chunk should have been repacked
							%% in the meantime.
							read_range2(MessagesRemaining,
									{Start, End, OriginStoreID, TargetStoreID});
						Reply ->
							?LOG_ERROR([{event, chunk_record_not_found},
									{absolute_end_offset, AbsoluteOffset},
									{big_sync_record_reply, io_lib:format("~p", [Reply])}]),
							read_range2(MessagesRemaining,
									{Start + ChunkSize, End, OriginStoreID, TargetStoreID})
					end
			end
	end.

sync_range({Start, End, _Peer, _TargetStoreID, _RetryCount}, _State) when Start >= End ->
	ok;
sync_range({Start, End, Peer, _TargetStoreID, 0}, _State) ->
	?LOG_DEBUG([{event, sync_range_retries_exhausted},
				{peer, big_util:format_peer(Peer)},
				{start_offset, Start}, {end_offset, End}]),
	{error, timeout};
sync_range({Start, End, Peer, TargetStoreID, RetryCount} = Args, State) ->
	IsChunkCacheFull =
		case big_data_sync:is_chunk_cache_full() of
			true ->
				big_util:cast_after(500, self(), {sync_range, Args}),
				true;
			false ->
				false
		end,
	IsDiskSpaceSufficient =
		case IsChunkCacheFull of
			false ->
				case big_data_sync:is_disk_space_sufficient(TargetStoreID) of
					true ->
						true;
					_ ->
						big_util:cast_after(30000, self(), {sync_range, Args}),
						false
				end;
			true ->
				false
		end,
	case IsDiskSpaceSufficient of
		false ->
			recast;
		true ->
			Start2 = big_tx_blacklist:get_next_not_blacklisted_byte(Start + 1),
			case Start2 - 1 >= End of
				true ->
					ok;
				false ->
					Packing = get_target_packing(TargetStoreID,
							State#state.request_packed_chunks),
					case big_http_iface_client:get_chunk_binary(Peer, Start2, Packing) of
						{ok, #{ chunk := Chunk } = Proof, _Time, _TransferSize} ->
							%% In case we fetched a packed small chunk,
							%% we may potentially skip some chunks by
							%% continuing with Start2 + byte_size(Chunk) - the skip
							%% chunks will be then requested later.
							Start3 = big_block:get_chunk_padded_offset(
									Start2 + byte_size(Chunk)) + 1,
							gen_server:cast(big_data_sync:name(TargetStoreID),
									{store_fetched_chunk, Peer, Start2 - 1, Proof}),
							big_data_sync:increment_chunk_cache_size(),
							sync_range({Start3, End, Peer, TargetStoreID, RetryCount}, State);
						{error, timeout} ->
							?LOG_DEBUG([{event, timeout_fetching_chunk},
									{peer, big_util:format_peer(Peer)},
									{start_offset, Start2}, {end_offset, End}]),
							Args2 = {Start, End, Peer, TargetStoreID, RetryCount - 1},
							big_util:cast_after(1000, self(), {sync_range, Args2}),
							recast;
						{error, Reason} ->
							?LOG_DEBUG([{event, failed_to_fetch_chunk},
									{peer, big_util:format_peer(Peer)},
									{start_offset, Start2}, {end_offset, End},
									{reason, io_lib:format("~p", [Reason])}]),
							{error, Reason}
					end
			end
	end.

get_target_packing(StoreID, true) ->
	big_storage_module:get_packing(StoreID);
get_target_packing(_StoreID, false) ->
	any.
