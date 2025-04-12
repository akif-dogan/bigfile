%% The blob storage optimized for fast reads.
-module(big_chunk_storage).

-behaviour(gen_server).

-export([start_link/2, name/1, register_workers/0, is_storage_supported/3, put/4,
		open_files/1, get/2, get/3, locate_chunk_on_disk/2,
		get_range/2, get_range/3, cut/2, delete/1, delete/2,
		set_entropy_complete/1,
		get_filepath/2, get_handle_by_filepath/1, close_file/2, close_files/1, 
		list_files/2, run_defragmentation/0, get_position_and_relative_chunk_offset/2,
		get_storage_module_path/2, get_chunk_storage_path/2,
		get_chunk_bucket_start/1, get_chunk_bucket_end/1, 
		get_chunk_byte_from_bucket_end/1,
		sync_record_id/1, write_chunk/4, record_chunk/7, read_offset/2]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

%% Used in tests.
-export([delete_chunk/2]).

-include("../include/big.hrl").
-include("../include/big_sup.hrl").
-include("../include/big_config.hrl").
-include("../include/big_consensus.hrl").
-include("../include/big_chunk_storage.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-record(state, {
	file_index,
	store_id,
	store_id_label,
	packing_labels = #{},
	entropy_context = none, %% some data we need pass to ar_entropy_storage
	range_start,
	range_end
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link(Name, StoreID) ->
	gen_server:start_link({local, Name}, ?MODULE, StoreID, []).

%% @doc Return the name of the server serving the given StoreID.
name(StoreID) ->
	list_to_atom("big_chunk_storage_" ++ big_storage_module:label_by_id(StoreID)).

register_workers() ->
	{ok, Config} = application:get_env(arweave, config),
	ConfiguredWorkers = lists:map(
		fun(StorageModule) ->
			StoreID = big_storage_module:id(StorageModule),

			ChunkStorageName = big_chunk_storage:name(StoreID),
			?CHILD_WITH_ARGS(big_chunk_storage, worker,
				ChunkStorageName, [ChunkStorageName, StoreID])
		end,
		Config#config.storage_modules
	),
	
	DefaultChunkStorageWorker = ?CHILD_WITH_ARGS(big_chunk_storage, worker,
		big_chunk_storage_default, [big_chunk_storage_default, "default"]),

	RepackInPlaceWorkers = lists:map(
		fun({StorageModule, _Packing}) ->
			StoreID = big_storage_module:id(StorageModule),
			%% Note: the config validation will prevent a StoreID from being used in both
			%% `storage_modules` and `repack_in_place_storage_modules`, so there's
			%% no risk of a `Name` clash with the workers spawned above.
			ChunkStorageName = big_chunk_storage:name(StoreID),
			?CHILD_WITH_ARGS(big_chunk_storage, worker,
				ChunkStorageName, [ChunkStorageName, StoreID])
		end,
		Config#config.repack_in_place_storage_modules
	),

	ConfiguredWorkers ++ RepackInPlaceWorkers ++ [DefaultChunkStorageWorker].

%% @doc Return true if we can accept the chunk for storage.
%% 256 KiB chunks are stored in the blob storage optimized for read speed.
%% Unpacked chunks smaller than 256 KiB cannot be stored here currently,
%% because the module does not keep track of the chunk sizes - all chunks
%% are assumed to be 256 KiB.
-spec is_storage_supported(
		Offset :: non_neg_integer(),
		ChunkSize :: non_neg_integer(),
		Packing :: term()
) -> true | false.

is_storage_supported(Offset, ChunkSize, Packing) ->
	case Offset > ?STRICT_DATA_SPLIT_THRESHOLD of
		true ->
			%% All chunks above ?STRICT_DATA_SPLIT_THRESHOLD are placed in 256 KiB buckets
			%% so technically can be stored in ar_chunk_storage. However, to avoid
			%% managing padding in ar_chunk_storage for unpacked chunks smaller than 256 KiB
			%% (we do not need fast random access to unpacked chunks after
			%% ?STRICT_DATA_SPLIT_THRESHOLD anyways), we put them to RocksDB.
			Packing /= unpacked orelse ChunkSize == (?DATA_CHUNK_SIZE);
		false ->
			ChunkSize == (?DATA_CHUNK_SIZE)
	end.

%% @doc Store the chunk under the given end offset,
%% bytes Offset - ?DATA_CHUNK_SIZE, Offset - ?DATA_CHUNK_SIZE + 1, .., Offset - 1.
put(PaddedOffset, Chunk, Packing, StoreID) ->
	GenServerID = name(StoreID),
	case catch gen_server:call(GenServerID, {put, PaddedOffset, Chunk, Packing}, 180_000) of
		{'EXIT', {shutdown, {gen_server, call, _}}} ->
			%% Handle to avoid the large badmatch log on shutdown.
			{error, shutdown};
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			?LOG_ERROR([{event, gen_server_timeout_putting_chunk},
				{padded_offset, PaddedOffset},
				{store_id, StoreID}
			]),
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Open all the storage files. The subsequent calls to get/1 in the
%% caller process will use the opened file descriptors.
open_files(StoreID) ->
	ets:foldl(
		fun ({{Key, ID}, Filepath}, _) when ID == StoreID ->
				case erlang:get({cfile, {Key, ID}}) of
					undefined ->
						case file:open(Filepath, [read, raw, binary]) of
							{ok, F} ->
								erlang:put({cfile, {Key, ID}}, F);
							_ ->
								ok
						end;
					_ ->
						ok
				end;
			(_, _) ->
				ok
		end,
		ok,
		chunk_storage_file_index
	).

%% @doc Return {PaddedEndOffset, Chunk} for the chunk containing the given byte.
get(Byte, StoreID) ->
	case big_sync_record:get_interval(Byte + 1, big_chunk_storage, StoreID) of
		not_found ->
			not_found;
		{_End, IntervalStart} ->
			get(Byte, IntervalStart, StoreID)
	end.

get(Byte, IntervalStart, StoreID) ->
	%% The synced ranges begin at IntervalStart => the chunk
	%% should begin at a multiple of ?DATA_CHUNK_SIZE to the right of IntervalStart.
	ChunkStart = Byte - (Byte - IntervalStart) rem ?DATA_CHUNK_SIZE,
	ChunkFileStart = get_chunk_file_start_by_start_offset(ChunkStart),

	case get(Byte, ChunkStart, ChunkFileStart, StoreID, 1) of
		[] ->
			not_found;
		[{PaddedEndOffset, Chunk}] ->
			{PaddedEndOffset, Chunk}
	end.

locate_chunk_on_disk(PaddedEndOffset, StoreID) ->
	locate_chunk_on_disk(PaddedEndOffset, StoreID, #{}).

locate_chunk_on_disk(PaddedEndOffset, StoreID, FileIndex) ->
	ChunkFileStart = get_chunk_file_start(PaddedEndOffset),
	Filepath = filepath(ChunkFileStart, FileIndex, StoreID),
	{Position, ChunkOffset} =
        get_position_and_relative_chunk_offset(ChunkFileStart, PaddedEndOffset),
	{ChunkFileStart, Filepath, Position, ChunkOffset}.

%% @doc Return a list of {PaddedEndOffset, Chunk} pairs for the stored chunks
%% inside the given range. The given interval does not have to cover every chunk
%% completely - we return all chunks at the intersection with the range.
get_range(Start, Size) ->
	get_range(Start, Size, "default").

%% @doc Return a list of {PaddedEndOffset, Chunk} pairs for the stored chunks
%% inside the given range. The given interval does not have to cover every chunk
%% completely - we return all chunks at the intersection with the range. The
%% very last chunk might be outside of the interval - its start offset is
%% at most Start + Size + ?DATA_CHUNK_SIZE - 1.
get_range(Start, Size, StoreID) ->
	?assert(Size < get_chunk_group_size()),
	case big_sync_record:get_next_synced_interval(Start, infinity, big_chunk_storage, StoreID) of
		{_End, IntervalStart} when Start + Size > IntervalStart ->
			Start2 = max(Start, IntervalStart),
			Size2 = Start + Size - Start2,
			ChunkStart = Start2 - (Start2 - IntervalStart) rem ?DATA_CHUNK_SIZE,
			ChunkFileStart = get_chunk_file_start_by_start_offset(ChunkStart),
			End = Start2 + Size2,
			LastChunkStart = (End - 1) - ((End - 1) - IntervalStart) rem ?DATA_CHUNK_SIZE,
			LastChunkFileStart = get_chunk_file_start_by_start_offset(LastChunkStart),
			ChunkCount = (LastChunkStart - ChunkStart) div ?DATA_CHUNK_SIZE + 1,
			case ChunkFileStart /= LastChunkFileStart of
				false ->
					%% All chunks are from the same chunk file.
					get(Start2, ChunkStart, ChunkFileStart, StoreID, ChunkCount);
				true ->
					SizeBeforeBorder = ChunkFileStart + get_chunk_group_size() - ChunkStart,
					ChunkCountBeforeBorder = SizeBeforeBorder div ?DATA_CHUNK_SIZE
							+ case SizeBeforeBorder rem ?DATA_CHUNK_SIZE of 0 -> 0; _ -> 1 end,
					StartAfterBorder = ChunkStart + ChunkCountBeforeBorder * ?DATA_CHUNK_SIZE,
					SizeAfterBorder = Size2 - ChunkCountBeforeBorder * ?DATA_CHUNK_SIZE
							+ (Start2 - ChunkStart),
					get(Start2, ChunkStart, ChunkFileStart, StoreID, ChunkCountBeforeBorder)
						++ get_range(StartAfterBorder, SizeAfterBorder, StoreID)
			end;
		_ ->
			[]
	end.

%% @doc Close the file with the given Key.
close_file(Key, StoreID) ->
	case erlang:erase({cfile, {Key, StoreID}}) of
		undefined ->
			ok;
		F ->
			file:close(F)
	end.

%% @doc Close the files opened by open_files/1.
close_files(StoreID) ->
	close_files(erlang:get_keys(), StoreID).

%% @doc Soft-delete everything above the given end offset.
cut(Offset, StoreID) ->
	big_sync_record:cut(Offset, big_chunk_storage, StoreID).

%% @doc Remove the chunk with the given end offset.
delete(Offset) ->
	delete(Offset, "default").

%% @doc Remove the chunk with the given end offset.
delete(PaddedOffset, StoreID) ->
	GenServerID = name(StoreID),
	case catch gen_server:call(GenServerID, {delete, PaddedOffset}, 20000) of
		{'EXIT', {shutdown, {gen_server, call, _}}} ->
			%% Handle to avoid the large badmatch log on shutdown.
			{error, shutdown};
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Run defragmentation of chunk files if enabled
run_defragmentation() ->
	{ok, Config} = application:get_env(arweave, config),
	case Config#config.run_defragmentation of
		false ->
			ok;
		true ->
			big:console("Defragmentation threshold: ~B bytes.~n",
					   [Config#config.defragmentation_trigger_threshold]),
			DefragModules = modules_to_defrag(Config),
			Sizes = read_chunks_sizes(Config#config.data_dir),
			Files = files_to_defrag(DefragModules,
									Config#config.data_dir,
									Config#config.defragmentation_trigger_threshold,
									Sizes),
			ok = defrag_files(Files),
			ok = update_sizes_file(Files, #{})
	end.

get_storage_module_path(DataDir, "default") ->
	DataDir;
get_storage_module_path(DataDir, StoreID) ->
	filename:join([DataDir, "storage_modules", StoreID]).

get_chunk_storage_path(DataDir, StoreID) ->
	filename:join([get_storage_module_path(DataDir, StoreID), ?CHUNK_DIR]).

%% @doc Return the start and end offset of the bucket containing the given offset.
%% A chunk bucket is a 0-based, 256-KiB wide, 256-KiB aligned range that
%% big_chunk_storage uses to index chunks. The bucket start does NOT necessarily
%% match the chunk's start offset.
-spec get_chunk_bucket_start(Offset :: non_neg_integer()) -> non_neg_integer().
get_chunk_bucket_start(Offset) ->
	PaddedEndOffset = big_block:get_chunk_padded_offset(Offset),
	ar_util:floor_int(max(0, PaddedEndOffset - ?DATA_CHUNK_SIZE), ?DATA_CHUNK_SIZE).

-spec get_chunk_bucket_end(Offset :: non_neg_integer()) -> non_neg_integer().
get_chunk_bucket_end(Offset) ->
	get_chunk_bucket_start(Offset) + ?DATA_CHUNK_SIZE.

%% @doc Return the byte (>= ChunkStartOffset, < ChunkEndOffset)
%% that necessarily belongs to the chunk stored
%% in the bucket with the given bucket end offset.
-spec get_chunk_byte_from_bucket_end(Offset :: non_neg_integer()) -> non_neg_integer().
get_chunk_byte_from_bucket_end(BucketEndOffset) ->
	case BucketEndOffset >= ?STRICT_DATA_SPLIT_THRESHOLD of
		true ->
			RelativeBucketEndOffset = BucketEndOffset - ?STRICT_DATA_SPLIT_THRESHOLD,
			case RelativeBucketEndOffset rem ?DATA_CHUNK_SIZE of
				0 ->
					%% The chunk beginning at this offset is the rightmost possible
					%% chunk that will be routed to this bucket.
					%% The chunk ending at this offset plus one is the leftmost possible
					%% chunk routed to this bucket.
					BucketEndOffset - ?DATA_CHUNK_SIZE;
				_ ->
					?STRICT_DATA_SPLIT_THRESHOLD
							+ ar_util:floor_int(RelativeBucketEndOffset, ?DATA_CHUNK_SIZE)
			end;
		false ->
			BucketEndOffset - 1
	end.

set_entropy_complete(StoreID) ->
	gen_server:cast(name(StoreID), entropy_complete).

read_offset(PaddedOffset, StoreID) ->
	{_ChunkFileStart, Filepath, Position, _ChunkOffset} =
			big_chunk_storage:locate_chunk_on_disk(PaddedOffset, StoreID),
	case file:open(Filepath, [read, raw, binary]) of
		{ok, F} ->
			Result = file:pread(F, Position, ?OFFSET_SIZE),
			file:close(F),
			Result;
		Error ->
			Error
	end.

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init("default" = StoreID) ->
	%% Trap exit to avoid corrupting any open files on quit..
	process_flag(trap_exit, true),
	{ok, Config} = application:get_env(arweave, config),
	DataDir = Config#config.data_dir,
	Dir = get_storage_module_path(DataDir, StoreID),
	ok = filelib:ensure_dir(Dir ++ "/"),
	ok = filelib:ensure_dir(filename:join(Dir, ?CHUNK_DIR) ++ "/"),
	FileIndex = read_file_index(Dir),
	FileIndex2 = maps:map(
		fun(Key, Filepath) ->
			Filepath2 = filename:join([DataDir, ?CHUNK_DIR, Filepath]),
			ets:insert(chunk_storage_file_index, {{Key, StoreID}, Filepath2}),
			Filepath2
		end,
		FileIndex
	),
	warn_custom_chunk_group_size(StoreID),
	StoreIDLabel = big_storage_module:label_by_id(StoreID),
	{ok, #state{
		file_index = FileIndex2, store_id = StoreID, store_id_label = StoreIDLabel }};
init(StoreID) ->
	%% Trap exit to avoid corrupting any open files on quit..
	process_flag(trap_exit, true),
	{ok, Config} = application:get_env(arweave, config),
	DataDir = Config#config.data_dir,
	Dir = get_storage_module_path(DataDir, StoreID),
	ok = filelib:ensure_dir(Dir ++ "/"),
	ok = filelib:ensure_dir(filename:join(Dir, ?CHUNK_DIR) ++ "/"),
	FileIndex = read_file_index(Dir),
	FileIndex2 = maps:map(
		fun(Key, Filepath) ->
			ets:insert(chunk_storage_file_index, {{Key, StoreID}, Filepath}),
			Filepath
		end,
		FileIndex
	),
	warn_custom_chunk_group_size(StoreID),
	{RangeStart, RangeEnd} = big_storage_module:get_range(StoreID),
	StoreIDLabel = big_storage_module:label_by_id(StoreID),

	State = #state{
		file_index = FileIndex2,
		store_id = StoreID,
		range_start = RangeStart,
		range_end = RangeEnd,
		store_id_label = StoreIDLabel
	},

	EntropyContext = big_entropy_gen:initialize_context(
		StoreID, big_storage_module:get_packing(StoreID)),
	State2 = State#state{ entropy_context = EntropyContext },

	{ok, State2}.

warn_custom_chunk_group_size(StoreID) ->
	case StoreID == "default" andalso get_chunk_group_size() /= ?CHUNK_GROUP_SIZE of
		true ->
			%% This warning applies to all store ids, but we will only print it when loading
			%% the default StoreID to ensure it is only printed once.
			WarningMessage = "WARNING: changing chunk_storage_file_size is not "
				"recommended and may cause errors if different sizes are used for the same "
				"chunk storage files.",
			big:console(WarningMessage),
			?LOG_WARNING(WarningMessage);
		false ->
			ok
	end.

handle_cast(entropy_complete, State) ->
	#state{ entropy_context = {_, RewardAddr} } = State,
	State2 = State#state{ entropy_context = {true, RewardAddr} },
	{noreply, State2};

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_call({put, PaddedEndOffset, Chunk, Packing}, _From, State)
		when byte_size(Chunk) == ?DATA_CHUNK_SIZE ->
	#state{ store_id = StoreID, store_id_label = StoreIDLabel,
		entropy_context = EntropyContext, file_index = FileIndex } = State,

	{PackingLabel, State2} = get_packing_label(Packing, State),
	Result = store_chunk(
		PaddedEndOffset, Chunk, Packing, StoreID,
		StoreIDLabel, PackingLabel, FileIndex, EntropyContext),
	case Result of
		{ok, FileIndex2, NewPacking} ->
			{reply, {ok, NewPacking}, State2#state{ file_index = FileIndex2 }};
		Error ->
			{reply, Error, State2}
	end;

handle_call({delete, PaddedEndOffset}, _From, State) ->
	#state{	store_id = StoreID } = State,
	StartOffset = PaddedEndOffset - ?DATA_CHUNK_SIZE,
	case big_sync_record:delete(PaddedEndOffset, StartOffset, big_chunk_storage, StoreID) of
		ok ->
			case big_entropy_storage:delete_record(PaddedEndOffset, StoreID) of
				ok ->
					case delete_chunk(PaddedEndOffset, StoreID) of
						ok ->
							{reply, ok, State};
						Error ->
							{reply, Error, State}
					end;
				Error2 ->
					{reply, Error2, State}
			end;
		Error3 ->
			{reply, Error3, State}
	end;

handle_call(reset, _, #state{ store_id = StoreID, file_index = FileIndex } = State) ->
	maps:map(
		fun(_Key, Filepath) ->
			file:delete(Filepath)
		end,
		FileIndex
	),
	ok = big_sync_record:cut(0, big_chunk_storage, StoreID),
	erlang:erase(),
	{reply, ok, State#state{ file_index = #{} }};

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_info({Ref, _Reply}, State) when is_reference(Ref) ->
	?LOG_ERROR([{event, stale_gen_server_call_reply}, {ref, Ref}, {reply, _Reply}]),
	%% A stale gen_server:call reply.
	{noreply, State};

handle_info({'EXIT', _PID, normal}, State) ->
	{noreply, State};

handle_info({entropy_generated, _Ref, _Entropy}, State) ->
	?LOG_WARNING([{event, entropy_generation_timed_out}]),
	{noreply, State};

handle_info(Info, State) ->
	?LOG_ERROR([{event, unhandled_info}, {info, io_lib:format("~p", [Info])}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	sync_and_close_files(),
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

get_chunk_group_size() ->
	{ok, Config} = application:get_env(arweave, config),
	Config#config.chunk_storage_file_size.

get_filepath(Name, StoreID) ->
	{ok, Config} = application:get_env(arweave, config),
	DataDir = Config#config.data_dir,
	ChunkDir = get_chunk_storage_path(DataDir, StoreID),
	filename:join([ChunkDir, Name]).

store_chunk(
		PaddedEndOffset, Chunk, Packing, StoreID, StoreIDLabel,
		PackingLabel, FileIndex, EntropyContext) ->
	case Packing == unpacked_padded of
		true ->
			big_entropy_storage:record_chunk(
				PaddedEndOffset, Chunk, StoreID,
				StoreIDLabel, PackingLabel, FileIndex, EntropyContext);
		false ->
			record_chunk(
				PaddedEndOffset, Chunk, Packing, StoreID, 
				StoreIDLabel, PackingLabel, FileIndex)
	end.

record_chunk(
		PaddedEndOffset, Chunk, Packing, StoreID, StoreIDLabel, PackingLabel, FileIndex) ->
	case write_chunk(PaddedEndOffset, Chunk, FileIndex, StoreID) of
		{ok, Filepath} ->
			prometheus_counter:inc(chunks_stored, [PackingLabel, StoreIDLabel]),
			case big_sync_record:add(
					PaddedEndOffset, PaddedEndOffset - ?DATA_CHUNK_SIZE,
					sync_record_id(Packing), StoreID) of
				ok ->
					ChunkFileStart = get_chunk_file_start(PaddedEndOffset),
					ets:insert(chunk_storage_file_index,
						{{ChunkFileStart, StoreID}, Filepath}),
					{ok, maps:put(ChunkFileStart, Filepath, FileIndex), Packing};
				Error ->
					Error
			end;
		Error2 ->
			Error2
	end.

sync_record_id(unpacked_padded) ->
	%% Entropy indexing changed between 2.9.0 and 2.9.1. So we'll use a new
	%% sync_record id (ar_chunk_storage_replica_2_9_1_unpacked) going forward.
	%% The old id (ar_chunk_storage_replica_2_9_unpacked) should not be used.
	ar_chunk_storage_replica_2_9_1_unpacked;
sync_record_id(_Packing) ->
	ar_chunk_storage.

get_chunk_file_start(EndOffset) ->
	StartOffset = EndOffset - ?DATA_CHUNK_SIZE,
	get_chunk_file_start_by_start_offset(StartOffset).

get_chunk_file_start_by_start_offset(StartOffset) ->
	ar_util:floor_int(StartOffset, get_chunk_group_size()).

write_chunk(PaddedOffset, Chunk, FileIndex, StoreID) ->
	{_ChunkFileStart, Filepath, Position, ChunkOffset} =
				locate_chunk_on_disk(PaddedOffset, StoreID, FileIndex),
	case get_handle_by_filepath(Filepath) of
		{error, _} = Error ->
			Error;
		F ->
			write_chunk2(PaddedOffset, ChunkOffset, Chunk, Filepath, F, Position)
	end.

filepath(ChunkFileStart, FileIndex, StoreID) ->
	case maps:get(ChunkFileStart, FileIndex, not_found) of
		not_found ->
			filepath(ChunkFileStart, StoreID);
		Filepath ->
			Filepath
	end.

filepath(ChunkFileStart, StoreID) ->
	get_filepath(integer_to_binary(ChunkFileStart), StoreID).

get_handle_by_filepath(Filepath) ->
	case erlang:get({write_handle, Filepath}) of
		undefined ->
			case file:open(Filepath, [read, write, raw]) of
				{error, Reason} = Error ->
					?LOG_ERROR([
						{event, failed_to_open_chunk_file},
						{file, Filepath},
						{reason, io_lib:format("~p", [Reason])}
					]),
					Error;
				{ok, F} ->
					erlang:put({write_handle, Filepath}, F),
					F
			end;
		F ->
			F
	end.

write_chunk2(_PaddedOffset, ChunkOffset, Chunk, Filepath, F, Position) ->
	Result = file:pwrite(F, Position, [<< ChunkOffset:?OFFSET_BIT_SIZE >> | Chunk]),
	case Result of
		{error, _Reason} = Error ->
			Error;
		ok ->
			{ok, Filepath}
	end.

get_special_zero_offset() ->
	?DATA_CHUNK_SIZE.

get_position_and_relative_chunk_offset(ChunkFileStart, Offset) ->
	BucketPickOffset = Offset - ?DATA_CHUNK_SIZE,
	get_position_and_relative_chunk_offset_by_start_offset(ChunkFileStart, BucketPickOffset).

get_position_and_relative_chunk_offset_by_start_offset(ChunkFileStart, BucketPickOffset) ->
	BucketStart = ar_util:floor_int(BucketPickOffset, ?DATA_CHUNK_SIZE),
	ChunkOffset = case BucketPickOffset - BucketStart of
		0 ->
			%% Represent 0 as the largest possible offset plus one,
			%% to distinguish zero offset from not yet written data.
			get_special_zero_offset();
		Offset ->
			Offset
	end,
	RelativeOffset = BucketStart - ChunkFileStart,
	Position = RelativeOffset + ?OFFSET_SIZE * (RelativeOffset div ?DATA_CHUNK_SIZE),
	{Position, ChunkOffset}.

delete_chunk(PaddedOffset, StoreID) ->
	{_ChunkFileStart, Filepath, Position, _ChunkOffset} =
		locate_chunk_on_disk(PaddedOffset, StoreID),
	case file:open(Filepath, [read, write, raw]) of
		{ok, F} ->
			ZeroChunk =
				case erlang:get(zero_chunk) of
					undefined ->
						OffsetBytes = << 0:?OFFSET_BIT_SIZE >>,
						ZeroBytes = << <<0>> || _ <- lists:seq(1, ?DATA_CHUNK_SIZE) >>,
						Chunk = << OffsetBytes/binary, ZeroBytes/binary >>,
						%% Cache the zero chunk in the process memory, constructing
						%% it is expensive.
						erlang:put(zero_chunk, Chunk),
						Chunk;
					Chunk ->
						Chunk
				end,
			big_entropy_storage:acquire_semaphore(Filepath),
			Result = file:pwrite(F, Position, ZeroChunk),
			big_entropy_storage:release_semaphore(Filepath),
			Result;
		{error, enoent} ->
			ok;
		Error ->
			Error
	end.

get(Byte, Start, ChunkFileStart, StoreID, ChunkCount) ->
	ReadChunks =
		case erlang:get({cfile, {ChunkFileStart, StoreID}}) of
			undefined ->
				case ets:lookup(chunk_storage_file_index, {ChunkFileStart, StoreID}) of
					[] ->
						[];
					[{_, Filepath}] ->
						read_chunk(Byte, Start, ChunkFileStart, Filepath, ChunkCount, StoreID)
				end;
			File ->
				read_chunk2(Byte, Start, ChunkFileStart, File, ChunkCount, StoreID)
		end,
	filter_by_sync_record(ReadChunks, Byte, Start, ChunkFileStart, StoreID, ChunkCount).

read_chunk(Byte, Start, ChunkFileStart, Filepath, ChunkCount, StoreID) ->
	case file:open(Filepath, [read, raw, binary]) of
		{error, enoent} ->
			[];
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_open_chunk_file},
				{byte, Byte},
				{reason, io_lib:format("~p", [Reason])}
			]),
			[];
		{ok, File} ->
			Result = read_chunk2(Byte, Start, ChunkFileStart, File, ChunkCount, StoreID),
			file:close(File),
			Result
	end.

read_chunk2(Byte, Start, ChunkFileStart, File, ChunkCount, StoreID) ->
	{Position, _ChunkOffset} =
			get_position_and_relative_chunk_offset_by_start_offset(ChunkFileStart, Start),
	BucketStart = ar_util:floor_int(Start, ?DATA_CHUNK_SIZE),
	read_chunk3(Byte, Position, BucketStart, File, ChunkCount, StoreID).

read_chunk3(Byte, Position, BucketStart, File, ChunkCount, StoreID) ->
	StartTime = erlang:monotonic_time(),
	case file:pread(File, Position, (?DATA_CHUNK_SIZE + ?OFFSET_SIZE) * ChunkCount) of
		{ok, << ChunkOffset:?OFFSET_BIT_SIZE, _Chunk/binary >> = Bin} ->
			big_metrics:record_rate_metric(
				StartTime, byte_size(Bin), chunk_read_rate_bytes_per_second, [StoreID, raw]),
			prometheus_counter:inc(chunks_read, [StoreID], ChunkCount),
			case is_offset_valid(Byte, BucketStart, ChunkOffset) of
				true ->
					extract_end_offset_chunk_pairs(Bin, BucketStart, 1);
				false ->
					[]
			end;
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_read_chunk},
				{byte, Byte},
				{position, Position},
				{reason, io_lib:format("~p", [Reason])}
			]),
			[];
		eof ->
			[]
	end.

extract_end_offset_chunk_pairs(
		<< 0:?OFFSET_BIT_SIZE, _ZeroChunk:?DATA_CHUNK_SIZE/binary, Rest/binary >>,
		BucketStart,
		Shift
 ) ->
	extract_end_offset_chunk_pairs(Rest, BucketStart, Shift + 1);
extract_end_offset_chunk_pairs(
		<< ChunkOffset:?OFFSET_BIT_SIZE, Chunk:?DATA_CHUNK_SIZE/binary, Rest/binary >>,
		BucketStart,
		Shift
 ) ->
	ChunkOffsetLimit = ?DATA_CHUNK_SIZE,
	EndOffset =
		BucketStart
		+ (ChunkOffset rem ChunkOffsetLimit)
		+ (?DATA_CHUNK_SIZE * Shift),
	[{EndOffset, Chunk}
			| extract_end_offset_chunk_pairs(Rest, BucketStart, Shift + 1)];
extract_end_offset_chunk_pairs(<<>>, _BucketStart, _Shift) ->
	[];
extract_end_offset_chunk_pairs(<< ChunkOffset:?OFFSET_BIT_SIZE, Chunk/binary >>,
		BucketStart, Shift) ->
	?LOG_ERROR([{event, unexpected_chunk_data}, {chunk_offset, ChunkOffset},
			{bucket_start, BucketStart}, {shift, Shift}, {chunk_size, byte_size(Chunk)}]),
	[].

is_offset_valid(_Byte, _BucketStart, 0) ->
	%% 0 is interpreted as "data has not been written yet".
	false;
is_offset_valid(Byte, BucketStart, ChunkOffset) ->
	Delta = Byte - (BucketStart + ChunkOffset rem ?DATA_CHUNK_SIZE),
	Delta >= 0 andalso Delta < ?DATA_CHUNK_SIZE.

filter_by_sync_record(Chunks, _Byte, _Start, _ChunkFileStart, _StoreID, 1) ->
	%% The code paths which query a single chunk have already implicitly checked that
	%% the chunk belongs to the sync_record. E.g. ar_chunk_storage:get/2
	Chunks;
filter_by_sync_record([], _Byte, _Start, _ChunkFileStart, _StoreID, _ChunkCount) ->
	[];
filter_by_sync_record([{PaddedEndOffset, Chunk} | Rest], Byte, Start, ChunkFileStart, StoreID, ChunkCount) ->
	case big_sync_record:is_recorded(PaddedEndOffset, big_chunk_storage, StoreID) of
		false ->
			%% Filter out repacking artifacts when reading a range of chunks.
			%% This warning may also occur due to unlucky timing when the chunk is
			%% being removed.
			?LOG_WARNING([{event, found_chunk_not_in_sync_record},
					{padded_end_offset, PaddedEndOffset},
							{store_id, StoreID},
							{byte, Byte},
							{queried_range_start, Start},
							{chunk_file_start, ChunkFileStart},
							{requested_chunk_count, ChunkCount}]),
			filter_by_sync_record(Rest, Byte, Start, ChunkFileStart, StoreID, ChunkCount);
		_ ->
			[{PaddedEndOffset, Chunk}
				| filter_by_sync_record(Rest, Byte, Start, ChunkFileStart, StoreID, ChunkCount)]
	end.

close_files([{cfile, {_, StoreID} = Key} | Keys], StoreID) ->
	file:close(erlang:get({cfile, Key})),
	close_files(Keys, StoreID);
close_files([_ | Keys], StoreID) ->
	close_files(Keys, StoreID);
close_files([], _StoreID) ->
	ok.

read_file_index(Dir) ->
	ChunkDir = filename:join(Dir, ?CHUNK_DIR),
	{ok, Filenames} = file:list_dir(ChunkDir),
	lists:foldl(
		fun(Filename, Acc) ->
			case catch list_to_integer(Filename) of
				Key when is_integer(Key) ->
					maps:put(Key, filename:join(ChunkDir, Filename), Acc);
				_ ->
					Acc
			end
		end,
		#{},
		Filenames
	).

sync_and_close_files() ->
	sync_and_close_files(erlang:get_keys()).

sync_and_close_files([{write_handle, _} = Key | Keys]) ->
	F = erlang:get(Key),
	ok = file:sync(F),
	file:close(F),
	sync_and_close_files(Keys);
sync_and_close_files([_ | Keys]) ->
	sync_and_close_files(Keys);
sync_and_close_files([]) ->
	ok.

list_files(DataDir, StoreID) ->
	Dir = get_storage_module_path(DataDir, StoreID),
	ok = filelib:ensure_dir(Dir ++ "/"),
	ok = filelib:ensure_dir(filename:join(Dir, ?CHUNK_DIR) ++ "/"),
	StorageIndex = read_file_index(Dir),
	maps:values(StorageIndex).

files_to_defrag(StorageModules, DataDir, ByteSizeThreshold, Sizes) ->
	AllFiles = lists:flatmap(
		fun(StorageModule) ->
			list_files(DataDir, big_storage_module:id(StorageModule))
		end, StorageModules),
	lists:filter(
		fun(Filepath) ->
			case file:read_file_info(Filepath) of
				{ok, #file_info{ size = Size }} ->
					LastSize = maps:get(Filepath, Sizes, 1),
					Growth = (Size - LastSize) / LastSize,
					Size >= ByteSizeThreshold andalso Growth > 0.1;
				{error, Reason} ->
					?LOG_ERROR([
						{event, failed_to_read_chunk_file_info},
						{file, Filepath},
						{reason, io_lib:format("~p", [Reason])}
					]),
					false
			end
		end, AllFiles).

defrag_files([]) ->
	ok;
defrag_files([Filepath | Rest]) ->
	?LOG_DEBUG([{event, defragmenting_file}, {file, Filepath}]),
	big:console("Defragmenting ~s...~n", [Filepath]),
	TmpFilepath = Filepath ++ ".tmp",
	DefragCmd = io_lib:format("rsync --sparse --quiet ~ts ~ts", [Filepath, TmpFilepath]),
	MoveDefragCmd = io_lib:format("mv ~ts ~ts", [TmpFilepath, Filepath]),
	%% We expect nothing to be returned on successful calls.
	[] = os:cmd(DefragCmd),
	[] = os:cmd(MoveDefragCmd),
	big:console("Defragmented ~s...~n", [Filepath]),
	defrag_files(Rest).

update_sizes_file([], Sizes) ->
	{ok, Config} = application:get_env(arweave, config),
	SizesFile = filename:join(Config#config.data_dir, "chunks_sizes"),
	case file:open(SizesFile, [write, raw]) of
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_open_chunk_sizes_file},
				{file, SizesFile},
				{reason, io_lib:format("~p", [Reason])}
			]),
			error;
		{ok, F} ->
			SizesBinary = erlang:term_to_binary(Sizes),
			ok = file:write(F, SizesBinary),
			file:close(F)
	end;
update_sizes_file([Filepath | Rest], Sizes) ->
	case file:read_file_info(Filepath) of
		{ok, #file_info{ size = Size }} ->
			update_sizes_file(Rest, Sizes#{ Filepath => Size });
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_read_chunk_file_info},
				{file, Filepath},
				{reason, io_lib:format("~p", [Reason])}
			]),
			error
	end.

read_chunks_sizes(DataDir) ->
	SizesFile = filename:join(DataDir, "chunks_sizes"),
	case file:read_file(SizesFile) of
		{ok, Content} ->
			erlang:binary_to_term(Content);
		{error, enoent} ->
			#{};
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_read_chunk_sizes_file},
				{file, SizesFile},
				{reason, io_lib:format("~p", [Reason])}
			]),
			error
	end.

