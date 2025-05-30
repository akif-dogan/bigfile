-module(big_repack_mine_tests).

-include_lib("bigfile/include/big_config.hrl").
-include_lib("bigfile/include/big_consensus.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(REPACK_MINE_TEST_TIMEOUT, 600).

%% --------------------------------------------------------------------------------------------
%% Test Registration
%% --------------------------------------------------------------------------------------------
repack_mine_test_() ->
	Timeout = ?REPACK_MINE_TEST_TIMEOUT,
	[
		{timeout, Timeout, {with, {replica_2_9, replica_2_9}, [fun test_repacking_blocked/1]}},
		{timeout, Timeout, {with, {replica_2_9, spora_2_6}, [fun test_repacking_blocked/1]}},
		{timeout, Timeout, {with, {replica_2_9, composite_1}, [fun test_repacking_blocked/1]}},
		{timeout, Timeout, {with, {replica_2_9, unpacked}, [fun test_repacking_blocked/1]}},
		{timeout, Timeout, {with, {unpacked, replica_2_9}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {unpacked, spora_2_6}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {unpacked, composite_1}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {spora_2_6, replica_2_9}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {spora_2_6, spora_2_6}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {spora_2_6, composite_1}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {spora_2_6, unpacked}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {composite_1, replica_2_9}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {composite_1, spora_2_6}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {composite_1, composite_1}, [fun test_repack_mine/1]}},
		{timeout, Timeout, {with, {composite_1, unpacked}, [fun test_repack_mine/1]}}
	].

%% --------------------------------------------------------------------------------------------
%% test_repack_mine
%% --------------------------------------------------------------------------------------------
test_repack_mine({FromPackingType, ToPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [FromPackingType, ToPackingType]),
	?LOG_INFO([{event, test_repack_mine}, {module, ?MODULE},
		{from_packing_type, FromPackingType}, {to_packing_type, ToPackingType}]),
	ValidatorNode = peer1,
	RepackerNode = peer2,
	big_test_node:stop(ValidatorNode),
	big_test_node:stop(RepackerNode),
	{Blocks, _AddrA, Chunks} = big_e2e:start_source_node(
		RepackerNode, FromPackingType, wallet_a),

	[B0 | _] = Blocks,
	start_validator_node(ValidatorNode, RepackerNode, B0),

	{WalletB, StorageModules} = big_e2e:source_node_storage_modules(
		RepackerNode, ToPackingType, wallet_b),
	AddrB = case WalletB of
		undefined -> undefined;
		_ -> big_wallet:to_address(WalletB)
	end,
	ToPacking = big_e2e:packing_type_to_packing(ToPackingType, AddrB),
	{ok, Config} = big_test_node:get_config(RepackerNode),
	big_test_node:restart_with_config(RepackerNode, Config#config{
		storage_modules = Config#config.storage_modules ++ StorageModules,
		mining_addr = AddrB
	}),

	big_e2e:assert_syncs_range(RepackerNode, 0, 4*?PARTITION_SIZE),
	big_e2e:assert_partition_size(RepackerNode, 0, ToPacking),
	big_e2e:assert_partition_size(RepackerNode, 1, ToPacking),
	big_e2e:assert_partition_size(
		RepackerNode, 2, ToPacking, floor(0.5*?PARTITION_SIZE)),
	%% Don't assert chunks here. Since we have two storage modules defined we won't know
	%% which packing format will be found - which complicates the assertion. We'll rely
	%% on the assert_chunks later (after we restart with only a single set of storage modules)
	%% to verify that the chunks are present.
	%% big_e2e:assert_chunks(RepackerNode, ToPacking, Chunks),
	big_e2e:assert_empty_partition(RepackerNode, 3, ToPacking),

	big_test_node:restart_with_config(RepackerNode, Config#config{
		storage_modules = StorageModules,
		mining_addr = AddrB
	}),
	big_e2e:assert_syncs_range(RepackerNode, ToPacking, 0, 4*?PARTITION_SIZE),
	big_e2e:assert_partition_size(RepackerNode, 0, ToPacking),
	big_e2e:assert_partition_size(RepackerNode, 1, ToPacking),
	big_e2e:assert_partition_size(
		RepackerNode, 2, ToPacking, floor(0.5*?PARTITION_SIZE)),
	big_e2e:assert_chunks(RepackerNode, ToPacking, Chunks),
	big_e2e:assert_empty_partition(RepackerNode, 3, ToPacking),

	case ToPackingType of
		unpacked ->
			ok;
		_ ->
			big_e2e:assert_mine_and_validate(RepackerNode, ValidatorNode, ToPacking),

			%% Now that we mined a block, the rest of partition 2 is below the disk pool
			%% threshold
			big_e2e:assert_syncs_range(RepackerNode, ToPacking, 0, 4*?PARTITION_SIZE),
			big_e2e:assert_partition_size(RepackerNode, 0, ToPacking),
			big_e2e:assert_partition_size(RepackerNode, 1, ToPacking),			
			big_e2e:assert_partition_size(RepackerNode, 2, ToPacking, ?PARTITION_SIZE),
			%% All of partition 3 is still above the disk pool threshold
			big_e2e:assert_empty_partition(RepackerNode, 3, ToPacking)
	end.

test_repacking_blocked({FromPackingType, ToPackingType}) ->
	big_e2e:delayed_print(<<" ~p -> ~p ">>, [FromPackingType, ToPackingType]),
	?LOG_INFO([{event, test_repacking_blocked}, {module, ?MODULE},
		{from_packing_type, FromPackingType}, {to_packing_type, ToPackingType}]),
	ValidatorNode = peer1,
	RepackerNode = peer2,
	big_test_node:stop(ValidatorNode),
	big_test_node:stop(RepackerNode),
	{Blocks, _AddrA, Chunks} = big_e2e:start_source_node(
		RepackerNode, FromPackingType, wallet_a),

	[B0 | _] = Blocks,
	start_validator_node(ValidatorNode, RepackerNode, B0),

	{WalletB, StorageModules} = big_e2e:source_node_storage_modules(
		RepackerNode, ToPackingType, wallet_b),
	AddrB = case WalletB of
		undefined -> undefined;
		_ -> big_wallet:to_address(WalletB)
	end,
	ToPacking = big_e2e:packing_type_to_packing(ToPackingType, AddrB),
	{ok, Config} = big_test_node:get_config(RepackerNode),
	big_test_node:restart_with_config(RepackerNode, Config#config{
		storage_modules = Config#config.storage_modules ++ StorageModules,
		mining_addr = AddrB
	}),

	big_e2e:assert_empty_partition(RepackerNode, 1, ToPacking),
	big_e2e:assert_no_chunks(RepackerNode, Chunks),

	big_test_node:restart_with_config(RepackerNode, Config#config{
		storage_modules = StorageModules,
		mining_addr = AddrB
	}),

	big_e2e:assert_empty_partition(RepackerNode, 1, ToPacking),
	big_e2e:assert_no_chunks(RepackerNode, Chunks).

start_validator_node(ValidatorNode, RepackerNode, B0) ->
	{ok, Config} = big_test_node:get_config(ValidatorNode),
	?assertEqual(big_test_node:peer_name(ValidatorNode),
		big_test_node:start_other_node(ValidatorNode, B0, Config#config{
			peers = [big_test_node:peer_ip(RepackerNode)],
			start_from_latest_state = true,
			auto_join = true,
			storage_modules = []
		}, true)
	),
	ok.
	