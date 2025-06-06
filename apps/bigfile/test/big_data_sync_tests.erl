-module(big_data_sync_tests).

-include_lib("eunit/include/eunit.hrl").

-include("../include/big.hrl").
-include("../include/big_consensus.hrl").
-include("../include/big_config.hrl").

-import(big_test_node, [assert_wait_until_height/2, test_with_mocked_functions/2]).

recovers_from_corruption_test_() ->
	{timeout, 140, fun test_recovers_from_corruption/0}.

test_recovers_from_corruption() ->
	big_test_data_sync:setup_nodes(),
	{ok, Config} = application:get_env(bigfile, config),
	StoreID = big_storage_module:id(hd(big_storage_module:get_all(262144 * 3))),
	?debugFmt("Corrupting ~s...", [StoreID]),
	[big_chunk_storage:write_chunk(PaddedEndOffset, << 0:(262144*8) >>, #{}, StoreID)
			|| PaddedEndOffset <- lists:seq(262144, 262144 * 3, 262144)],
	big_test_node:mine(),
	big_test_node:assert_wait_until_height(main, 1).

syncs_data_test_() ->
	{timeout, 240, fun test_syncs_data/0}.

test_syncs_data() ->
	Wallet = big_test_data_sync:setup_nodes(),
	Records = big_test_data_sync:post_random_blocks(Wallet),
	RecordsWithProofs = lists:flatmap(
			fun({B, TX, Chunks}) -> 
				big_test_data_sync:get_records_with_proofs(B, TX, Chunks) end, Records),
	lists:foreach(
		fun({_, _, _, {_, Proof}}) ->
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					big_test_node:post_chunk(main, big_serialize:jsonify(Proof))),
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					big_test_node:post_chunk(main, big_serialize:jsonify(Proof)))
		end,
		RecordsWithProofs
	),
	Proofs = [Proof || {_, _, _, Proof} <- RecordsWithProofs],
	big_test_data_sync:wait_until_syncs_chunks(Proofs),
	DiskPoolThreshold = big_node:get_partition_upper_bound(big_node:get_block_index()),
	big_test_data_sync:wait_until_syncs_chunks(peer1, Proofs, DiskPoolThreshold),
	lists:foreach(
		fun({B, #tx{ id = TXID }, Chunks, {_, Proof}}) ->
			TXSize = byte_size(binary:list_to_bin(Chunks)),
			TXOffset = big_merkle:extract_note(big_util:decode(maps:get(tx_path, Proof))),
			AbsoluteTXOffset = B#block.weave_size - B#block.block_size + TXOffset,
			ExpectedOffsetInfo = big_serialize:jsonify(#{
					offset => integer_to_binary(AbsoluteTXOffset),
					size => integer_to_binary(TXSize) }),
			true = big_util:do_until(
				fun() ->
					case big_test_data_sync:get_tx_offset(peer1, TXID) of
						{ok, {{<<"200">>, _}, _, ExpectedOffsetInfo, _, _}} ->
							true;
						_ ->
							false
					end
				end,
				100,
				120 * 1000
			),
			ExpectedData = big_util:encode(binary:list_to_bin(Chunks)),
			big_test_node:assert_get_tx_data(main, TXID, ExpectedData),
			case AbsoluteTXOffset > DiskPoolThreshold of
				true ->
					ok;
				false ->
					big_test_node:assert_get_tx_data(peer1, TXID, ExpectedData)
			end
		end,
		RecordsWithProofs
	).

syncs_after_joining_test_() ->
	big_test_node:test_with_mocked_functions([{big_fork, height_2_5, fun() -> 0 end}],
		fun test_syncs_after_joining/0, 240).

test_syncs_after_joining() ->
	test_syncs_after_joining(original_split).

test_syncs_after_joining(Split) ->
	Wallet = big_test_data_sync:setup_nodes(),
	{TX1, Chunks1} = big_test_data_sync:tx(Wallet, {Split, 1}, v2, ?BIG(1)),
	B1 = big_test_node:post_and_mine(#{ miner => main, await_on => peer1 }, [TX1]),
	Proofs1 = big_test_data_sync:post_proofs(main, B1, TX1, Chunks1),
	UpperBound = big_node:get_partition_upper_bound(big_node:get_block_index()),
	big_test_data_sync:wait_until_syncs_chunks(peer1, Proofs1, UpperBound),
	big_test_data_sync:wait_until_syncs_chunks(Proofs1),
	big_test_node:disconnect_from(peer1),
	{MainTX2, MainChunks2} = big_test_data_sync:tx(Wallet, {Split, 3}, v2, ?BIG(1)),
	MainB2 = big_test_node:post_and_mine(#{ miner => main, await_on => main }, [MainTX2]),
	MainProofs2 = big_test_data_sync:post_proofs(main, MainB2, MainTX2, MainChunks2),
	{MainTX3, MainChunks3} = big_test_data_sync:tx(Wallet, {Split, 2}, v2, ?BIG(1)),
	MainB3 = big_test_node:post_and_mine(#{ miner => main, await_on => main }, [MainTX3]),
	MainProofs3 = big_test_data_sync:post_proofs(main, MainB3, MainTX3, MainChunks3),
	{PeerTX2, PeerChunks2} = big_test_data_sync:tx(Wallet, {Split, 2}, v2, ?BIG(1)),
	PeerB2 = big_test_node:post_and_mine( #{ miner => peer1, await_on => peer1 }, [PeerTX2] ),
	PeerProofs2 = big_test_data_sync:post_proofs(peer1, PeerB2, PeerTX2, PeerChunks2),
	big_test_data_sync:wait_until_syncs_chunks(peer1, PeerProofs2, infinity),
	_Peer2 = big_test_node:rejoin_on(#{ node => peer1, join_on => main }),
	assert_wait_until_height(peer1, 3),
	big_test_node:connect_to_peer(peer1),
	UpperBound2 = big_node:get_partition_upper_bound(big_node:get_block_index()),
	big_test_data_sync:wait_until_syncs_chunks(peer1, MainProofs2, UpperBound2),
	big_test_data_sync:wait_until_syncs_chunks(peer1, MainProofs3, UpperBound2),
	big_test_data_sync:wait_until_syncs_chunks(peer1, Proofs1, infinity).

mines_off_only_last_chunks_test_() ->
	test_with_mocked_functions([{big_fork, height_2_6, fun() -> 0 end}, mock_reset_frequency()],
			fun test_mines_off_only_last_chunks/0).

mock_reset_frequency() ->
	{big_nonce_limiter, get_reset_frequency, fun() -> 5 end}.

test_mines_off_only_last_chunks() ->
	Wallet = big_test_data_sync:setup_nodes(),
	%% Submit only the last chunks (smaller than 256 KiB) of transactions.
	%% Assert the nodes construct correct proofs of access from them.
	lists:foreach(
		fun(Height) ->
			RandomID = crypto:strong_rand_bytes(32),
			Chunk = crypto:strong_rand_bytes(1023),
			ChunkID = big_tx:generate_chunk_id(Chunk),
			DataSize = ?DATA_CHUNK_SIZE + 1023,
			{DataRoot, DataTree} = big_merkle:generate_tree([{RandomID, ?DATA_CHUNK_SIZE},
					{ChunkID, DataSize}]),
			TX = big_test_node:sign_tx(Wallet, #{ last_tx => big_test_node:get_tx_anchor(main), data_size => DataSize,
					data_root => DataRoot }),
			big_test_node:post_and_mine(#{ miner => main, await_on => peer1 }, [TX]),
			Offset = ?DATA_CHUNK_SIZE + 1,
				DataPath = big_merkle:generate_path(DataRoot, Offset, DataTree),
			Proof = #{ data_root => big_util:encode(DataRoot),
					data_path => big_util:encode(DataPath), chunk => big_util:encode(Chunk),
					offset => integer_to_binary(Offset),
					data_size => integer_to_binary(DataSize) },
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					big_test_node:post_chunk(main, big_serialize:jsonify(Proof))),
			case Height - ?SEARCH_SPACE_UPPER_BOUND_DEPTH of
				-1 ->
					%% Make sure we waited enough to have the next block use
					%% the new entropy reset source.
					[{_, Info}] = ets:lookup(node_state, nonce_limiter_info),
					PrevStepNumber = Info#nonce_limiter_info.global_step_number,
					true = big_util:do_until(
						fun() ->
							big_nonce_limiter:get_current_step_number()
									> PrevStepNumber + big_nonce_limiter:get_reset_frequency()
						end,
						100,
						60000
					);
				0 ->
					%% Wait until the new chunks fall below the new upper bound and
					%% remove the original big chunks. The protocol will increase the upper
					%% bound based on the nonce limiter entropy reset, but big_data_sync waits
					%% for ?SEARCH_SPACE_UPPER_BOUND_DEPTH confirmations before packing the
					%% chunks.
					{ok, Config} = application:get_env(bigfile, config),
					lists:foreach(
						fun(O) ->
							[big_chunk_storage:delete(O, big_storage_module:id(Module))
									|| Module <- Config#config.storage_modules]
						end,
						lists:seq(?DATA_CHUNK_SIZE, ?STRICT_DATA_SPLIT_THRESHOLD,
								?DATA_CHUNK_SIZE)
					);
				_ ->
					ok
			end
		end,
		lists:seq(1, 6)
	).

mines_off_only_second_last_chunks_test_() ->
	test_with_mocked_functions([{big_fork, height_2_6, fun() -> 0 end}, mock_reset_frequency()],
			fun test_mines_off_only_second_last_chunks/0).

test_mines_off_only_second_last_chunks() ->
	Wallet = big_test_data_sync:setup_nodes(),
	%% Submit only the second last chunks (smaller than 256 KiB) of transactions.
	%% Assert the nodes construct correct proofs of access from them.
	lists:foreach(
		fun(Height) ->
			RandomID = crypto:strong_rand_bytes(32),
			Chunk = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE div 2),
			ChunkID = big_tx:generate_chunk_id(Chunk),
			DataSize = (?DATA_CHUNK_SIZE) div 2 + (?DATA_CHUNK_SIZE) div 2 + 3,
			{DataRoot, DataTree} = big_merkle:generate_tree([{ChunkID, ?DATA_CHUNK_SIZE div 2},
					{RandomID, DataSize}]),
			TX = big_test_node:sign_tx(Wallet, #{ last_tx => big_test_node:get_tx_anchor(main), data_size => DataSize,
					data_root => DataRoot }),
			big_test_node:post_and_mine(#{ miner => main, await_on => peer1 }, [TX]),
			Offset = 0,
			DataPath = big_merkle:generate_path(DataRoot, Offset, DataTree),
			Proof = #{ data_root => big_util:encode(DataRoot),
					data_path => big_util:encode(DataPath), chunk => big_util:encode(Chunk),
					offset => integer_to_binary(Offset),
					data_size => integer_to_binary(DataSize) },
			?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
					big_test_node:post_chunk(main, big_serialize:jsonify(Proof))),
			case Height - ?SEARCH_SPACE_UPPER_BOUND_DEPTH >= 0 of
				true ->
					%% Wait until the new chunks fall below the new upper bound and
					%% remove the original big chunks. The protocol will increase the upper
					%% bound based on the nonce limiter entropy reset, but big_data_sync waits
					%% for ?SEARCH_SPACE_UPPER_BOUND_DEPTH confirmations before packing the
					%% chunks.
					{ok, Config} = application:get_env(bigfile, config),
					lists:foreach(
						fun(O) ->
							[big_chunk_storage:delete(O, big_storage_module:id(Module))
									|| Module <- Config#config.storage_modules]
						end,
						lists:seq(?DATA_CHUNK_SIZE, ?STRICT_DATA_SPLIT_THRESHOLD,
								?DATA_CHUNK_SIZE)
					);
				_ ->
					ok
			end
		end,
		lists:seq(1, 6)
	).

disk_pool_rotation_test_() ->
	{timeout, 120, fun test_disk_pool_rotation/0}.

test_disk_pool_rotation() ->
	Addr = big_wallet:to_address(big_wallet:new_keyfile()),
	%% Will store the three genesis chunks.
	%% The third one falls inside the "overlap" (see big_storage_module.erl)
	StorageModules = [{2 * ?DATA_CHUNK_SIZE, 0,
			big_test_node:get_default_storage_module_packing(Addr, 0)}],
	Wallet = big_test_data_sync:setup_nodes(
			#{ addr => Addr, storage_modules => StorageModules }),
	Chunks = [crypto:strong_rand_bytes(?DATA_CHUNK_SIZE)],
	{DataRoot, DataTree} = big_merkle:generate_tree(
		big_tx:sized_chunks_to_sized_chunk_ids(
			big_tx:chunks_to_size_tagged_chunks(Chunks)
		)
	),
	{TX, Chunks} = big_test_data_sync:tx(Wallet, {fixed_data, DataRoot, Chunks}),
	big_test_node:assert_post_tx_to_peer(main, TX),
	Offset = ?DATA_CHUNK_SIZE,
	DataSize = ?DATA_CHUNK_SIZE,
	DataPath = big_merkle:generate_path(DataRoot, Offset, DataTree),
	Proof = #{ data_root => big_util:encode(DataRoot),
			data_path => big_util:encode(DataPath),
			chunk => big_util:encode(hd(Chunks)),
			offset => integer_to_binary(Offset),
			data_size => integer_to_binary(DataSize) },
	?assertMatch({ok, {{<<"200">>, _}, _, _, _, _}},
			big_test_node:post_chunk(main, big_serialize:jsonify(Proof))),
	big_test_node:mine(main),
	assert_wait_until_height(main, 1),
	timer:sleep(2000),
	Options = #{ format => etf, random_subset => false },
	{ok, Binary1} = big_global_sync_record:get_serialized_sync_record(Options),
	{ok, Global1} = big_intervals:safe_from_etf(Binary1),
	%% 3 genesis chunks plus the two we upload here.
	?assertEqual([{1048576, 0}], big_intervals:to_list(Global1)),
	big_test_node:mine(main),
	assert_wait_until_height(main, 2),
	{ok, Binary2} = big_global_sync_record:get_serialized_sync_record(Options),
	{ok, Global2} = big_intervals:safe_from_etf(Binary2),
	?assertEqual([{1048576, 0}], big_intervals:to_list(Global2)),
	big_test_node:mine(main),
	assert_wait_until_height(main, 3),
	big_test_node:mine(main),
	assert_wait_until_height(main, 4),
	%% The new chunk has been confirmed but there is not storage module to take it.
	?assertEqual(3, ?SEARCH_SPACE_UPPER_BOUND_DEPTH),
	true = big_util:do_until(
		fun() ->
			{ok, Binary3} = big_global_sync_record:get_serialized_sync_record(Options),
			{ok, Global3} = big_intervals:safe_from_etf(Binary3),
			[{786432, 0}] == big_intervals:to_list(Global3)
		end,
		200,
		5000
	).

enqueue_intervals_test() ->
	test_enqueue_intervals([], 2, [], [], [], "Empty Intervals"),
	Peer1 = {1, 2, 3, 4, 1984},
	Peer2 = {101, 102, 103, 104, 1984},
	Peer3 = {201, 202, 203, 204, 1984},

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
					{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
					{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
				])}
		],
		5,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer1},
			{7*?DATA_CHUNK_SIZE, 8*?DATA_CHUNK_SIZE, Peer1},
			{8*?DATA_CHUNK_SIZE, 9*?DATA_CHUNK_SIZE, Peer1}
		],
		"Single peer, full intervals, all chunks. Non-overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
					{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
					{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
				])}
		],
		2,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1}
		],
		"Single peer, full intervals, 2 chunks. Non-overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer2, big_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
			])},
			{Peer3, big_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		2,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{8*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{5*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer2},
			{7*?DATA_CHUNK_SIZE, 8*?DATA_CHUNK_SIZE, Peer3}
		],
		"Multiple peers, overlapping, full intervals, 2 chunks. Non-overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer2, big_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
			])},
			{Peer3, big_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		3,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{8*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{5*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer1},
			{7*?DATA_CHUNK_SIZE, 8*?DATA_CHUNK_SIZE, Peer3}
		],
		"Multiple peers, overlapping, full intervals, 3 chunks. Non-overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
					{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
					{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])}
		],
		5,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}, {9*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{7*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer1}
		],
		"Single peer, full intervals, all chunks. Overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer2, big_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
			])},
			{Peer3, big_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		2,
		[{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE}, {9*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{7*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, 4*?DATA_CHUNK_SIZE, Peer1},
			{5*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE, Peer2}
		],
		"Multiple peers, overlapping, full intervals, 2 chunks. Overlapping QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
				{trunc(3.25*?DATA_CHUNK_SIZE), 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, trunc(5.75*?DATA_CHUNK_SIZE)}
			])}
		],
		2,
		[
			{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE},
			{trunc(8.5*?DATA_CHUNK_SIZE), trunc(6.5*?DATA_CHUNK_SIZE)}
		],
		[
			{trunc(3.25*?DATA_CHUNK_SIZE), 2*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, trunc(3.25*?DATA_CHUNK_SIZE), Peer1}
		],
		"Single peer, partial intervals, 2 chunks. Overlapping partial QIntervals."),

	test_enqueue_intervals(
		[
			{Peer1, big_intervals:from_list([
				{trunc(3.25*?DATA_CHUNK_SIZE), 2*?DATA_CHUNK_SIZE},
				{9*?DATA_CHUNK_SIZE, trunc(5.75*?DATA_CHUNK_SIZE)}
			])},
			{Peer2, big_intervals:from_list([
				{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
				{7*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
			])},
			{Peer3, big_intervals:from_list([
				{8*?DATA_CHUNK_SIZE, 7*?DATA_CHUNK_SIZE}
			])}
		],
		2,
		[
			{20*?DATA_CHUNK_SIZE, 10*?DATA_CHUNK_SIZE},
			{trunc(8.5*?DATA_CHUNK_SIZE), trunc(6.5*?DATA_CHUNK_SIZE)}
		],
		[
			{4*?DATA_CHUNK_SIZE, 2*?DATA_CHUNK_SIZE},
			{8*?DATA_CHUNK_SIZE, 6*?DATA_CHUNK_SIZE}
		],
		[
			{2*?DATA_CHUNK_SIZE, 3*?DATA_CHUNK_SIZE, Peer1},
			{3*?DATA_CHUNK_SIZE, trunc(3.25*?DATA_CHUNK_SIZE), Peer1},
			{trunc(3.25*?DATA_CHUNK_SIZE), 4*?DATA_CHUNK_SIZE, Peer2},
			{6*?DATA_CHUNK_SIZE, trunc(6.5*?DATA_CHUNK_SIZE), Peer2}
		],
		"Multiple peers, overlapping, full intervals, 2 chunks. Overlapping QIntervals.").

test_enqueue_intervals(Intervals, ChunksPerPeer, QIntervalsRanges, ExpectedQIntervalRanges, ExpectedChunks, Label) ->
	QIntervals = big_intervals:from_list(QIntervalsRanges),
	Q = gb_sets:new(),
	{QResult, QIntervalsResult} = big_data_sync:enqueue_intervals(Intervals, ChunksPerPeer, {Q, QIntervals}),
	ExpectedQIntervals = lists:foldl(fun({End, Start}, Acc) ->
			big_intervals:add(Acc, End, Start)
		end, QIntervals, ExpectedQIntervalRanges),
	?assertEqual(big_intervals:to_list(ExpectedQIntervals), big_intervals:to_list(QIntervalsResult), Label),
	?assertEqual(ExpectedChunks, gb_sets:to_list(QResult), Label).