modules_to_defrag(#config{defragmentation_modules = [_ | _] = Modules}) -> Modules;
modules_to_defrag(#config{storage_modules = Modules}) -> Modules.

get_packing_label(Packing, State) ->
	case maps:get(Packing, State#state.packing_labels, not_found) of
		not_found ->
			Label = big_storage_module:packing_label(Packing),
			Map = maps:put(Packing, Label, State#state.packing_labels),
			{Label, State#state{ packing_labels = Map }};
		Label ->
			{Label, State}
	end.

%%%===================================================================
%%% Tests.
%%%===================================================================

chunk_bucket_test() ->
	case ?STRICT_DATA_SPLIT_THRESHOLD of
		786432 ->
			ok;
		_ ->
			throw(unexpected_strict_data_split_threshold)
	end,

	%% get_chunk_bucket_end pads the provided offset
	%% get_chunk_bucket_start does not padd the provided offset

	%% At and before the STRICT_DATA_SPLIT_THRESHOLD, offsets are not padded.
	?assertEqual(262144, get_chunk_bucket_end(0)),
	?assertEqual(0, get_chunk_bucket_start(0)),

	?assertEqual(262144, get_chunk_bucket_end(1)),
	?assertEqual(0, get_chunk_bucket_start(1)),

	?assertEqual(262144, get_chunk_bucket_end(?DATA_CHUNK_SIZE - 1)),
	?assertEqual(0, get_chunk_bucket_start(?DATA_CHUNK_SIZE - 1)),

	?assertEqual(262144, get_chunk_bucket_end(?DATA_CHUNK_SIZE)),
	?assertEqual(0, get_chunk_bucket_start(?DATA_CHUNK_SIZE)),

	?assertEqual(262144, get_chunk_bucket_end(?DATA_CHUNK_SIZE + 1)),
	?assertEqual(0, get_chunk_bucket_start(?DATA_CHUNK_SIZE + 1)),

	?assertEqual(524288, get_chunk_bucket_end(2 * ?DATA_CHUNK_SIZE)),
	?assertEqual(262144, get_chunk_bucket_start(2 * ?DATA_CHUNK_SIZE)),

	?assertEqual(524288, get_chunk_bucket_end(2 * ?DATA_CHUNK_SIZE + 1)),
	?assertEqual(262144, get_chunk_bucket_start(2 * ?DATA_CHUNK_SIZE + 1)),

	?assertEqual(524288, get_chunk_bucket_end(3 * ?DATA_CHUNK_SIZE - 1)),
	?assertEqual(262144, get_chunk_bucket_start(3 * ?DATA_CHUNK_SIZE - 1)),

	?assertEqual(786432, get_chunk_bucket_end(3 * ?DATA_CHUNK_SIZE)),
	?assertEqual(524288, get_chunk_bucket_start(3 * ?DATA_CHUNK_SIZE)),

	%% After the STRICT_DATA_SPLIT_THRESHOLD, offsets are padded.
	?assertEqual(1048576, get_chunk_bucket_end(3 * ?DATA_CHUNK_SIZE + 1)),
	?assertEqual(786432, get_chunk_bucket_start(3 * ?DATA_CHUNK_SIZE + 1)),

	?assertEqual(1048576, get_chunk_bucket_end(4 * ?DATA_CHUNK_SIZE - 1)),
	?assertEqual(786432, get_chunk_bucket_start(4 * ?DATA_CHUNK_SIZE - 1)),

	?assertEqual(1048576, get_chunk_bucket_end(4 * ?DATA_CHUNK_SIZE)),
	?assertEqual(786432, get_chunk_bucket_start(4 * ?DATA_CHUNK_SIZE)),

	?assertEqual(1310720, get_chunk_bucket_end(4 * ?DATA_CHUNK_SIZE + 1)),
	?assertEqual(1048576, get_chunk_bucket_start(4 * ?DATA_CHUNK_SIZE + 1)),

	?assertEqual(1310720, get_chunk_bucket_end(5 * ?DATA_CHUNK_SIZE - 1)),
	?assertEqual(1048576, get_chunk_bucket_start(5 * ?DATA_CHUNK_SIZE - 1)),

	?assertEqual(1310720, get_chunk_bucket_end(5 * ?DATA_CHUNK_SIZE)),
	?assertEqual(1048576, get_chunk_bucket_start(5 * ?DATA_CHUNK_SIZE)),

	?assertEqual(1572864, get_chunk_bucket_end(5 * ?DATA_CHUNK_SIZE + 1)),
	?assertEqual(1310720, get_chunk_bucket_start(5 * ?DATA_CHUNK_SIZE + 1)),

	?assertEqual(1572864, get_chunk_bucket_end(6 * ?DATA_CHUNK_SIZE - 1)),
	?assertEqual(1310720, get_chunk_bucket_start(6 * ?DATA_CHUNK_SIZE - 1)),

	?assertEqual(1572864, get_chunk_bucket_end(6 * ?DATA_CHUNK_SIZE)),
	?assertEqual(1310720, get_chunk_bucket_start(6 * ?DATA_CHUNK_SIZE)),

	?assertEqual(1835008, get_chunk_bucket_end(6 * ?DATA_CHUNK_SIZE + 1)),
	?assertEqual(1572864, get_chunk_bucket_start(6 * ?DATA_CHUNK_SIZE + 1)),
	
	?assertEqual(1835008, get_chunk_bucket_end(7 * ?DATA_CHUNK_SIZE)),
	?assertEqual(1572864, get_chunk_bucket_start(7 * ?DATA_CHUNK_SIZE)),

	?assertEqual(2097152, get_chunk_bucket_end(8 * ?DATA_CHUNK_SIZE)),
	?assertEqual(1835008, get_chunk_bucket_start(8 * ?DATA_CHUNK_SIZE)),

	?assertEqual(2359296, get_chunk_bucket_end(9 * ?DATA_CHUNK_SIZE)),
	?assertEqual(2097152, get_chunk_bucket_start(9 * ?DATA_CHUNK_SIZE)),

	?assertEqual(2621440, get_chunk_bucket_end(10 * ?DATA_CHUNK_SIZE)),
	?assertEqual(2359296, get_chunk_bucket_start(10 * ?DATA_CHUNK_SIZE)).
	
well_aligned_test_() ->
	{timeout, 20, fun test_well_aligned/0}.

test_well_aligned() ->
	clear("default"),
	Packing = big_storage_module:get_packing("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C3 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	{ok, unpacked} = big_chunk_storage:put(2 * ?DATA_CHUNK_SIZE, C1, Packing, "default"),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE),
	?assertEqual(not_found, big_chunk_storage:get(2 * ?DATA_CHUNK_SIZE, "default")),
	?assertEqual(not_found, big_chunk_storage:get(2 * ?DATA_CHUNK_SIZE + 1, "default")),
	big_chunk_storage:delete(2 * ?DATA_CHUNK_SIZE),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE),
	big_chunk_storage:put(?DATA_CHUNK_SIZE, C2, Packing, "default"),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE),
	big_chunk_storage:put(2 * ?DATA_CHUNK_SIZE, C1, Packing, "default"),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			big_chunk_storage:get_range(0, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			big_chunk_storage:get_range(1, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			big_chunk_storage:get_range(1, 2 * ?DATA_CHUNK_SIZE - 1)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			big_chunk_storage:get_range(0, 3 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			big_chunk_storage:get_range(0, ?DATA_CHUNK_SIZE + 1)),
	big_chunk_storage:put(3 * ?DATA_CHUNK_SIZE, C3, Packing, "default"),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE),
	?assertEqual(not_found, big_chunk_storage:get(3 * ?DATA_CHUNK_SIZE, "default")),
	?assertEqual(not_found, big_chunk_storage:get(3 * ?DATA_CHUNK_SIZE + 1, "default")),
	big_chunk_storage:put(2 * ?DATA_CHUNK_SIZE, C2, Packing, "default"),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	assert_get(C2, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE),
	big_chunk_storage:delete(?DATA_CHUNK_SIZE),
	assert_get(not_found, ?DATA_CHUNK_SIZE),
	?assertEqual([], big_chunk_storage:get_range(0, ?DATA_CHUNK_SIZE)),
	assert_get(C2, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE),
	?assertEqual([{2 * ?DATA_CHUNK_SIZE, C2}, {3 * ?DATA_CHUNK_SIZE, C3}],
			big_chunk_storage:get_range(0, 4 * ?DATA_CHUNK_SIZE)),
	?assertEqual([], big_chunk_storage:get_range(7 * ?DATA_CHUNK_SIZE, 13 * ?DATA_CHUNK_SIZE)).

not_aligned_test_() ->
	{timeout, 20, fun test_not_aligned/0}.

test_not_aligned() ->
	clear("default"),
	Packing = big_storage_module:get_packing("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C3 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	big_chunk_storage:put(2 * ?DATA_CHUNK_SIZE + 7, C1, Packing, "default"),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE + 7),
	big_chunk_storage:delete(2 * ?DATA_CHUNK_SIZE + 7),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE + 7),
	big_chunk_storage:put(2 * ?DATA_CHUNK_SIZE + 7, C1, Packing, "default"),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE + 7),
	?assertEqual(not_found, big_chunk_storage:get(2 * ?DATA_CHUNK_SIZE + 7, "default")),
	?assertEqual(not_found, big_chunk_storage:get(?DATA_CHUNK_SIZE + 7 - 1, "default")),
	?assertEqual(not_found, big_chunk_storage:get(?DATA_CHUNK_SIZE, "default")),
	?assertEqual(not_found, big_chunk_storage:get(?DATA_CHUNK_SIZE - 1, "default")),
	?assertEqual(not_found, big_chunk_storage:get(0, "default")),
	?assertEqual(not_found, big_chunk_storage:get(1, "default")),
	big_chunk_storage:put(?DATA_CHUNK_SIZE + 3, C2, Packing, "default"),
	assert_get(C2, ?DATA_CHUNK_SIZE + 3),
	?assertEqual(not_found, big_chunk_storage:get(0, "default")),
	?assertEqual(not_found, big_chunk_storage:get(1, "default")),
	?assertEqual(not_found, big_chunk_storage:get(2, "default")),
	big_chunk_storage:delete(2 * ?DATA_CHUNK_SIZE + 7),
	assert_get(C2, ?DATA_CHUNK_SIZE + 3),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE + 7),
	big_chunk_storage:put(3 * ?DATA_CHUNK_SIZE + 7, C3, Packing, "default"),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE + 7),
	big_chunk_storage:put(3 * ?DATA_CHUNK_SIZE + 7, C1, Packing, "default"),
	assert_get(C1, 3 * ?DATA_CHUNK_SIZE + 7),
	big_chunk_storage:put(4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2, C2, Packing, "default"),
	assert_get(C2, 4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2),
	?assertEqual(
		not_found,
		big_chunk_storage:get(4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2, "default")
	),
	?assertEqual(not_found, big_chunk_storage:get(3 * ?DATA_CHUNK_SIZE + 7, "default")),
	?assertEqual(not_found, big_chunk_storage:get(3 * ?DATA_CHUNK_SIZE + 8, "default")),
	big_chunk_storage:put(5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2, Packing, "default"),
	assert_get(C2, 5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE + 7),
	big_chunk_storage:delete(4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2),
	assert_get(not_found, 4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2),
	assert_get(C2, 5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1),
	assert_get(C1, 3 * ?DATA_CHUNK_SIZE + 7),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1}],
			big_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1}],
			big_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 6, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			%% The end offset of the second chunk is bigger than Start + Size but
			%% it is included because Start + Size is bigger than the start offset
			%% of the bucket where the last chunk is placed.
			big_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7, 2 * ?DATA_CHUNK_SIZE + 1)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			big_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7, 3 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			big_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7 - 1, 3 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			big_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE, 4 * ?DATA_CHUNK_SIZE)).

