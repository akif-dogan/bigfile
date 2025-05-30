-module(big_sync_pack_mine_tests).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_config.hrl").
-include_lib("bigfile/include/big_consensus.hrl").
-include_lib("eunit/include/eunit.hrl").

%% --------------------------------------------------------------------------------------------
%% Fixtures
%% --------------------------------------------------------------------------------------------
setup_source_node(PackingType) ->
	SourceNode = peer1,
	SinkNode = peer2,
	big_test_node:stop(SinkNode),
	big_test_node:stop(SourceNode),
	{Blocks, _SourceAddr, Chunks} = big_e2e:start_source_node(SourceNode, PackingType, wallet_a),

	{Blocks, Chunks, PackingType}.

instantiator(GenesisData, SinkPackingType, TestFun) ->
	{timeout, 600, {with, {GenesisData, SinkPackingType}, [TestFun]}}.
	
%% --------------------------------------------------------------------------------------------
%% Test Registration
%% --------------------------------------------------------------------------------------------

replica_2_9_block_sync_test_() ->
	{setup, fun () -> setup_source_node(replica_2_9) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_syncing_blocked/1),
					instantiator(GenesisData, spora_2_6, fun test_syncing_blocked/1),
					instantiator(GenesisData, composite_1, fun test_syncing_blocked/1),
					instantiator(GenesisData, unpacked, fun test_syncing_blocked/1)
				]
		end}.

spora_2_6_sync_pack_mine_test_() ->
	{setup, fun () -> setup_source_node(spora_2_6) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_sync_pack_mine/1),
					instantiator(GenesisData, spora_2_6, fun test_sync_pack_mine/1),
					instantiator(GenesisData, composite_1, fun test_sync_pack_mine/1),
					instantiator(GenesisData, unpacked, fun test_sync_pack_mine/1)
				]
		end}.

composite_1_sync_pack_mine_test_() ->
	{setup, fun () -> setup_source_node(composite_1) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_sync_pack_mine/1),
					instantiator(GenesisData, spora_2_6, fun test_sync_pack_mine/1),
					instantiator(GenesisData, composite_1, fun test_sync_pack_mine/1),
					instantiator(GenesisData, unpacked, fun test_sync_pack_mine/1)
				]
		end}.

unpacked_sync_pack_mine_test_() ->
	{setup, fun () -> setup_source_node(unpacked) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, fun test_sync_pack_mine/1),
					instantiator(GenesisData, spora_2_6, fun test_sync_pack_mine/1),
					instantiator(GenesisData, composite_1, fun test_sync_pack_mine/1),
					instantiator(GenesisData, unpacked, fun test_sync_pack_mine/1)
				]
		end}.

% Note: we should limit the number of tests run per setup_source_node to 5, if it gets
% too long then the source node may hit a difficulty adjustment, which can impact the
% results.
unpacked_edge_case_test_() ->
	{setup, fun () -> setup_source_node(unpacked) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, {replica_2_9, unpacked}, 
						fun test_unpacked_and_packed_sync_pack_mine/1),
					instantiator(GenesisData, {unpacked, replica_2_9}, 
						fun test_unpacked_and_packed_sync_pack_mine/1),
					instantiator(GenesisData, replica_2_9, 
						fun test_entropy_first_sync_pack_mine/1),
					instantiator(GenesisData, replica_2_9, 
						fun test_entropy_last_sync_pack_mine/1)
				]
		end}.

spora_2_6_edge_case_test_() ->
	{setup, fun () -> setup_source_node(spora_2_6) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, {replica_2_9, unpacked}, 
						fun test_unpacked_and_packed_sync_pack_mine/1),
					instantiator(GenesisData, {unpacked, replica_2_9}, 
						fun test_unpacked_and_packed_sync_pack_mine/1),
					instantiator(GenesisData, replica_2_9, 
						fun test_entropy_first_sync_pack_mine/1),
					instantiator(GenesisData, replica_2_9, 
						fun test_entropy_last_sync_pack_mine/1)
				]
		end}.

unpacked_small_module_test_() ->
	{setup, fun () -> setup_source_node(unpacked) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, 
						fun test_small_module_aligned_sync_pack_mine/1),
					instantiator(GenesisData, replica_2_9, 
						fun test_small_module_unaligned_sync_pack_mine/1)
				]
	end}.
	
spora_2_6_small_module_test_() ->
	{setup, fun () -> setup_source_node(spora_2_6) end, 
		fun (GenesisData) ->
				[
					instantiator(GenesisData, replica_2_9, 
						fun test_small_module_aligned_sync_pack_mine/1),
					instantiator(GenesisData, replica_2_9, 
						fun test_small_module_unaligned_sync_pack_mine/1)
				]
		end}.

