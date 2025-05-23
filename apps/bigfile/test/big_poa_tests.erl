-module(big_poa_tests).

-include_lib("bigfile/include/big.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(big_test_node, [wait_until_height/2, assert_wait_until_height/2, read_block_when_stored/1]).

v1_transactions_after_2_0_test_() ->
	{timeout, 420, fun test_v1_transactions_after_2_0/0}.

test_v1_transactions_after_2_0() ->
	Key = {_, Pub1} = big_wallet:new(),
	Key2 = {_, Pub2} = big_wallet:new(),
	[B0] = big_weave:init([
		{big_wallet:to_address(Pub1), ?BIG(100), <<>>},
		{big_wallet:to_address(Pub2), ?BIG(100), <<>>}
	]),
	big_test_node:start(B0),
	big_test_node:start_peer(peer1, B0),
	big_test_node:connect_to_peer(peer1),
	TXs = generate_txs(Key, fun big_test_node:sign_v1_tx/2),
	lists:foreach(
		fun(TX) ->
			big_test_node:assert_post_tx_to_peer(peer1, TX)
		end,
		TXs
	),
	big_test_node:assert_wait_until_receives_txs(TXs),
	lists:foreach(
		fun(Height) ->
			big_test_node:mine(peer1),
			BI = wait_until_height(main, Height),
			case Height of
				1 ->
					assert_txs_mined(TXs, BI);
				_ ->
					noop
			end,
			assert_wait_until_height(peer1, Height)
		end,
		lists:seq(1, 10)
	),
	MoreTXs = generate_txs(Key2, fun big_test_node:sign_v1_tx/2),
	lists:foreach(
		fun(TX) ->
			big_test_node:assert_post_tx_to_peer(peer1, TX)
		end,
		MoreTXs
	),
	big_test_node:assert_wait_until_receives_txs(MoreTXs),
	lists:foreach(
		fun(Height) ->
			big_test_node:mine(peer1),
			BI = wait_until_height(main, Height),
			case Height of
				11 ->
					assert_txs_mined(MoreTXs, BI);
				_ ->
					noop
			end,
			assert_wait_until_height(peer1, Height)
		end,
		lists:seq(11, 20)
	).

v2_transactions_after_2_0_test_() ->
	{timeout, 420, fun test_v2_transactions_after_2_0/0}.

test_v2_transactions_after_2_0() ->
	Key = {_, Pub1} = big_wallet:new(),
	Key2 = {_, Pub2} = big_wallet:new(),
	[B0] = big_weave:init([
		{big_wallet:to_address(Pub1), ?BIG(100), <<>>},
		{big_wallet:to_address(Pub2), ?BIG(100), <<>>}
	]),
	big_test_node:start(B0),
	big_test_node:start_peer(peer1, B0),
	big_test_node:connect_to_peer(peer1),
	TXs = generate_txs(Key, fun big_test_node:sign_tx/2),
	lists:foreach(
		fun(TX) ->
			big_test_node:assert_post_tx_to_peer(peer1, TX)
		end,
		TXs
	),
	big_test_node:assert_wait_until_receives_txs(TXs),
	lists:foreach(
		fun(Height) ->
			big_test_node:mine(peer1),
			BI = wait_until_height(main, Height),
			case Height of
				1 ->
					assert_txs_mined(TXs, BI);
				_ ->
					noop
			end,
			assert_wait_until_height(peer1, Height)
		end,
		lists:seq(1, 10)
	),
	MoreTXs = generate_txs(Key2, fun big_test_node:sign_tx/2),
	lists:foreach(
		fun(TX) ->
			big_test_node:assert_post_tx_to_peer(peer1, TX)
		end,
		MoreTXs
	),
	big_test_node:assert_wait_until_receives_txs(MoreTXs),
	lists:foreach(
		fun(Height) ->
			big_test_node:mine(peer1),
			BI = wait_until_height(main, Height),
			case Height of
				11 ->
					assert_txs_mined(MoreTXs, BI);
				_ ->
					noop
			end,
			assert_wait_until_height(peer1, Height)
		end,
		lists:seq(11, 20)
	).

recall_byte_on_the_border_test_() ->
	{timeout, 420, fun test_recall_byte_on_the_border/0}.

test_recall_byte_on_the_border() ->
	Key = {_, Pub} = big_wallet:new(),
	[B0] = big_weave:init([
		{big_wallet:to_address(Pub), ?BIG(100), <<>>}
	]),
	big_test_node:start(B0),
	big_test_node:start_peer(peer1, B0),
	big_test_node:connect_to_peer(peer1),
	%% Generate one-byte transactions so that recall byte is often on the
	%% the border between two transactions.
	TXs = [
		big_test_node:sign_tx(Key, #{ data => <<"A">>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) }),
		big_test_node:sign_tx(Key, #{ data => <<"B">>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) }),
		big_test_node:sign_tx(Key, #{ data => <<"B">>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) }),
		big_test_node:sign_tx(Key, #{ data => <<"C">>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) })
	],
	lists:foreach(
		fun(TX) ->
			big_test_node:assert_post_tx_to_peer(peer1, TX)
		end,
		TXs
	),
	big_test_node:assert_wait_until_receives_txs(TXs),
	lists:foreach(
		fun(Height) ->
			big_test_node:mine(peer1),
			BI = wait_until_height(main, Height),
			case Height of
				1 ->
					assert_txs_mined(TXs, BI);
				_ ->
					noop
			end,
			assert_wait_until_height(peer1, Height)
		end,
		lists:seq(1, 10)
	).

ignores_transactions_with_invalid_data_root_test_() ->
	{timeout, 420, fun test_ignores_transactions_with_invalid_data_root/0}.

test_ignores_transactions_with_invalid_data_root() ->
	Key = {_, Pub} = big_wallet:new(),
	[B0] = big_weave:init([
		{big_wallet:to_address(Pub), ?BIG(100), <<>>}
	]),
	big_test_node:start(B0),
	big_test_node:start_peer(peer1, B0),
	big_test_node:connect_to_peer(peer1),
	%% Generate transactions where half of them are valid and the other
	%% half has an invalid data_root.
	GenerateTXParams =
		fun
			(valid) ->
				#{ data => <<"DATA">>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) };
			(invalid) ->
				#{ data_root => crypto:strong_rand_bytes(32),
					data => <<"DATA">>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) }
		end,
	TXs = [
		big_test_node:sign_tx(Key, GenerateTXParams(valid)),
		(big_test_node:sign_tx(Key, GenerateTXParams(invalid)))#tx{ data = <<>> },
		big_test_node:sign_tx(Key, GenerateTXParams(valid)),
		(big_test_node:sign_tx(Key, GenerateTXParams(invalid)))#tx{ data = <<>> },
		big_test_node:sign_tx(Key, GenerateTXParams(valid)),
		(big_test_node:sign_tx(Key, GenerateTXParams(invalid)))#tx{ data = <<>> },
		big_test_node:sign_tx(Key, GenerateTXParams(valid)),
		(big_test_node:sign_tx(Key, GenerateTXParams(invalid)))#tx{ data = <<>> },
		big_test_node:sign_tx(Key, GenerateTXParams(valid)),
		(big_test_node:sign_tx(Key, GenerateTXParams(invalid)))#tx{ data = <<>> }
	],
	lists:foreach(
		fun(TX) ->
			big_test_node:assert_post_tx_to_peer(peer1, TX)
		end,
		TXs
	),
	big_test_node:assert_wait_until_receives_txs(TXs),
	lists:foreach(
		fun(Height) ->
			big_test_node:mine(peer1),
			BI = wait_until_height(main, Height),
			case Height of
				1 ->
					assert_txs_mined(TXs, BI);
				_ ->
					noop
			end,
			assert_wait_until_height(peer1, Height)
		end,
		lists:seq(1, 10)
	).

generate_txs(Key, SignFun) ->
	[
		SignFun(Key, #{ data => <<>>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) }),
		SignFun(Key, #{ data => <<"B">>, tags => [random_nonce()], last_tx => big_test_node:get_tx_anchor(peer1) }),
		SignFun(
			Key, #{
				data => <<"DATA">>,
				tags => [random_nonce()],
				last_tx => big_test_node:get_tx_anchor(peer1)
			}
		),
		SignFun(
			Key, #{
				data => << <<"B">> || _ <- lists:seq(1, ?DATA_CHUNK_SIZE) >>,
				tags => [random_nonce()],
				last_tx => big_test_node:get_tx_anchor(peer1)
			}
		),
		SignFun(
			Key,
			#{
				data => << <<"B">> || _ <- lists:seq(1, ?DATA_CHUNK_SIZE * 2) >>,
				tags => [random_nonce()],
				last_tx => big_test_node:get_tx_anchor(peer1)
			}
		),
		SignFun(
			Key, #{
				data => << <<"B">> || _ <- lists:seq(1, ?DATA_CHUNK_SIZE * 3) >>,
				tags => [random_nonce()],
				last_tx => big_test_node:get_tx_anchor(peer1)
			}
		),
		SignFun(
			Key, #{
				data => << <<"B">> || _ <- lists:seq(1, ?DATA_CHUNK_SIZE * 13) >>,
				tags => [random_nonce()],
				last_tx => big_test_node:get_tx_anchor(peer1)
			}
		)
	].

random_nonce() ->
	{<<"nonce">>, integer_to_binary(rand:uniform(1000000))}.

assert_txs_mined(TXs, [{H, _, _} | _]) ->
	B = read_block_when_stored(H),
	TXIDs = [TX#tx.id || TX <- TXs],
	?assertEqual(length(TXIDs), length(B#block.txs)),
	?assertEqual(lists:sort(TXIDs), lists:sort(B#block.txs)).