cross_file_aligned_test_() ->
	{timeout, 20, fun test_cross_file_aligned/0}.

test_cross_file_aligned() ->
	clear("default"),
	Packing = big_storage_module:get_packing("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	big_chunk_storage:put(get_chunk_group_size(), C1, Packing, "default"),
	assert_get(C1, get_chunk_group_size()),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size(), "default")),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size() + 1, "default")),
	?assertEqual(not_found, big_chunk_storage:get(0, "default")),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size() - ?DATA_CHUNK_SIZE - 1, "default")),
	big_chunk_storage:put(get_chunk_group_size() + ?DATA_CHUNK_SIZE, C2, Packing, "default"),
	assert_get(C2, get_chunk_group_size() + ?DATA_CHUNK_SIZE),
	assert_get(C1, get_chunk_group_size()),
	?assertEqual([{get_chunk_group_size(), C1}, {get_chunk_group_size() + ?DATA_CHUNK_SIZE, C2}],
			big_chunk_storage:get_range(get_chunk_group_size() - ?DATA_CHUNK_SIZE,
					2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{get_chunk_group_size(), C1}, {get_chunk_group_size() + ?DATA_CHUNK_SIZE, C2}],
			big_chunk_storage:get_range(get_chunk_group_size() - 2 * ?DATA_CHUNK_SIZE - 1,
					4 * ?DATA_CHUNK_SIZE)),
	?assertEqual(not_found, big_chunk_storage:get(0, "default")),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size() - ?DATA_CHUNK_SIZE - 1, "default")),
	big_chunk_storage:delete(get_chunk_group_size(), "default"),
	assert_get(not_found, get_chunk_group_size(), "default"),
	assert_get(C2, get_chunk_group_size() + ?DATA_CHUNK_SIZE),
	big_chunk_storage:put(get_chunk_group_size(), C2, Packing, "default"),
	assert_get(C2, get_chunk_group_size()).

