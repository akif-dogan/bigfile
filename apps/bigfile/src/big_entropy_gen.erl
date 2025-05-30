-module(big_entropy_gen).

-behaviour(gen_server).

-export([name/1, register_workers/1,  initialize_context/2, is_entropy_packing/1,
    set_repack_cursor/2, generate_entropies/2]).

-export([start_link/2, init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include("../include/big.hrl").
-include("../include/big_sup.hrl").
-include("../include/big_config.hrl").
-include("../include/big_consensus.hrl").

-include_lib("eunit/include/eunit.hrl").

-record(state, {
	store_id,
    packing,
    range_start,
    range_end,
    cursor,
    slice_index,
    prepare_status = undefined,
    repack_cursor
}).

-ifdef(BIG_TEST).
-define(DEVICE_LOCK_WAIT, 5_000).
-else.
-define(DEVICE_LOCK_WAIT, 5_000).
-endif.

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link(Name, {StoreID, Packing}) ->
	gen_server:start_link({local, Name}, ?MODULE,  {StoreID, Packing}, []).

%% @doc Return the name of the server serving the given StoreID.
name(StoreID) ->
	list_to_atom("big_entropy_gen_" ++ big_storage_module:label_by_id(StoreID)).


register_workers(Module) ->
    {ok, Config} = application:get_env(bigfile , config),
    ConfiguredWorkers = lists:filtermap(
        fun(StorageModule) ->
            StoreID = big_storage_module:id(StorageModule),
            Packing = big_storage_module:get_packing(StoreID),

            case is_entropy_packing(Packing) of
                true ->
                    Worker = ?CHILD_WITH_ARGS(
                        Module, worker, Module:name(StoreID),
                        [Module:name(StoreID), {StoreID, Packing}]),
                    {true, Worker};
                false ->
                    false
            end
        end,
        Config#config.storage_modules
    ),
    
    RepackInPlaceWorkers = lists:filtermap(
        fun({StorageModule, Packing}) ->
            StoreID = big_storage_module:id(StorageModule),
            %% Note: the config validation will prevent a StoreID from being used in both
            %% `storage_modules` and `repack_in_place_storage_modules`, so there's
            %% no risk of a `Name` clash with the workers spawned above.
            case is_entropy_packing(Packing) of
                true ->
                    Worker = ?CHILD_WITH_ARGS(
                        Module, worker, Module:name(StoreID),
                        [Module:name(StoreID), {StoreID, Packing}]),
                    {true, Worker};
                false ->
                    false
            end
        end,
        Config#config.repack_in_place_storage_modules
    ),

    ConfiguredWorkers ++ RepackInPlaceWorkers.

-spec initialize_context(big_storage_module:store_id(), big_chunk_storage:packing()) ->
    {IsPrepared :: boolean(), RewardAddr :: none | big_wallet:address()}.
initialize_context(StoreID, Packing) ->
    case Packing of
        {replica_2_9, Addr} ->
            {RangeStart, RangeEnd} = big_storage_module:get_range(StoreID),
            Cursor = read_cursor(StoreID, RangeStart + 1),
            case Cursor =< RangeEnd of
                true ->
                    {false, Addr};
                false ->
                    {true, Addr}
            end;
        _ ->
            {true, none}
    end.


-spec is_entropy_packing(big_chunk_storage:packing()) -> boolean().
is_entropy_packing(unpacked_padded) ->
	true;
is_entropy_packing({replica_2_9, _}) ->
	true;
is_entropy_packing(_) ->
	false.

set_repack_cursor(StoreID, RepackCursor) ->
    gen_server:cast(name(StoreID), {set_repack_cursor, RepackCursor}).

init({StoreID, Packing}) ->
	?LOG_INFO([{event, big_entropy_gen_init},
        {name, name(StoreID)}, {store_id, StoreID},
        {packing, big_serialize:encode_packing(Packing, true)}]),

    %% Senity checks
    {replica_2_9, _} = Packing,
    %% End sanity checks

    {RangeStart, RangeEnd} = big_storage_module:get_range(StoreID),

    Cursor = read_cursor(StoreID, RangeStart + 1),
    ?LOG_INFO([{event, read_prepare_replica_2_9_cursor}, {store_id, StoreID},
            {cursor, Cursor}, {range_start, RangeStart},
            {range_end, RangeEnd}]),
    PrepareStatus = 
        case initialize_context(StoreID, Packing) of
            {_IsPrepared, none} ->
                %% big_entropy_gen is only used for replica_2_9 packing
                ?LOG_ERROR([{event, invalid_packing_for_entropy}, {module, ?MODULE},
                    {store_id, StoreID},
                    {packing, big_serialize:encode_packing(Packing, true)}]),
                off;
            {false, _} ->
                gen_server:cast(self(), prepare_entropy),
                paused;
            {true, _} ->
                %% Entropy generation is complete
                complete
        end,
    
    BucketEndOffset = big_chunk_storage:get_chunk_bucket_end(Cursor),
    RepackCursor =
        case Packing == big_storage_module:get_packing(StoreID) of
            true ->
                none;
            false ->
                %% Provided Packing will only differ from the StoreID packing when this
                %% module is configured to repack in place.
                big_repack:read_cursor(StoreID, Packing, RangeStart)
        end,
    State = #state{
        store_id = StoreID,
        packing = Packing, 
        range_start = RangeStart,
        range_end = RangeEnd,
        cursor = Cursor,
        slice_index = big_replica_2_9:get_slice_index(BucketEndOffset),
        prepare_status = PrepareStatus,
        repack_cursor = RepackCursor
    },
    big_device_lock:set_device_lock_metric(StoreID, prepare, PrepareStatus),
	{ok, State}.


handle_cast(prepare_entropy, State) ->
    #state{ store_id = StoreID } = State,
    NewStatus = big_device_lock:acquire_lock(prepare, StoreID, State#state.prepare_status),
    State2 = State#state{ prepare_status = NewStatus },
    State3 = case NewStatus of
        active ->
            do_prepare_entropy(State2);
        paused ->
            big_util:cast_after(?DEVICE_LOCK_WAIT, self(), prepare_entropy),
            State2;
        _ ->
            State2
    end,
    {noreply, State3};

handle_cast({set_repack_cursor, RepackCursor}, State) ->
    {noreply, State#state{ repack_cursor = RepackCursor }};

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_call(Call, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {call, Call}]),
	{reply, {error, unhandled_call}, State}.

handle_info(Info, State) ->
    ?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {info, Info}]),
    {noreply, State}.

