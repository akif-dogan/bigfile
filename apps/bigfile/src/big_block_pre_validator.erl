-module(big_block_pre_validator).

-behaviour(gen_server).

-export([start_link/0, pre_validate/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_config.hrl").
-include_lib("bigfile/include/big_consensus.hrl").

-record(state, {
	%% The priority queue storing the validation requests.
	pqueue = gb_sets:new(),
	%% The total size in bytes of the priority queue.
	size = 0,
	%% The map IP => the timestamp of the last block from this IP.
	ip_timestamps = #{},
	throttle_by_ip_interval,
	%% The map SolutionHash => the timestamp of the last block with this solution hash.
	hash_timestamps = #{},
	throttle_by_solution_interval
}).

%% The maximum size in bytes the blocks enqueued for pre-validation can occupy.
-define(MAX_PRE_VALIDATION_QUEUE_SIZE, (200 * 1024 * 1024)).

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Partially validate the received block. The validation consists of multiple
%% stages. The process is aiming to increase resistance against DDoS attacks.
%% The first stage is the quickest and performed synchronously when this function
%% is called. Afterwards, the block is put in a limited-size priority queue.
%% Bigger-height blocks from better-rated peers have higher priority. Additionally,
%% the processing is throttled by IP and solution hash.
%% Returns: ok, invalid, skipped
pre_validate(B, Peer, ReceiveTimestamp) ->
	#block{ indep_hash = H } = B,
	case big_ignore_registry:member(H) of
		true ->
			skipped;
		false ->
			Ref = make_ref(),
			big_ignore_registry:add_ref(H, Ref),
			erlang:put(ignore_registry_ref, Ref),
			B2 = B#block{ receive_timestamp = ReceiveTimestamp },
			case pre_validate_is_peer_banned(B2, Peer) of
				enqueued ->
					enqueued;
				Other ->
					big_ignore_registry:remove_ref(H, Ref),
					Other
			end
	end.

%%%===================================================================
%%% gen_server callbacks.
%%%===================================================================

init([]) ->
	gen_server:cast(?MODULE, pre_validate),
	ok = big_events:subscribe(block),
	{ok, Config} = application:get_env(bigfile, config),
	ThrottleBySolutionInterval = Config#config.block_throttle_by_solution_interval,
	ThrottleByIPInterval = Config#config.block_throttle_by_ip_interval,
	{ok, #state{ throttle_by_ip_interval = ThrottleByIPInterval,
			throttle_by_solution_interval = ThrottleBySolutionInterval }}.

handle_cast(pre_validate, #state{ pqueue = Q, size = Size, ip_timestamps = IPTimestamps,
			hash_timestamps = HashTimestamps,
			throttle_by_ip_interval = ThrottleByIPInterval,
			throttle_by_solution_interval = ThrottleBySolutionInterval } = State) ->
	case gb_sets:is_empty(Q) of
		true ->
			big_util:cast_after(50, ?MODULE, pre_validate),
			{noreply, State};
		false ->
			{{_, {B, PrevB, SolutionResigned, Peer, Ref}}, Q2} = gb_sets:take_largest(Q),
			BlockSize = byte_size(term_to_binary(B)),				
			Size2 = Size - BlockSize,
			BH = B#block.indep_hash,
			case big_ignore_registry:permanent_member(BH) of
				true ->
					gen_server:cast(?MODULE, pre_validate),
					{noreply, State#state{ pqueue = Q2, size = Size2 }};
				false ->
					ThrottleByIPResult = throttle_by_ip(Peer, IPTimestamps,
							ThrottleByIPInterval),
					{IPTimestamps3, HashTimestamps3} =
						case ThrottleByIPResult of
							false ->
								big_ignore_registry:remove_ref(BH, Ref),
								{IPTimestamps, HashTimestamps};
							{true, IPTimestamps2} ->
								case throttle_by_solution_hash(B#block.hash, HashTimestamps,
										ThrottleBySolutionInterval) of
									{true, HashTimestamps2} ->
										?LOG_INFO([{event, processing_block},
												{peer, big_util:format_peer(Peer)},
												{height, B#block.height},
												{step_number, big_block:vdf_step_number(B)},
												{block, big_util:encode(B#block.indep_hash)},
												{miner_address,
														big_util:encode(B#block.reward_addr)},
												{previous_block,
													big_util:encode(PrevB#block.indep_hash)}]),
										pre_validate_nonce_limiter_seed_data(B, PrevB,
												SolutionResigned, Peer),
										record_block_pre_validation_time(
												B#block.receive_timestamp),
										{IPTimestamps2, HashTimestamps2};
									false ->
										big_ignore_registry:remove_ref(BH, Ref),
										{IPTimestamps2, HashTimestamps}
								end
						end,
					gen_server:cast(?MODULE, pre_validate),
					{noreply, State#state{ pqueue = Q2, size = Size2,
							ip_timestamps = IPTimestamps3,
							hash_timestamps = HashTimestamps3 }}
			end
	end;

handle_cast({enqueue, {B, PrevB, SolutionResigned, Peer, Ref}}, State) ->
	#state{ pqueue = Q, size = Size } = State,
	Priority = priority(B, Peer),
	BlockSize = byte_size(term_to_binary(B)),
	Size2 = Size + BlockSize,
	Q2 = gb_sets:add_element({Priority, {B, PrevB, SolutionResigned, Peer, Ref}}, Q),
	{Q3, Size3} =
		case Size2 > ?MAX_PRE_VALIDATION_QUEUE_SIZE of
			true ->
				drop_tail(Q2, Size2);
			false ->
				{Q2, Size2}
		end,
	{noreply, State#state{ pqueue = Q3, size = Size3 }};

handle_cast({may_be_remove_ip_timestamp, IP}, #state{ ip_timestamps = Timestamps,
		throttle_by_ip_interval = ThrottleInterval } = State) ->
	Now = os:system_time(millisecond),
	case maps:get(IP, Timestamps, not_set) of
		not_set ->
			{noreply, State};
		Timestamp when Timestamp < Now - ThrottleInterval ->
			{noreply, State#state{ ip_timestamps = maps:remove(IP, Timestamps) }};
		_ ->
			{noreply, State}
	end;

handle_cast({may_be_remove_h_timestamp, H}, #state{ hash_timestamps = Timestamps,
		throttle_by_solution_interval = ThrottleInterval } = State) ->
	Now = os:system_time(millisecond),
	case maps:get(H, Timestamps, not_set) of
		not_set ->
			{noreply, State};
		Timestamp when Timestamp < Now - ThrottleInterval ->
			{noreply, State#state{ hash_timestamps = maps:remove(H, Timestamps) }};
		_ ->
			{noreply, State}
	end;

handle_cast(Msg, State) ->
	?LOG_ERROR([{event, unhandled_cast}, {module, ?MODULE}, {message, Msg}]),
	{noreply, State}.

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_info({event, block, _}, State) ->
	{noreply, State};

handle_info(Info, State) ->
	?LOG_ERROR([{event, unhandled_info}, {module, ?MODULE}, {info, Info}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

pre_validate_is_peer_banned(B, Peer) ->
	case big_blacklist_middleware:is_peer_banned(Peer) of
		not_banned ->
			pre_validate_previous_block(B, Peer);
		banned ->
			skipped
	end.

pre_validate_previous_block(B, Peer) ->
	PrevH = B#block.previous_block,
	case big_node:get_block_shadow_from_cache(PrevH) of
		not_found ->
			%% We have not seen the previous block yet - might happen if two
			%% successive blocks are distributed at the same time. Do not
			%% ban the peer as the block might be valid. If the network adopts
			%% this block, big_poller will catch up.
			skipped;
		#block{ height = PrevHeight } = PrevB ->
			case B#block.height == PrevHeight + 1 of
				false ->
					invalid;
				true ->
					true = B#block.height >= big_fork:height_2_6(),
					PrevCDiff = B#block.previous_cumulative_diff,
					case PrevB#block.cumulative_diff == PrevCDiff of
						true ->
							pre_validate_proof_sizes(B, PrevB, Peer);
						false ->
							invalid
					end
			end
	end.

pre_validate_proof_sizes(B, PrevB, Peer) ->
	case big_block:validate_proof_size(B#block.poa) andalso
			big_block:validate_proof_size(B#block.poa2) of
		true ->
			may_be_pre_validate_first_chunk_hash(B, PrevB, Peer);
		false ->
			post_block_reject_warn(B, check_proof_size, Peer),
			big_events:send(block, {rejected, invalid_proof_size, B#block.indep_hash, Peer}),
			invalid
	end.

may_be_pre_validate_first_chunk_hash(B, PrevB, Peer) ->
	case crypto:hash(sha256, (B#block.poa)#poa.chunk) == B#block.chunk_hash of
		false ->
			post_block_reject_warn(B, check_first_chunk, Peer),
			big_events:send(block, {rejected, invalid_first_chunk, B#block.indep_hash, Peer}),
			invalid;
		true ->
			may_be_pre_validate_second_chunk_hash(B, PrevB, Peer)
	end.

may_be_pre_validate_second_chunk_hash(#block{ recall_byte2 = undefined } = B, PrevB, Peer) ->
	case B#block.height < big_fork:height_2_7_2() orelse B#block.poa2 == #poa{} of
		false ->
			post_block_reject_warn(B, check_second_chunk, Peer),
			big_events:send(block, {rejected, invalid_poa2_recall_byte2_undefined,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			%% The block is not supposed to have the second chunk.
			may_be_pre_validate_first_unpacked_chunk_hash(B, PrevB, Peer)
	end;
may_be_pre_validate_second_chunk_hash(B, PrevB, Peer) ->
	case crypto:hash(sha256, (B#block.poa2)#poa.chunk) == B#block.chunk2_hash of
		false ->
			post_block_reject_warn(B, check_second_chunk, Peer),
			big_events:send(block, {rejected, invalid_second_chunk, B#block.indep_hash, Peer}),
			invalid;
		true ->
			may_be_pre_validate_first_unpacked_chunk_hash(B, PrevB, Peer)
	end.

may_be_pre_validate_first_unpacked_chunk_hash(
		#block{ packing_difficulty = PackingDifficulty } = B, PrevB, Peer)
			when PackingDifficulty >= 1 ->
	PoA = B#block.poa,
	case crypto:hash(sha256, PoA#poa.unpacked_chunk) == B#block.unpacked_chunk_hash
			%% The unpacked chunk is expected to be 0-padded when smaller than
			%% ?DATA_CHUNK_SIZE.
			andalso byte_size(PoA#poa.unpacked_chunk) == ?DATA_CHUNK_SIZE of
		false ->
			post_block_reject_warn(B, check_first_unpacked_chunk, Peer),
			big_events:send(block, {rejected, invalid_first_unpacked_chunk,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			may_be_pre_validate_second_unpacked_chunk_hash(B, PrevB, Peer)
	end;
may_be_pre_validate_first_unpacked_chunk_hash(B, PrevB, Peer) ->
	#block{ poa = PoA, poa2 = PoA2 } = B,
	#block{ unpacked_chunk_hash = UnpackedChunkHash,
			unpacked_chunk2_hash = UnpackedChunk2Hash } = B,
	case {UnpackedChunkHash, UnpackedChunk2Hash} == {undefined, undefined} of
		false ->
			post_block_reject_warn(B, check_first_unpacked_chunk_hash, Peer),
			big_events:send(block, {rejected, invalid_first_unpacked_chunk_hash,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			pre_validate_indep_hash(B#block{
					poa = PoA#poa{ unpacked_chunk = <<>> },
					poa2 = PoA2#poa{ unpacked_chunk = <<>> } }, PrevB, Peer)
	end.

may_be_pre_validate_second_unpacked_chunk_hash(
		#block{ recall_byte2 = RecallByte2 } = B, PrevB, Peer)
			when RecallByte2 /= undefined ->
	PoA2 = B#block.poa2,
	case crypto:hash(sha256, PoA2#poa.unpacked_chunk) == B#block.unpacked_chunk2_hash
			%% The unpacked chunk is expected to be 0-padded when smaller than
			%% ?DATA_CHUNK_SIZE.
			andalso byte_size(PoA2#poa.unpacked_chunk) == ?DATA_CHUNK_SIZE of
		false ->
			post_block_reject_warn(B, check_second_unpacked_chunk, Peer),
			big_events:send(block, {rejected, invalid_second_unpacked_chunk,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			pre_validate_indep_hash(B, PrevB, Peer)
	end;
may_be_pre_validate_second_unpacked_chunk_hash(B, PrevB, Peer) ->
	#block{ poa2 = PoA2 } = B,
	case B#block.unpacked_chunk2_hash == undefined of
		false ->
			post_block_reject_warn(B, check_second_unpacked_chunk_hash, Peer),
			big_events:send(block, {rejected, invalid_second_unpacked_chunk_hash,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			pre_validate_indep_hash(B#block{
					poa2 = PoA2#poa{ unpacked_chunk = <<>> } }, PrevB, Peer)
	end.

pre_validate_indep_hash(#block{ indep_hash = H } = B, PrevB, Peer) ->
	case catch compute_hash(B, PrevB#block.cumulative_diff) of
		{ok, H} ->
			case big_ignore_registry:permanent_member(H) of
				true ->
					skipped;
				false ->
					pre_validate_timestamp(B, PrevB, Peer)
			end;
		{error, invalid_signature} ->
			post_block_reject_warn(B, check_signature, Peer),
			big_events:send(block, {rejected, invalid_signature, B#block.indep_hash, Peer}),
			invalid;
		{ok, _DifferentH} ->
			post_block_reject_warn(B, check_indep_hash, Peer),
			big_events:send(block, {rejected, invalid_hash, B#block.indep_hash, Peer}),
			invalid
	end.

pre_validate_timestamp(B, PrevB, Peer) ->
	#block{ indep_hash = H } = B,
	case big_block:verify_timestamp(B, PrevB) of
		true ->
			pre_validate_existing_solution_hash(B, PrevB, Peer);
		false ->
			post_block_reject_warn(B, check_timestamp, Peer, [{block_time,
					B#block.timestamp}, {current_time, os:system_time(seconds)}]),
			big_events:send(block, {rejected, invalid_timestamp, H, Peer}),
			invalid
	end.

pre_validate_existing_solution_hash(B, PrevB, Peer) ->
	Height = B#block.height,
	SolutionH = B#block.hash,
	#block{ hash = SolutionH, nonce = Nonce, reward_addr = RewardAddr,
			hash_preimage = HashPreimage, recall_byte = RecallByte,
			partition_number = PartitionNumber, recall_byte2 = RecallByte2,
			nonce_limiter_info = #nonce_limiter_info{ output = Output,
					global_step_number = StepNumber, seed = Seed,
					partition_upper_bound = UpperBound,
					last_step_checkpoints = LastStepCheckpoints },
			chunk_hash = ChunkHash, chunk2_hash = Chunk2Hash,
			unpacked_chunk_hash = UnpackedChunkHash,
			unpacked_chunk2_hash = UnpackedChunk2Hash,
			packing_difficulty = PackingDifficulty,
			replica_format = ReplicaFormat } = B,
	H = B#block.indep_hash,
	CDiff = B#block.cumulative_diff,
	PrevCDiff = PrevB#block.cumulative_diff,
	GetCachedSolution =
		case big_block_cache:get_by_solution_hash(block_cache, SolutionH, H,
				CDiff, PrevCDiff) of
			not_found ->
				not_found;
			#block{ hash = SolutionH, nonce = Nonce,
					reward_addr = RewardAddr, hash_preimage = HashPreimage,
					recall_byte = RecallByte, partition_number = PartitionNumber,
					nonce_limiter_info = #nonce_limiter_info{ output = Output,
							last_step_checkpoints = LastStepCheckpoints,
							seed = Seed, partition_upper_bound = UpperBound,
							global_step_number = StepNumber },
					chunk_hash = ChunkHash, chunk2_hash = Chunk2Hash,
					unpacked_chunk_hash = UnpackedChunkHash,
					unpacked_chunk2_hash = UnpackedChunk2Hash,
					poa = #poa{ chunk = Chunk }, poa2 = #poa{ chunk = Chunk2 },
					recall_byte2 = RecallByte2,
					packing_difficulty = PackingDifficulty2,
					replica_format = ReplicaFormat } = CacheB ->
				may_be_report_double_signing(B, CacheB),
				LastStepPrevOutput = get_last_step_prev_output(B),
				LastStepPrevOutput2 = get_last_step_prev_output(CacheB),
				case LastStepPrevOutput == LastStepPrevOutput2
						andalso (Height < big_fork:height_2_9()
							orelse PackingDifficulty == PackingDifficulty2) of
					true ->
						B2 = B#block{ poa = (B#block.poa)#poa{ chunk = Chunk },
								poa2 = (B#block.poa2)#poa{ chunk = Chunk2 } },
						case validate_poa_against_cached_poa(B2, CacheB) of
							{true, B3} ->
								{valid, B3};
							false ->
								invalid
						end;
					false ->
						invalid
				end;
			_ ->
				invalid
		end,
	ValidatedCachedSolutionDiff =
		case GetCachedSolution of
			not_found ->
				not_found;
			invalid ->
				invalid;
			{valid, B4} ->
				case big_node_utils:block_passes_diff_check(B) of
					true ->
						{valid, B4};
					false ->
						invalid
				end
		end,
	case ValidatedCachedSolutionDiff of
		not_found ->
			pre_validate_nonce_limiter_global_step_number(B, PrevB, false, Peer);
		invalid ->
			post_block_reject_warn(B, check_resigned_solution_hash, Peer),
			big_events:send(block, {rejected, invalid_resigned_solution_hash,
					B#block.indep_hash, Peer}),
			invalid;
		{valid, B5} ->
			pre_validate_nonce_limiter_global_step_number(B5, PrevB, true, Peer)
	end.

may_be_report_double_signing(B, B2) ->
	#block{ reward_key = {_, Key}, signature = Signature1, cumulative_diff = CDiff1,
			previous_solution_hash = PreviousSolutionH1,
			previous_cumulative_diff = PrevCDiff } = B,
	#block{ reward_key = {_, Key}, signature = Signature2, cumulative_diff = CDiff2,
			previous_cumulative_diff = PrevCDiff2,
			previous_solution_hash = PreviousSolutionH2 } = B2,
	case CDiff1 == CDiff2 orelse (CDiff1 > PrevCDiff2 andalso CDiff2 > PrevCDiff) of
		true ->
			Preimage1 = << PreviousSolutionH1/binary,
					(big_block:generate_signed_hash(B))/binary >>,
			Preimage2 = << PreviousSolutionH2/binary,
					(big_block:generate_signed_hash(B2))/binary >>,
			Proof = {Key, Signature1, CDiff1, PrevCDiff, Preimage1, Signature2, CDiff2,
					PrevCDiff2, Preimage2},
			?LOG_INFO([{event, report_double_signing},
				{key, big_util:encode(Key)}, 
				{block1, big_util:encode(B#block.indep_hash)},
				{block2, big_util:encode(B2#block.indep_hash)},
				{height1, B#block.height}, {height2, B2#block.height}]),
			big_events:send(block, {double_signing, Proof});
		false ->
			ok
	end.

get_last_step_prev_output(B) ->
	#block{ nonce_limiter_info = Info } = B,
	#nonce_limiter_info{ steps = Steps, prev_output = PrevOutput } = Info,
	case Steps of
		[_, PrevStepOutput | _] ->
			PrevStepOutput;
		_ ->
			PrevOutput
	end.

validate_poa_against_cached_poa(B, CacheB) ->
	#block{ poa_cache = {ArgCache, ChunkID}, poa2_cache = Cache2 } = CacheB,
	Args = erlang:append_element(erlang:insert_element(5, ArgCache, B#block.poa), ChunkID),
	case big_poa:validate(Args) of
		{true, ChunkID} ->
			B2 = B#block{ poa_cache = {ArgCache, ChunkID} },
			case B#block.recall_byte2 of
				undefined ->
					{true, B2};
				_ ->
					{ArgCache2, Chunk2ID} = Cache2,
					Args2 = erlang:append_element(
							erlang:insert_element(5, ArgCache2, B#block.poa2), Chunk2ID),
					case big_poa:validate(Args2) of
						{true, Chunk2ID} ->
							{true, B2#block{ poa2_cache = Cache2 }};
						_ ->
							false
					end
			end;
		_ ->
			false
	end.

pre_validate_nonce_limiter_global_step_number(B, PrevB, SolutionResigned, Peer) ->
	BlockInfo = B#block.nonce_limiter_info,
	StepNumber = big_block:vdf_step_number(B),
	PrevBlockInfo = PrevB#block.nonce_limiter_info,
	PrevStepNumber = big_block:vdf_step_number(PrevB),
	CurrentStepNumber =
		case big_nonce_limiter:get_current_step_number(PrevB) of
			not_found ->
				%% Not necessarily computed already, but will be after we
				%% validate the previous block's chain.
				PrevStepNumber;
			N ->
				N
		end,
	IsAhead = big_nonce_limiter:is_ahead_on_the_timeline(BlockInfo, PrevBlockInfo),
	MaxDistance = ?NONCE_LIMITER_MAX_CHECKPOINTS_COUNT,
	ExpectedStepCount = min(MaxDistance, StepNumber - PrevStepNumber),
	Steps = BlockInfo#nonce_limiter_info.steps,
	PrevOutput = BlockInfo#nonce_limiter_info.prev_output,
	case IsAhead andalso StepNumber - CurrentStepNumber =< MaxDistance
			andalso length(Steps) == ExpectedStepCount
			andalso PrevOutput == PrevBlockInfo#nonce_limiter_info.output of
		false ->
			post_block_reject_warn(B, check_nonce_limiter_step_number, Peer,
					[{block_step_number, StepNumber},
					{current_step_number, CurrentStepNumber}]),
			H = B#block.indep_hash,
			big_events:send(block,
					{rejected, invalid_nonce_limiter_global_step_number, H, Peer}),
			invalid;
		true ->
			prometheus_gauge:set(block_vdf_advance, StepNumber - CurrentStepNumber),
			pre_validate_previous_solution_hash(B, PrevB, SolutionResigned, Peer)
	end.

pre_validate_previous_solution_hash(B, PrevB, SolutionResigned, Peer) ->
	case B#block.previous_solution_hash == PrevB#block.hash of
		false ->
			post_block_reject_warn_and_error_dump(B, check_previous_solution_hash, Peer),
			big_events:send(block, {rejected, invalid_previous_solution_hash,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			pre_validate_last_retarget(B, PrevB, SolutionResigned, Peer)
	end.

pre_validate_last_retarget(B, PrevB, SolutionResigned, Peer) ->
	true = B#block.height >= big_fork:height_2_6(),
	case big_block:verify_last_retarget(B, PrevB) of
		true ->
			pre_validate_difficulty(B, PrevB, SolutionResigned, Peer);
		false ->
			post_block_reject_warn_and_error_dump(B, check_last_retarget, Peer),
			big_events:send(block, {rejected, invalid_last_retarget,
					B#block.indep_hash, Peer}),
			invalid
	end.

pre_validate_difficulty(B, PrevB, SolutionResigned, Peer) ->
	true = B#block.height >= big_fork:height_2_6(),
	DiffValid = big_retarget:validate_difficulty(B, PrevB),
	case DiffValid of
		true ->
			pre_validate_cumulative_difficulty(B, PrevB, SolutionResigned, Peer);
		_ ->
			post_block_reject_warn_and_error_dump(B, check_difficulty, Peer),
			big_events:send(block, {rejected, invalid_difficulty, B#block.indep_hash, Peer}),
			invalid
	end.

pre_validate_cumulative_difficulty(B, PrevB, SolutionResigned, Peer) ->
	true = B#block.height >= big_fork:height_2_6(),
	case big_block:verify_cumulative_diff(B, PrevB) of
		false ->
			post_block_reject_warn_and_error_dump(B, check_cumulative_difficulty, Peer),
			big_events:send(block, {rejected, invalid_cumulative_difficulty,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			pre_validate_packing_difficulty(B, PrevB, SolutionResigned, Peer)
	end.

pre_validate_packing_difficulty(B, PrevB, SolutionResigned, Peer) ->
	case big_block:validate_replica_format(B#block.height, B#block.packing_difficulty,
			B#block.replica_format) of
		false ->
			post_block_reject_warn_and_error_dump(B, check_packing_difficulty, Peer),
			big_events:send(block, {rejected, invalid_packing_difficulty,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			case SolutionResigned of
				true ->
					Ref = erlang:get(ignore_registry_ref),
					gen_server:cast(?MODULE, {enqueue, {B, PrevB, true, Peer, Ref}}),
					enqueued;
				false ->
					pre_validate_quick_pow(B, PrevB, false, Peer)
			end
	end.

pre_validate_quick_pow(B, PrevB, SolutionResigned, Peer) ->
	#block{ hash_preimage = HashPreimage } = B,
	H0 = big_block:compute_h0(B, PrevB),
	SolutionHash = big_block:compute_solution_h(H0, HashPreimage),
	case big_node_utils:block_passes_diff_check(SolutionHash, B) of
		false ->
			post_block_reject_warn_and_error_dump(B, check_hash_preimage, Peer),
			big_events:send(block, {rejected, invalid_hash_preimage,
					B#block.indep_hash, Peer}),
			invalid;
		true ->
			Ref = erlang:get(ignore_registry_ref),
			gen_server:cast(?MODULE, {enqueue, {B, PrevB, SolutionResigned, Peer, Ref}}),
			enqueued
	end.

pre_validate_nonce_limiter_seed_data(B, PrevB, SolutionResigned, Peer) ->
	Info = B#block.nonce_limiter_info,
	#nonce_limiter_info{ global_step_number = StepNumber, seed = Seed,
			next_seed = NextSeed, partition_upper_bound = PartitionUpperBound,
			vdf_difficulty = VDFDifficulty,
			next_partition_upper_bound = NextPartitionUpperBound } = Info,
	StepNumber = big_block:vdf_step_number(B),
	ExpectedSeedData = big_nonce_limiter:get_seed_data(StepNumber, PrevB),
	case ExpectedSeedData == {Seed, NextSeed, PartitionUpperBound,
			NextPartitionUpperBound, VDFDifficulty} of
		true ->
			pre_validate_partition_number(B, PrevB, PartitionUpperBound,
					SolutionResigned, Peer);
		false ->
			post_block_reject_warn_and_error_dump(B, check_nonce_limiter_seed_data, Peer),
			big_events:send(block, {rejected, invalid_nonce_limiter_seed_data,
					B#block.indep_hash, Peer}),
			invalid
	end.

pre_validate_partition_number(B, PrevB, PartitionUpperBound, SolutionResigned, Peer) ->
	Max = big_node:get_max_partition_number(PartitionUpperBound),
	case B#block.partition_number > Max of
		true ->
			post_block_reject_warn_and_error_dump(B, check_partition_number, Peer),
			big_events:send(block, {rejected, invalid_partition_number, B#block.indep_hash,
					Peer}),
			invalid;
		false ->
			pre_validate_nonce(B, PrevB, PartitionUpperBound, SolutionResigned, Peer)
	end.

pre_validate_nonce(B, PrevB, PartitionUpperBound, SolutionResigned, Peer) ->
	Max = big_block:get_max_nonce(B#block.packing_difficulty),
	case B#block.nonce > Max of
		true ->
			post_block_reject_warn_and_error_dump(B, check_nonce, Peer),
			big_events:send(block, {rejected, invalid_nonce, B#block.indep_hash, Peer}),
			invalid;
		false ->
			case SolutionResigned of
				true ->
					accept_block(B, Peer, false);
				false ->
					pre_validate_pow_2_6(B, PrevB, PartitionUpperBound, Peer)
			end
	end.

pre_validate_pow_2_6(B, PrevB, PartitionUpperBound, Peer) ->
	H0 = big_block:compute_h0(B, PrevB),
	Chunk1 = (B#block.poa)#poa.chunk,
	{H1, Preimage1} = big_block:compute_h1(H0, B#block.nonce, Chunk1),
	DiffPair = big_difficulty:diff_pair(B),
	case H1 == B#block.hash andalso big_node_utils:h1_passes_diff_check(H1, DiffPair,
				B#block.packing_difficulty)
			andalso Preimage1 == B#block.hash_preimage
			andalso B#block.recall_byte2 == undefined
			andalso B#block.chunk2_hash == undefined of
		true ->
			pre_validate_poa(B, PrevB, PartitionUpperBound, H0, H1, Peer);
		false ->
			Chunk2 = (B#block.poa2)#poa.chunk,
			{H2, Preimage2} = big_block:compute_h2(H1, Chunk2, H0),
			case H2 == B#block.hash andalso big_node_utils:h2_passes_diff_check(H2, DiffPair,
						B#block.packing_difficulty)
					andalso Preimage2 == B#block.hash_preimage of
				true ->
					pre_validate_poa(B, PrevB, PartitionUpperBound, H0, H1, Peer);
				false ->
					post_block_reject_warn_and_error_dump(B, check_pow, Peer),
					big_events:send(block, {rejected, invalid_pow, B#block.indep_hash, Peer}),
					invalid
			end
	end.

pre_validate_poa(B, PrevB, PartitionUpperBound, H0, H1, Peer) ->
	{RecallRange1Start, RecallRange2Start} = big_block:get_recall_range(H0,
			B#block.partition_number, PartitionUpperBound),
	RecallByte1 = big_block:get_recall_byte(RecallRange1Start, B#block.nonce,
			B#block.packing_difficulty),
	{BlockStart1, BlockEnd1, TXRoot1} = big_block_index:get_block_bounds(RecallByte1),
	BlockSize1 = BlockEnd1 - BlockStart1,
	PackingDifficulty = B#block.packing_difficulty,
	Nonce = B#block.nonce,
	%% The packing difficulty >0 is only allowed after the 2.8 hard fork (validated earlier
	%% here), and the composite packing is only possible for packing difficulty >= 1.
	%% The new shared entropy format is supported starting from 2.9.
	Packing = big_block:get_packing(PackingDifficulty, B#block.reward_addr,
			B#block.replica_format),
	SubChunkIndex = big_block:get_sub_chunk_index(PackingDifficulty, Nonce),
	ArgCache = {BlockStart1, RecallByte1, TXRoot1, BlockSize1, Packing, SubChunkIndex},
	case RecallByte1 == B#block.recall_byte andalso
			big_poa:validate({BlockStart1, RecallByte1, TXRoot1, BlockSize1, B#block.poa,
					Packing, SubChunkIndex, not_set}) of
		error ->
			?LOG_ERROR([{event, failed_to_validate_proof_of_access},
					{block, big_util:encode(B#block.indep_hash)}]),
			invalid;
		false ->
			post_block_reject_warn_and_error_dump(B, check_poa, Peer),
			big_events:send(block, {rejected, invalid_poa, B#block.indep_hash, Peer}),
			invalid;
		{true, ChunkID} ->
			%% Cache the proof so that in case the miner signs additional blocks
			%% using the same solution, we can re-validate the potentially new
			%% proofs quickly, without re-validating the solution and re-unpacking
			%% the chunk.
			B2 = B#block{ poa_cache = {ArgCache, ChunkID} },
			case B#block.hash == H1 of
				true ->
					pre_validate_nonce_limiter(B2, PrevB, Peer);
				false ->
					RecallByte2 = big_block:get_recall_byte(RecallRange2Start, B#block.nonce,
							B#block.packing_difficulty),
					{BlockStart2, BlockEnd2, TXRoot2} = big_block_index:get_block_bounds(
							RecallByte2),
					BlockSize2 = BlockEnd2 - BlockStart2,
					ArgCache2 = {BlockStart2, RecallByte2, TXRoot2, BlockSize2, Packing,
							SubChunkIndex},
					case RecallByte2 == B#block.recall_byte2 andalso
							big_poa:validate({BlockStart2, RecallByte2, TXRoot2, BlockSize2,
									B#block.poa2, Packing, SubChunkIndex, not_set}) of
						error ->
							?LOG_ERROR([{event, failed_to_validate_proof_of_access},
									{block, big_util:encode(B#block.indep_hash)}]),
							invalid;
						false ->
							post_block_reject_warn_and_error_dump(B, check_poa2, Peer),
							big_events:send(block, {rejected, invalid_poa2,
									B#block.indep_hash, Peer}),
							invalid;
						{true, Chunk2ID} ->
							%% Cache the proof so that in case the miner signs additional
							%% blocks using the same solution, we can re-validate the
							%% potentially new proofs quickly, without re-validating the
							%% solution and re-unpacking the chunk.
							B3 = B2#block{ poa2_cache = {ArgCache2, Chunk2ID} },
							pre_validate_nonce_limiter(B3, PrevB, Peer)
					end
			end
	end.

pre_validate_nonce_limiter(B, PrevB, Peer) ->
	PrevOutput = get_last_step_prev_output(B),
	case big_nonce_limiter:validate_last_step_checkpoints(B, PrevB, PrevOutput) of
		{false, cache_mismatch} ->
			post_block_reject_warn_and_error_dump(B, check_nonce_limiter, Peer),
			big_events:send(block, {rejected, invalid_nonce_limiter_cache_mismatch,
					B#block.indep_hash, Peer}),
			invalid;
		false ->
			post_block_reject_warn_and_error_dump(B, check_nonce_limiter, Peer),
			big_events:send(block, {rejected, invalid_nonce_limiter, B#block.indep_hash, Peer}),
			invalid;
		{true, cache_match} ->
			accept_block(B, Peer, true);
		true ->
			accept_block(B, Peer, false)
	end.

accept_block(B, Peer, Gossip) ->
	big_ignore_registry:add(B#block.indep_hash),
	big_events:send(block, {new, B, 
		#{ source => {peer, Peer}, gossip => Gossip }}),
	?LOG_INFO([{event, accepted_block}, {height, B#block.height},
			{indep_hash, big_util:encode(B#block.indep_hash)}]),
	ok.

compute_hash(B, PrevCDiff) ->
	true = B#block.height >= big_fork:height_2_6(),
	SignedH = big_block:generate_signed_hash(B),
	case big_block:verify_signature(SignedH, PrevCDiff, B) of
		false ->
			{error, invalid_signature};
		true ->
			{ok, big_block:indep_hash2(SignedH, B#block.signature)}
	end.

post_block_reject_warn_and_error_dump(B, Step, Peer) ->
	{ok, Config} = application:get_env(bigfile, config),
	ID = binary_to_list(big_util:encode(crypto:strong_rand_bytes(16))),
	File = filename:join(Config#config.data_dir, "invalid_block_dump_" ++ ID),
	file:write_file(File, term_to_binary(B)),
	post_block_reject_warn(B, Step, Peer),
	?LOG_WARNING([{event, post_block_rejected},
			{hash, big_util:encode(B#block.indep_hash)}, {step, Step},
			{peer, big_util:format_peer(Peer)},
			{error_dump, File}]).

post_block_reject_warn(B, Step, Peer) ->
	?LOG_WARNING([{event, post_block_rejected},
			{hash, big_util:encode(B#block.indep_hash)}, {step, Step},
			{peer, big_util:format_peer(Peer)}]).

post_block_reject_warn(B, Step, Peer, Params) ->
	?LOG_WARNING([{event, post_block_rejected},
			{hash, big_util:encode(B#block.indep_hash)}, {step, Step},
			{params, Params}, {peer, big_util:format_peer(Peer)}]).

record_block_pre_validation_time(ReceiveTimestamp) ->
	TimeMs = timer:now_diff(erlang:timestamp(), ReceiveTimestamp) / 1000,
	prometheus_histogram:observe(block_pre_validation_time, TimeMs).

priority(B, Peer) ->
	{B#block.height, get_peer_score(Peer)}.

get_peer_score(Peer) ->
	get_peer_score(Peer, big_peers:get_peers(lifetime), 0).

get_peer_score(Peer, [Peer | _Peers], N) ->
	N;
get_peer_score(Peer, [_Peer | Peers], N) ->
	get_peer_score(Peer, Peers, N - 1);
get_peer_score(_Peer, [], N) ->
	N - rand:uniform(100).

drop_tail(Q, Size) when Size =< ?MAX_PRE_VALIDATION_QUEUE_SIZE ->
	{Q, 0};
drop_tail(Q, Size) ->
	{{_Priority, {B, _PrevB, _SolutionResigned, _Peer, Ref}}, Q2} = gb_sets:take_smallest(Q),
	big_ignore_registry:remove_ref(B#block.indep_hash, Ref),
	BlockSize = byte_size(term_to_binary(B)),
	drop_tail(Q2, Size - BlockSize).

throttle_by_ip(Peer, Timestamps, ThrottleInterval) ->
	IP = get_ip(Peer),
	Now = os:system_time(millisecond),
	big_util:cast_after(ThrottleInterval * 2, ?MODULE, {may_be_remove_ip_timestamp, IP}),
	case maps:get(IP, Timestamps, not_set) of
		not_set ->
			{true, maps:put(IP, Now, Timestamps)};
		Timestamp when Timestamp < Now - ThrottleInterval ->
			{true, maps:put(IP, Now, Timestamps)};
		_ ->
			false
	end.

get_ip({A, B, C, D, _Port}) ->
	{A, B, C, D}.

throttle_by_solution_hash(H, Timestamps, ThrottleInterval) ->
	Now = os:system_time(millisecond),
	big_util:cast_after(ThrottleInterval * 2, ?MODULE, {may_be_remove_h_timestamp, H}),
	case maps:get(H, Timestamps, not_set) of
		not_set ->
			{true, maps:put(H, Now, Timestamps)};
		Timestamp when Timestamp < Now - ThrottleInterval ->
			{true, maps:put(H, Now, Timestamps)};
		_ ->
			false
	end.