disk_pool_threshold_test_() ->
	[
		instantiator(unpacked, replica_2_9, fun test_disk_pool_threshold/1),
		instantiator(unpacked, spora_2_6, fun test_disk_pool_threshold/1),
		instantiator(spora_2_6, replica_2_9, fun test_disk_pool_threshold/1),
		instantiator(spora_2_6, spora_2_6, fun test_disk_pool_threshold/1),
		instantiator(spora_2_6, unpacked, fun test_disk_pool_threshold/1)
	].

%% --------------------------------------------------------------------------------------------
%% test_sync_pack_mine
%% --------------------------------------------------------------------------------------------
test_sync_pack_mine({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	?LOG_INFO([{event, test_sync_pack_mine}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, SinkPackingType}]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	SinkPacking = start_sink_node(SinkNode, SourceNode, B0, SinkPackingType),

	RangeStart = ?PARTITION_SIZE,
	RangeEnd = 2*?PARTITION_SIZE + big_storage_module:get_overlap(SinkPacking),
	RangeSize = RangeEnd - RangeStart,

	%% Partition 1 and half of partition 2 are below the disk pool threshold
	big_e2e:assert_syncs_range(SinkNode,	SinkPacking, RangeStart, RangeEnd),
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking, RangeSize),
	big_e2e:assert_chunks(SinkNode, SinkPacking, Chunks),

	case SinkPackingType of
		unpacked ->
			ok;
		_ ->
			big_e2e:assert_mine_and_validate(SinkNode, SourceNode, SinkPacking),
			ok
	end.

test_syncing_blocked({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	?LOG_INFO([{event, test_syncing_blocked}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, SinkPackingType}]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	start_sink_node(SinkNode, SourceNode, B0, SinkPackingType),
	big_e2e:assert_does_not_sync_range(SinkNode, ?PARTITION_SIZE, 2*?PARTITION_SIZE),
	big_e2e:assert_no_chunks(SinkNode, Chunks).

test_unpacked_and_packed_sync_pack_mine(
		{{Blocks, _Chunks, SourcePackingType}, {PackingType1, PackingType2}}) ->
	big_e2e:delayed_print(<<" ~p -> {~p, ~p} ">>, [SourcePackingType, PackingType1, PackingType2]),
	?LOG_INFO([{event, test_unpacked_and_packed_sync_pack_mine}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, {PackingType1, PackingType2}}]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	{SinkPacking1, SinkPacking2} = start_sink_node(
		SinkNode, SourceNode, B0, PackingType1, PackingType2),

	RangeStart1 = ?PARTITION_SIZE,
	RangeEnd1 = 2*?PARTITION_SIZE + big_storage_module:get_overlap(SinkPacking1),
	RangeSize1 = RangeEnd1 - RangeStart1,

	RangeStart2 = ?PARTITION_SIZE,
	RangeEnd2 = 2*?PARTITION_SIZE + big_storage_module:get_overlap(SinkPacking2),
	RangeSize2 = RangeEnd2 - RangeStart2,

	%% Data exists as both packed and unmpacked, so will exist in the global sync record
	%% even though replica_2_9 data is filtered out.
	big_e2e:assert_syncs_range(SinkNode, RangeStart1, RangeEnd1),
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking1, RangeSize1),
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking2, RangeSize2),
	%% XXX: we should be able to assert the chunks here, but since we have two
	%% storage modules configured and are querying the replica_2_9 chunk, GET /chunk gets
	%% confused and tries to load the unpacked chunk, which then fails within the middleware
	%% handler and 404s. To fix we'd need to update GET /chunk to query all matching
	%% storage modules and then find the best one to return. But since this is a rare edge
	%% case, we'll just disable the assertion for now.
	%% big_e2e:assert_chunks(SinkNode, SinkPacking, Chunks),
	
	MinablePacking = case PackingType1 of
		unpacked -> SinkPacking2;
		_ -> SinkPacking1
	end,
	big_e2e:assert_mine_and_validate(SinkNode, SourceNode, MinablePacking),
	ok.
	

test_entropy_first_sync_pack_mine({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	?LOG_INFO([{event, test_entropy_first_sync_pack_mine}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, SinkPackingType}]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	Wallet = big_test_node:remote_call(SinkNode, big_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = big_wallet:to_address(Wallet),
	SinkPacking = big_e2e:packing_type_to_packing(SinkPackingType, SinkAddr),
	{ok, Config} = big_test_node:get_config(SinkNode),
	
	Module = {?PARTITION_SIZE, 1, SinkPacking},
	StoreID = big_storage_module:id(Module),
	StorageModules = [ Module ],


	%% 1. Run node with no sync jobs so that it only prepares entropy
	Config2 = Config#config{
		peers = [big_test_node:peer_ip(SourceNode)],
		start_from_latest_state = true,
		storage_modules = StorageModules,
		auto_join = true,
		mining_addr = SinkAddr,
		sync_jobs = 0
	},
	?assertEqual(big_test_node:peer_name(SinkNode),
		big_test_node:start_other_node(SinkNode, B0, Config2, true)
	),

	RangeStart = ?PARTITION_SIZE,
	RangeEnd = 2*?PARTITION_SIZE + big_storage_module:get_overlap(SinkPacking),
	RangeSize = RangeEnd - RangeStart,

	big_e2e:assert_has_entropy(SinkNode, RangeStart, RangeEnd, StoreID),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked_padded),

	%% Delete two chunks of entropy from storage to test that the node will heal itself.
	%% 1. Delete the chunk from disk as well as all sync records.
	%% 2. Delete the chunk only from disk, but keep it in the sync records.
	DeleteOffset1 = RangeStart + ?DATA_CHUNK_SIZE,
	big_test_node:remote_call(SinkNode, big_chunk_storage, delete,
		[DeleteOffset1, StoreID]),
	DeleteOffset2 = DeleteOffset1 + ?DATA_CHUNK_SIZE,
	big_test_node:remote_call(SinkNode, big_chunk_storage, delete_chunk,
		[DeleteOffset2, StoreID]),

	%% 2. Run node with sync jobs so that it syncs and packs data
	big_test_node:restart_with_config(SinkNode, Config2#config{
		sync_jobs = 100
	}),

	big_e2e:assert_syncs_range(SinkNode, SinkPacking, RangeStart, RangeEnd),
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking, RangeSize),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked_padded),
	big_e2e:assert_chunks(SinkNode, SinkPacking, Chunks),

	%% 3. Make sure the data is minable
	big_e2e:assert_mine_and_validate(SinkNode, SourceNode, SinkPacking),
	ok.