terminate(Reason, State) ->
	?LOG_INFO([{event, terminate}, {module, ?MODULE},
		{reason, Reason}, {name, name(State#state.store_id)},
		{store_id, State#state.store_id}]),
	ok.

do_prepare_entropy(State) ->
    #state{ 
        cursor = Start, range_start = RangeStart, range_end = RangeEnd,
        packing = {replica_2_9, RewardAddr},
        store_id = StoreID, repack_cursor = RepackCursor
    } = State,

    BucketEndOffset = big_chunk_storage:get_chunk_bucket_end(Start),
    PaddedRangeEnd = big_chunk_storage:get_chunk_bucket_end(RangeEnd),

    %% Sanity checks:
    BucketEndOffset = big_chunk_storage:get_chunk_bucket_end(BucketEndOffset),
    true = (
        big_chunk_storage:get_chunk_bucket_start(Start) ==
        big_chunk_storage:get_chunk_bucket_start(BucketEndOffset)
    ),
    true = (
        max(0, BucketEndOffset - ?DATA_CHUNK_SIZE) == 
        big_chunk_storage:get_chunk_bucket_start(BucketEndOffset)
    ),
    %% End of sanity checks.

    SliceIndex = big_replica_2_9:get_slice_index(BucketEndOffset),

    %% Make sure all prior entropy writes are complete.
    big_entropy_storage:is_ready(StoreID),

    CheckRangeEnd =
        case BucketEndOffset > PaddedRangeEnd of
            true ->
                big_device_lock:release_lock(prepare, StoreID),
                ?LOG_INFO([{event, storage_module_entropy_preparation_complete},
                        {store_id, StoreID}]),
                big:console("The storage module ~s is prepared for 2.9 replication.~n",
                        [StoreID]),
                big_chunk_storage:set_entropy_complete(StoreID),
                complete;
            false ->
                false
        end,

    Start2 = advance_entropy_offset(BucketEndOffset, StoreID),
    State2 = State#state{ cursor = Start2, slice_index = SliceIndex },
    CheckRepackCursor =
        case CheckRangeEnd of
            complete ->
                complete;
            false ->
                case RepackCursor of
                    none ->
                        false;
                    _ ->
                        SectorSize = big_replica_2_9:get_sector_size(),
                        RangeStart2 = 
                            big_chunk_storage:get_chunk_bucket_start(RangeStart + 1),
                        RepackCursor2 =
                            big_chunk_storage:get_chunk_bucket_start(RepackCursor + 1),
                        RepackSectorShift = (RepackCursor2 - RangeStart2) rem SectorSize,
                        SectorShift = (BucketEndOffset - RangeStart2) rem SectorSize,
                        case SectorShift > RepackSectorShift of
                            true ->
                                waiting_for_repack;
                            false ->
                                false
                        end
                end
        end,
    CheckIsRecorded =
        case CheckRepackCursor of
            complete ->
                complete;
            waiting_for_repack ->
                waiting_for_repack;
            false ->
                big_entropy_storage:is_entropy_recorded(BucketEndOffset, StoreID)
        end,

    %% get_entropy_partition will use bucket *start* offset to determine the partition.
    Partition = big_replica_2_9:get_entropy_partition(BucketEndOffset),
    StoreEntropy =
        case CheckIsRecorded of
            complete ->
                complete;
            waiting_for_repack ->
                waiting_for_repack;
            true ->
                is_recorded;
            false ->
                %% Get all the entropies needed to encipher the chunk at BucketEndOffset.
                Entropies = prometheus_histogram:observe_duration(
                    replica_2_9_entropy_duration_milliseconds, [32], 
                        fun() ->
                            generate_entropies(RewardAddr, BucketEndOffset)
                        end),
                case Entropies of
                    {error, Reason} ->
                        {error, Reason};
                    _ ->
                        EntropyKeys = generate_entropy_keys(RewardAddr, BucketEndOffset),
                        
                        %% A set of generated entropies covers slighly more than 3.6TB of
                        %% chunks, however we only want to use the first 3.6TB
                        %% (+ chunk padding) of it.
                        PartitionEnd = (Partition + 1) * ?PARTITION_SIZE,
                        PaddedPartitionEnd =
                            big_chunk_storage:get_chunk_bucket_end(
                                big_block:get_chunk_padded_offset(PartitionEnd)),
                        %% In addition to limiting this iteration to the PaddedPartitionEnd,
                        %% we also want to limit it to the current storage module's range.
                        %% This allows us to handle both the storage module range as well
                        %% as the small overlap region.
                        IterationEnd = min(PaddedPartitionEnd, RangeEnd),
                        %% Wait for the previous store_entropy to complete. Should only
                        %% return 'false' if the entropy storage process is down (e.g. during
                        %% shutdown)
                        big_entropy_storage:store_entropy(
                            StoreID, Entropies, BucketEndOffset, RangeStart,
                            IterationEnd, EntropyKeys, RewardAddr)
                end
        end,
    case StoreEntropy of
        complete ->
            big_device_lock:set_device_lock_metric(StoreID, prepare, complete),
            State#state{ prepare_status = complete };
        waiting_for_repack ->
            ?LOG_INFO([{event, waiting_for_repacking},
                    {store_id, StoreID},
                    {padded_end_offset, BucketEndOffset},
                    {repack_cursor, RepackCursor},
                    {cursor, Start},
                    {range_start, RangeStart},
                    {range_end, RangeEnd}]),
            big_util:cast_after(10000, self(), prepare_entropy),
            State;
        is_recorded ->
            gen_server:cast(self(), prepare_entropy),
            State2;
        {error, Error} ->
            ?LOG_WARNING([{event, failed_to_store_entropy},
                    {cursor, Start},
                    {store_id, StoreID},
                    {reason, io_lib:format("~p", [Error])}]),
            big_util:cast_after(500, self(), prepare_entropy),
            State;
        ok ->
            gen_server:cast(self(), prepare_entropy),
            case store_cursor(Start2, StoreID) of
                ok ->
                    ok;
                {error, Error} ->
                    ?LOG_WARNING([{event, failed_to_store_prepare_entropy_cursor},
                            {chunk_cursor, Start2},
                            {store_id, StoreID},
                            {reason, io_lib:format("~p", [Error])}])
            end,
            State2
    end.

%% @doc Returns all the entropies needed to encipher the chunk at PaddedEndOffset.
generate_entropies(RewardAddr, PaddedEndOffset) ->
	SubChunkSize = ?COMPOSITE_PACKING_SUB_CHUNK_SIZE,
	EntropyTasks = lists:map(
		fun(Offset) ->
			Ref = make_ref(),
			big_packing_server:request_entropy_generation(
				Ref, self(), {RewardAddr, PaddedEndOffset, Offset}),
			Ref
		end,
		lists:seq(0, ?DATA_CHUNK_SIZE - SubChunkSize, SubChunkSize)
	),
	Entropies = collect_entropies(EntropyTasks, []),
	case Entropies of
		{error, _Reason} ->
			flush_entropy_messages();
		_ ->
			ok
	end,
	Entropies.

advance_entropy_offset(BucketEndOffset, StoreID) ->
    ID = big_chunk_storage_replica_2_9_1_entropy,
    case big_sync_record:get_next_unsynced_interval(
            BucketEndOffset, infinity, ID, StoreID) of
        not_found ->
            BucketEndOffset + ?DATA_CHUNK_SIZE;
        {_, Start} ->
            Start + ?DATA_CHUNK_SIZE
    end.

generate_entropy_keys(RewardAddr, Offset) ->
	generate_entropy_keys(RewardAddr, Offset, 0).
generate_entropy_keys(_RewardAddr, _Offset, SubChunkStart)
	when SubChunkStart == ?DATA_CHUNK_SIZE ->
	[];
generate_entropy_keys(RewardAddr, Offset, SubChunkStart) ->
	SubChunkSize = ?COMPOSITE_PACKING_SUB_CHUNK_SIZE,
	[big_replica_2_9:get_entropy_key(RewardAddr, Offset, SubChunkStart)
	 | generate_entropy_keys(RewardAddr, Offset, SubChunkStart + SubChunkSize)].

collect_entropies([], Acc) ->
	lists:reverse(Acc);
collect_entropies([Ref | Rest], Acc) ->
	receive
		{entropy_generated, Ref, {error, Reason}} ->
			?LOG_ERROR([{event, failed_to_generate_replica_2_9_entropy}, {error, Reason}]),
			{error, Reason};
		{entropy_generated, Ref, Entropy} ->
			collect_entropies(Rest, [Entropy | Acc])
	after 60000 ->
		?LOG_ERROR([{event, entropy_generation_timeout}, {ref, Ref}]),
		{error, timeout}
	end.

flush_entropy_messages() ->
	?LOG_INFO([{event, flush_entropy_messages}]),
	receive
		{entropy_generated, _, _} ->
			flush_entropy_messages()
	after 0 ->
		ok
	end.

read_cursor(StoreID, Default) ->
    Filepath = big_chunk_storage:get_filepath("prepare_replica_2_9_cursor", StoreID),
    case file:read_file(Filepath) of
        {ok, Bin} ->
            case catch binary_to_term(Bin) of Cursor when is_integer(Cursor) ->
                    Cursor;
                _ ->
                    Default
            end;
        _ ->
            Default
    end.

store_cursor(Cursor, StoreID) ->
    Filepath = big_chunk_storage:get_filepath("prepare_replica_2_9_cursor", StoreID),
    file:write_file(Filepath, term_to_binary(Cursor)).
    
%%%===================================================================
%%% Tests.
%%%===================================================================
