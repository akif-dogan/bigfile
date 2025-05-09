-module(big_node_tests).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_pricing.hrl").
-include_lib("bigfile/include/big_config.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(big_test_node, [sign_v1_tx/3, read_block_when_stored/1]).

big_node_interface_test_() ->
	{timeout, 300, fun test_big_node_interface/0}.

test_big_node_interface() ->
	[B0] = big_weave:init(),
	big_test_node:start(B0),
	?assertEqual(0, big_node:get_height()),
	?assertEqual(B0#block.indep_hash, big_node:get_current_block_hash()),
	big_test_node:mine(),
	B0H = B0#block.indep_hash,
	[{H, _, _}, {B0H, _, _}] = big_test_node:wait_until_height(main, 1),
	?assertEqual(1, big_node:get_height()),
	?assertEqual(H, big_node:get_current_block_hash()).

mining_reward_test_() ->
	{timeout, 120, fun test_mining_reward/0}.

test_mining_reward() ->
	{_Priv1, Pub1} = big_wallet:new_keyfile(),
	[B0] = big_weave:init(),
	big_test_node:start(B0, MiningAddr = big_wallet:to_address(Pub1)),
	big_test_node:mine(),
	big_test_node:wait_until_height(main, 1),
	B1 = big_node:get_current_block(),
	[{MiningAddr, _, Reward, 1}, _] = B1#block.reward_history,
	{_, TotalLocked} = lists:foldl(
		fun(Height, {PrevB, TotalLocked}) ->
			?assertEqual(0, big_node:get_balance(Pub1)),
			?assertEqual(TotalLocked, big_rewards:get_total_reward_for_address(MiningAddr, PrevB)),
			big_test_node:mine(),
			big_test_node:wait_until_height(main, Height + 1),
			B = big_node:get_current_block(),
			{B, TotalLocked + B#block.reward}
		end,
		{B1, Reward},
		lists:seq(1, ?LOCKED_REWARDS_BLOCKS)
	),
	?assertEqual(Reward, big_node:get_balance(Pub1)),

	%% Unlock one more reward.
	big_test_node:mine(),
	big_test_node:wait_until_height(main, ?LOCKED_REWARDS_BLOCKS + 2),
	FinalB = big_node:get_current_block(),
	?assertEqual(Reward + 10, big_node:get_balance(Pub1)),
	?assertEqual(
		TotalLocked - Reward - 10 + FinalB#block.reward,
		big_rewards:get_total_reward_for_address(MiningAddr, FinalB)).

% @doc Check that other nodes accept a new block and associated mining reward.
multi_node_mining_reward_test_() ->
	big_test_node:test_with_mocked_functions([{big_fork, height_2_6, fun() -> 0 end}],
		fun test_multi_node_mining_reward/0, 120).

test_multi_node_mining_reward() ->
	{_Priv1, Pub1} = big_test_node:remote_call(peer1, big_wallet, new_keyfile, []),
	[B0] = big_weave:init(),
	big_test_node:start(B0),
	big_test_node:start_peer(peer1, B0, MiningAddr = big_wallet:to_address(Pub1)),
	big_test_node:connect_to_peer(peer1),
	big_test_node:mine(peer1),
	big_test_node:wait_until_height(main, 1),
	B1 = big_node:get_current_block(),
	[{MiningAddr, _, Reward, 1}, _] = B1#block.reward_history,
	?assertEqual(0, big_node:get_balance(Pub1)),
	lists:foreach(
		fun(Height) ->
			?assertEqual(0, big_node:get_balance(Pub1)),
			big_test_node:mine(),
			big_test_node:wait_until_height(main, Height + 1)
		end,
		lists:seq(1, ?LOCKED_REWARDS_BLOCKS)
	),
	?assertEqual(Reward, big_node:get_balance(Pub1)).

%% @doc Ensure that TX replay attack mitigation works.
replay_attack_test_() ->
	{timeout, 120, fun() ->
		Key1 = {_Priv1, Pub1} = big_wallet:new(),
		{_Priv2, Pub2} = big_wallet:new(),
		[B0] = big_weave:init([{big_wallet:to_address(Pub1), ?BIG(10000), <<>>}]),
		big_test_node:start(B0),
		big_test_node:start_peer(peer1, B0),
		big_test_node:connect_to_peer(peer1),
		SignedTX = sign_v1_tx(main, Key1, #{ target => big_wallet:to_address(Pub2),
				quantity => ?BIG(1000), reward => ?BIG(1), last_tx => <<>> }),
		big_test_node:assert_post_tx_to_peer(main, SignedTX),
		big_test_node:mine(),
		big_test_node:assert_wait_until_height(peer1, 1),
		?assertEqual(?BIG(8999), big_test_node:remote_call(peer1, big_node, get_balance, [Pub1])),
		?assertEqual(?BIG(1000), big_test_node:remote_call(peer1, big_node, get_balance, [Pub2])),
		big_events:send(tx, {ready_for_mining, SignedTX}),
		big_test_node:wait_until_receives_txs([SignedTX]),
		big_test_node:mine(),
		big_test_node:assert_wait_until_height(peer1, 2),
		?assertEqual(?BIG(8999), big_test_node:remote_call(peer1, big_node, get_balance, [Pub1])),
		?assertEqual(?BIG(1000), big_test_node:remote_call(peer1, big_node, get_balance, [Pub2]))
	end}.

%% @doc Create two new wallets and a blockweave with a wallet balance.
%% Create and verify execution of a signed exchange of value tx.
wallet_transaction_test_() ->
	big_test_node:test_with_mocked_functions([{big_fork, height_2_6, fun() -> 0 end}],
		fun test_wallet_transaction/0, 120).

test_wallet_transaction() ->
	TestWalletTransaction = fun(KeyType) ->
		fun() ->
			{Priv1, Pub1} = big_wallet:new_keyfile(KeyType),
			{_Priv2, Pub2} = big_wallet:new(),
			TX = big_tx:new(big_wallet:to_address(Pub2), ?BIG(1), ?BIG(9000), <<>>),
			SignedTX = big_tx:sign(TX#tx{ format = 2 }, Priv1, Pub1),
			[B0] = big_weave:init([{big_wallet:to_address(Pub1), ?BIG(10000), <<>>}]),
			big_test_node:start(B0, big_wallet:to_address(big_wallet:new_keyfile({eddsa, ed25519}))),
			big_test_node:start_peer(peer1, B0),
			big_test_node:connect_to_peer(peer1),
			big_test_node:assert_post_tx_to_peer(main, SignedTX),
			big_test_node:mine(),
			big_test_node:wait_until_height(main, 1),
			big_test_node:assert_wait_until_height(peer1, 1),
			?assertEqual(?BIG(999), big_test_node:remote_call(peer1, big_node, get_balance, [Pub1])),
			?assertEqual(?BIG(9000), big_test_node:remote_call(peer1, big_node, get_balance, [Pub2]))
		end
	end,
	[
		{"PS256_65537", timeout, 60, TestWalletTransaction({?RSA_SIGN_ALG, 65537})},
		{"ES256K", timeout, 60, TestWalletTransaction({?ECDSA_SIGN_ALG, secp256k1})},
		{"Ed25519", timeout, 60, TestWalletTransaction({?EDDSA_SIGN_ALG, ed25519})}
	].

%% @doc Ensure that TX Id threading functions correctly (in the positive case).
tx_threading_test_() ->
	{timeout, 120, fun() ->
		Key1 = {_Priv1, Pub1} = big_wallet:new(),
		{_Priv2, Pub2} = big_wallet:new(),
		[B0] = big_weave:init([{big_wallet:to_address(Pub1), ?BIG(10000), <<>>}]),
		big_test_node:start(B0),
		big_test_node:start_peer(peer1, B0),
		big_test_node:connect_to_peer(peer1),
		SignedTX = sign_v1_tx(main, Key1, #{ target => big_wallet:to_address(Pub2),
				quantity => ?BIG(1000), reward => ?BIG(1), last_tx => <<>> }),
		SignedTX2 = sign_v1_tx(main, Key1, #{ target => big_wallet:to_address(Pub2),
				quantity => ?BIG(1000), reward => ?BIG(1), last_tx => SignedTX#tx.id }),
		big_test_node:assert_post_tx_to_peer(main, SignedTX),
		big_test_node:mine(),
		big_test_node:wait_until_height(main, 1),
		big_test_node:assert_post_tx_to_peer(main, SignedTX2),
		big_test_node:mine(),
		big_test_node:assert_wait_until_height(peer1, 2),
		?assertEqual(?BIG(7998), big_test_node:remote_call(peer1, big_node, get_balance, [Pub1])),
		?assertEqual(?BIG(2000), big_test_node:remote_call(peer1, big_node, get_balance, [Pub2]))
	end}.

persisted_mempool_test_() ->
	%% Make the propagation delay noticeable so that the submitted transactions do not
	%% become ready for mining before the node is restarted and we assert that waiting
	%% transactions found in the persisted mempool are (re-)submitted to peers.
	big_test_node:test_with_mocked_functions([{big_node_worker, calculate_delay,
			fun(_Size) -> 5000 end}], fun test_persisted_mempool/0).

test_persisted_mempool() ->
	{_, Pub} = Wallet = big_wallet:new(),
	[B0] = big_weave:init([{big_wallet:to_address(Pub), ?BIG(10000), <<>>}]),
	big_test_node:start(B0),
	big_test_node:start_peer(peer1, B0),
	big_test_node:disconnect_from(peer1),
	SignedTX = big_test_node:sign_tx(Wallet, #{ last_tx => big_test_node:get_tx_anchor(main) }),
	{ok, {{<<"200">>, _}, _, <<"OK">>, _, _}} = big_test_node:post_tx_to_peer(main, SignedTX, false),
	Mempool = big_mempool:get_map(),
	true = big_util:do_until(
		fun() ->
			maps:is_key(SignedTX#tx.id, Mempool)
		end,
		100,
		10000
	),
	Config = big_test_node:stop(),
	try
		%% Rejoin the network.
		%% Expect the pending transactions to be picked up and distributed.
		ok = application:set_env(bigfile, config, Config#config{
			start_from_latest_state = false,
			peers = [big_test_node:peer_ip(peer1)]
		}),
		big:start_dependencies(),
		big_test_node:wait_until_joined(),
		big_test_node:connect_to_peer(peer1),
		big_test_node:assert_wait_until_receives_txs(peer1, [SignedTX]),
		big_test_node:mine(),
		[{H, _, _} | _] = big_test_node:assert_wait_until_height(peer1, 1),
		B = read_block_when_stored(H),
		?assertEqual([SignedTX#tx.id], B#block.txs)
	after
		ok = application:set_env(bigfile, config, Config)
	end.