test_entropy_last_sync_pack_mine({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	?LOG_INFO([{event, test_entropy_last_sync_pack_mine}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, SinkPackingType}]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	Wallet = big_test_node:remote_call(SinkNode, big_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = big_wallet:to_address(Wallet),
	SinkPacking = big_e2e:packing_type_to_packing(SinkPackingType, SinkAddr),
	{ok, Config} = big_test_node:get_config(SinkNode),
	
	Module = {?PARTITION_SIZE, 1, SinkPacking},
	StoreID = big_storage_module:id(Module),
	StorageModules = [ Module ],

	%% 1. Run node with no replica_2_9 workers so that it only syncs chunks
	Config2 = Config#config{
		peers = [big_test_node:peer_ip(SourceNode)],
		start_from_latest_state = true,
		storage_modules = StorageModules,
		auto_join = true,
		mining_addr = SinkAddr,
		replica_2_9_workers = 0
	},
	?assertEqual(big_test_node:peer_name(SinkNode),
		big_test_node:start_other_node(SinkNode, B0, Config2, true)
	),

	RangeStart = ?PARTITION_SIZE,
	RangeEnd = 2*?PARTITION_SIZE + big_storage_module:get_overlap(SinkPacking),
	RangeSize = RangeEnd - RangeStart,

	big_e2e:assert_syncs_range(SinkNode, SinkPacking, RangeStart, RangeEnd),
	big_e2e:assert_partition_size(SinkNode, 1, unpacked_padded, RangeSize),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked),

	%% 2. Run node with sync jobs so that it syncs and packs data
	big_test_node:restart_with_config(SinkNode, Config2#config{
		replica_2_9_workers = 8
	}),

	big_e2e:assert_has_entropy(SinkNode, RangeStart, RangeEnd, StoreID),
	big_e2e:assert_syncs_range(SinkNode, SinkPacking, RangeStart, RangeEnd),
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking, RangeSize),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked_padded),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked),
	big_e2e:assert_chunks(SinkNode, SinkPacking, Chunks),

	%% 3. Make sure the data is minable
	big_e2e:assert_mine_and_validate(SinkNode, SourceNode, SinkPacking),
	ok.