cross_file_not_aligned_test_() ->
	{timeout, 20, fun test_cross_file_not_aligned/0}.

test_cross_file_not_aligned() ->
	clear("default"),
	Packing = big_storage_module:get_packing("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C3 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	big_chunk_storage:put(get_chunk_group_size() + 1, C1, Packing, "default"),
	assert_get(C1, get_chunk_group_size() + 1),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size() + 1, "default")),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size() - ?DATA_CHUNK_SIZE, "default")),
	big_chunk_storage:put(2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2, C2, Packing, "default"),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size() + 1, "default")),
	big_chunk_storage:put(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2, C3, Packing, "default"),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	assert_get(C3, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	?assertEqual([{2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2, C3},
			{2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2, C2}],
			big_chunk_storage:get_range(2 * get_chunk_group_size()
					- ?DATA_CHUNK_SIZE div 2 - ?DATA_CHUNK_SIZE, ?DATA_CHUNK_SIZE * 2)),
	?assertEqual(not_found, big_chunk_storage:get(get_chunk_group_size() + 1, "default")),
	?assertEqual(
		not_found,
		big_chunk_storage:get(get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2 - 1, "default")
	),
	big_chunk_storage:delete(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	assert_get(not_found, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	assert_get(C1, get_chunk_group_size() + 1),
	big_chunk_storage:delete(get_chunk_group_size() + 1),
	assert_get(not_found, get_chunk_group_size() + 1),
	assert_get(not_found, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	big_chunk_storage:delete(2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	assert_get(not_found, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	big_chunk_storage:delete(get_chunk_group_size() + 1),
	big_chunk_storage:delete(100 * get_chunk_group_size() + 1),
	big_chunk_storage:put(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2, C1, Packing, "default"),
	assert_get(C1, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	?assertEqual(not_found,
			big_chunk_storage:get(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2, "default")).

clear(StoreID) ->
	ok = gen_server:call(name(StoreID), reset).

assert_get(Expected, Offset) ->
	assert_get(Expected, Offset, "default").

assert_get(Expected, Offset, StoreID) ->
	ExpectedResult =
		case Expected of
			not_found ->
				not_found;
			_ ->
				{Offset, Expected}
		end,
	?assertEqual(ExpectedResult, big_chunk_storage:get(Offset - 1, StoreID)),
	?assertEqual(ExpectedResult, big_chunk_storage:get(Offset - 2, StoreID)),
	?assertEqual(ExpectedResult, big_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE, StoreID)),
	?assertEqual(ExpectedResult, big_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE + 1, StoreID)),
	?assertEqual(ExpectedResult, big_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE + 2, StoreID)),
	?assertEqual(ExpectedResult,
			big_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 2, StoreID)),
	?assertEqual(ExpectedResult,
			big_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 2 + 1, StoreID)),
	?assertEqual(ExpectedResult,
			big_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 2 - 1, StoreID)),
	?assertEqual(ExpectedResult,
			big_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 3, StoreID)).