test_small_module_aligned_sync_pack_mine({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	?LOG_INFO([{event, test_small_module_aligned_sync_pack_mine}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, SinkPackingType}]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	Wallet = big_test_node:remote_call(SinkNode, big_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = big_wallet:to_address(Wallet),
	SinkPacking = big_e2e:packing_type_to_packing(SinkPackingType, SinkAddr),
	{ok, Config} = big_test_node:get_config(SinkNode),

	Module = {floor(0.5 * ?PARTITION_SIZE), 2, SinkPacking},
	StoreID = big_storage_module:id(Module),
	StorageModules = [ Module ],

	%% Sync the second half of partition 1
	Config2 = Config#config{
		peers = [big_test_node:peer_ip(SourceNode)],
		start_from_latest_state = true,
		storage_modules = StorageModules,
		auto_join = true,
		mining_addr = SinkAddr
	},
	?assertEqual(big_test_node:peer_name(SinkNode),
		big_test_node:start_other_node(SinkNode, B0, Config2, true)
	),

	RangeStart = floor(1 * ?PARTITION_SIZE),
	RangeEnd = floor(1.5 * ?PARTITION_SIZE) + big_storage_module:get_overlap(SinkPacking),
	RangeSize = RangeEnd - RangeStart,

	%% Make sure the expected data was synced
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking, RangeSize),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked_padded),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked),
	big_e2e:assert_chunks(SinkNode, SinkPacking, lists:sublist(Chunks, 1, 4)),
	big_e2e:assert_syncs_range(SinkNode, SinkPacking, RangeStart, RangeEnd),

	%% Make sure no extra entropy was generated
	big_e2e:assert_has_entropy(SinkNode, RangeStart, RangeEnd, StoreID),
	big_e2e:assert_no_entropy(SinkNode, RangeEnd, 2 * ?PARTITION_SIZE, StoreID),

	%% Make sure the data is minable
	big_e2e:assert_mine_and_validate(SinkNode, SourceNode, SinkPacking),
	ok.

test_small_module_unaligned_sync_pack_mine({{Blocks, Chunks, SourcePackingType}, SinkPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	?LOG_INFO([{event, test_small_module_unaligned_sync_pack_mine}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, SinkPackingType}]),
	[B0 | _] = Blocks,
	SourceNode = peer1,
	SinkNode = peer2,

	Wallet = big_test_node:remote_call(SinkNode, big_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = big_wallet:to_address(Wallet),
	SinkPacking = big_e2e:packing_type_to_packing(SinkPackingType, SinkAddr),
	{ok, Config} = big_test_node:get_config(SinkNode),

	Module = {floor(0.5 * ?PARTITION_SIZE), 3, SinkPacking},
	StoreID = big_storage_module:id(Module),
	StorageModules = [ Module ],

	%% Sync the second half of partition 1
	Config2 = Config#config{
		peers = [big_test_node:peer_ip(SourceNode)],
		start_from_latest_state = true,
		storage_modules = StorageModules,
		auto_join = true,
		mining_addr = SinkAddr
	},
	?assertEqual(big_test_node:peer_name(SinkNode),
		big_test_node:start_other_node(SinkNode, B0, Config2, true)
	),

	RangeStart = floor(1.5 * ?PARTITION_SIZE),
	RangeEnd = floor(2 * ?PARTITION_SIZE) + big_storage_module:get_overlap(SinkPacking),
	RangeSize = RangeEnd - RangeStart,

	%% Make sure the expected data was synced	
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking, RangeSize),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked_padded),
	big_e2e:assert_empty_partition(SinkNode, 1, unpacked),
	big_e2e:assert_chunks(SinkNode, SinkPacking, lists:sublist(Chunks, 5, 8)),
	%% Even though the packing type is replica_2_9, the data will still exist in the
	%% default partition as unpacked - and so will exist in the global sync record.
	big_e2e:assert_syncs_range(SinkNode, RangeStart, RangeEnd),

	%% Make sure no extra entropy was generated
	big_e2e:assert_has_entropy(SinkNode, RangeStart, RangeEnd, StoreID),
	big_e2e:assert_no_entropy(SinkNode, 0, RangeStart, StoreID),

	%% Make sure the data is minable
	big_e2e:assert_mine_and_validate(SinkNode, SourceNode, SinkPacking),
	ok.