defrag_command_test() ->
	RandomID = crypto:strong_rand_bytes(16),
	Filepath = "test_defrag_" ++ binary_to_list(ar_util:encode(RandomID)),
	{ok, F} = file:open(Filepath, [binary, write]),
	{O1, C1} = {236, crypto:strong_rand_bytes(262144)},
	{O2, C2} = {262144, crypto:strong_rand_bytes(262144)},
	{O3, C3} = {262143, crypto:strong_rand_bytes(262144)},
	file:pwrite(F, 1, <<"a">>),
	file:pwrite(F, 1000, <<"b">>),
	file:pwrite(F, 1000000, <<"cde">>),
	file:pwrite(F, 10000001, << O1:24, C1/binary, O2:24, C2/binary >>),
	file:pwrite(F, 30000001, << O3:24, C3/binary >>),
	file:close(F),
	defrag_files([Filepath]),
	{ok, F2} = file:open(Filepath, [binary, read]),
	?assertEqual({ok, <<0>>}, file:pread(F2, 0, 1)),
	?assertEqual({ok, <<"a">>}, file:pread(F2, 1, 1)),
	?assertEqual({ok, <<0>>}, file:pread(F2, 2, 1)),
	?assertEqual({ok, <<"b">>}, file:pread(F2, 1000, 1)),
	?assertEqual({ok, <<"c">>}, file:pread(F2, 1000000, 1)),
	?assertEqual({ok, <<"cde">>}, file:pread(F2, 1000000, 3)),
	?assertEqual({ok, C1}, file:pread(F2, 10000001 + 3, 262144)),
	?assertMatch({ok, << O1:24, _/binary >>}, file:pread(F2, 10000001, 10)),
	?assertMatch({ok, << O1:24, C1:262144/binary, O2:24, C2:262144/binary,
			0:((262144 + 3) * 2 * 8) >>}, file:pread(F2, 10000001, (262144 + 3) * 4)),
	?assertMatch({ok, << O3:24, C3:262144/binary >>},
			file:pread(F2, 30000001, 262144 + 3 + 100)). % End of file => +100 is ignored.