test_disk_pool_threshold({SourcePackingType, SinkPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [SourcePackingType, SinkPackingType]),
	?LOG_INFO([{event, test_disk_pool_threshold}, {module, ?MODULE},
		{from_packing_type, SourcePackingType}, {to_packing_type, SinkPackingType}]),

	SourceNode = peer1,
	SinkNode = peer2,

	%% When the source packing type is unpacked, this setup process performs some
	%% extra disk pool checks:
	%% 1. spin up a spora_2_6 node and mine some blocks
	%% 2. some chunks are below the disk pool threshold and some above
	%% 3. spin up an unpacked node and sync from spora_2_6
	%% 4. shut down the spora_2_6 node
	%% 5. now the unpacked node should have synced all of the chunks, both above and below
	%%    the disk pool threshold
	%% 6. proceed with test and spin up the sink node and confirm it too can sink all chunks
	%%    from the unpacked source node - both above and below the disk pool threshold
	{Blocks, Chunks, SourcePackingType} = setup_source_node(SourcePackingType),
	[B0 | _] = Blocks,

	SinkPacking = start_sink_node(SinkNode, SourceNode, B0, SinkPackingType),
	%% Partition 1 and half of partition 2 are below the disk pool threshold
	big_e2e:assert_syncs_range(SinkNode, SinkPacking, ?PARTITION_SIZE, 4*?PARTITION_SIZE),
	big_e2e:assert_partition_size(SinkNode, 1, SinkPacking),
	big_e2e:assert_partition_size(SinkNode, 2, SinkPacking, floor(0.5*?PARTITION_SIZE)),
	big_e2e:assert_empty_partition(SinkNode, 3, SinkPacking),
	big_e2e:assert_does_not_sync_range(SinkNode, 0, ?PARTITION_SIZE),
	big_e2e:assert_chunks(SinkNode, SinkPacking, Chunks),

	case SinkPackingType of
		unpacked ->
			ok;
		_ ->
			big_e2e:assert_mine_and_validate(SinkNode, SourceNode, SinkPacking),

			%% Now that we mined a block, the rest of partition 2 is below the disk pool
			%% threshold
			big_e2e:assert_syncs_range(SinkNode, SinkPacking, ?PARTITION_SIZE, 4*?PARTITION_SIZE),
			big_e2e:assert_partition_size(SinkNode, 2, SinkPacking, ?PARTITION_SIZE),
			%% All of partition 3 is still above the disk pool threshold
			big_e2e:assert_empty_partition(SinkNode, 3, SinkPacking),
			big_e2e:assert_does_not_sync_range(SinkNode, 0, ?PARTITION_SIZE),
			ok
	end.

start_sink_node(Node, SourceNode, B0, PackingType) ->
	Wallet = big_test_node:remote_call(Node, big_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = big_wallet:to_address(Wallet),
	SinkPacking = big_e2e:packing_type_to_packing(PackingType, SinkAddr),
	{ok, Config} = big_test_node:get_config(Node),
	
	StorageModules = [
		{?PARTITION_SIZE, 1, SinkPacking},
		{?PARTITION_SIZE, 2, SinkPacking},
		{?PARTITION_SIZE, 3, SinkPacking},
		{?PARTITION_SIZE, 4, SinkPacking},
		{?PARTITION_SIZE, 5, SinkPacking},
		{?PARTITION_SIZE, 6, SinkPacking},
		{?PARTITION_SIZE, 10, SinkPacking}
	],
	?assertEqual(big_test_node:peer_name(Node),
		big_test_node:start_other_node(Node, B0, Config#config{
			peers = [big_test_node:peer_ip(SourceNode)],
			start_from_latest_state = true,
			storage_modules = StorageModules,
			auto_join = true,
			mining_addr = SinkAddr
		}, true)
	),

	SinkPacking.

start_sink_node(Node, SourceNode, B0, PackingType1, PackingType2) ->
	Wallet = big_test_node:remote_call(Node, big_e2e, load_wallet_fixture, [wallet_b]),
	SinkAddr = big_wallet:to_address(Wallet),
	SinkPacking1 = big_e2e:packing_type_to_packing(PackingType1, SinkAddr),
	SinkPacking2 = big_e2e:packing_type_to_packing(PackingType2, SinkAddr),
	{ok, Config} = big_test_node:get_config(Node),
	
	StorageModules = [
		{?PARTITION_SIZE, 1, SinkPacking1},
		{?PARTITION_SIZE, 1, SinkPacking2}
	],

	?assertEqual(big_test_node:peer_name(Node),
		big_test_node:start_other_node(Node, B0, Config#config{
			peers = [big_test_node:peer_ip(SourceNode)],
			start_from_latest_state = true,
			storage_modules = StorageModules,
			auto_join = true,
			mining_addr = SinkAddr
		}, true)
	),
	{SinkPacking1, SinkPacking2}.
