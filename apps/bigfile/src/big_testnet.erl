-module(big_testnet).

-export([is_testnet/0, height_testnet_fork/0, top_up_test_wallet/2,
		locked_rewards_blocks/1, reward_history_blocks/1, target_block_time/1,
		legacy_reward_history_blocks/1]).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_pricing.hrl").

-ifndef(TESTNET_REWARD_HISTORY_BLOCKS).
-define(TESTNET_REWARD_HISTORY_BLOCKS, ?REWARD_HISTORY_BLOCKS).
-endif.

-ifndef(TESTNET_LEGACY_REWARD_HISTORY_BLOCKS).
-define(TESTNET_LEGACY_REWARD_HISTORY_BLOCKS, ?LEGACY_REWARD_HISTORY_BLOCKS).
-endif.

-ifndef(TESTNET_LOCKED_REWARDS_BLOCKS).
-define(TESTNET_LOCKED_REWARDS_BLOCKS, ?LOCKED_REWARDS_BLOCKS).
-endif.

-ifndef(TESTNET_TARGET_BLOCK_TIME).
-define(TESTNET_TARGET_BLOCK_TIME, ?TARGET_BLOCK_TIME).
-endif.

-ifndef(TESTNET_FORK_HEIGHT).
-define(TESTNET_FORK_HEIGHT, infinity).
-endif.

-ifdef(TESTNET).
is_testnet() -> true.
-else.
is_testnet() -> false.
-endif.

-ifdef(TESTNET).
height_testnet_fork() ->
	?TESTNET_FORK_HEIGHT.
-else.
height_testnet_fork() ->
	infinity.
-endif.

-ifdef(TESTNET).
top_up_test_wallet(Accounts, Height) ->
	case Height == height_testnet_fork() of
		true ->
			Addr = big_util:decode(<<?TEST_WALLET_ADDRESS>>),
			maps:put(Addr, {?BIG(?TOP_UP_TEST_WALLET_BIG), <<>>, 1, true}, Accounts);
		false ->
			Accounts
	end.
-else.
top_up_test_wallet(Accounts, _Height) ->
	Accounts.
-endif.

-ifdef(TESTNET).
locked_rewards_blocks(Height) ->
	case Height >= height_testnet_fork() of
		true ->
			?TESTNET_LOCKED_REWARDS_BLOCKS;
		false ->
			?LOCKED_REWARDS_BLOCKS
	end.
-else.
locked_rewards_blocks(_Height) ->
	?LOCKED_REWARDS_BLOCKS.
-endif.

-ifdef(TESTNET).
reward_history_blocks(Height) ->
	case Height >= height_testnet_fork() of
		true ->
			?TESTNET_REWARD_HISTORY_BLOCKS;
		false ->
			?REWARD_HISTORY_BLOCKS
	end.
-else.
reward_history_blocks(_Height) ->
	?REWARD_HISTORY_BLOCKS.
-endif.

-ifdef(TESTNET).
legacy_reward_history_blocks(Height) ->
	case Height >= height_testnet_fork() of
		true ->
			?TESTNET_LEGACY_REWARD_HISTORY_BLOCKS;
		false ->
			?LEGACY_REWARD_HISTORY_BLOCKS
	end.
-else.
legacy_reward_history_blocks(_Height) ->
	?LEGACY_REWARD_HISTORY_BLOCKS.
-endif.

-ifdef(TESTNET).
target_block_time(Height) ->
	case Height >= height_testnet_fork() of
		true ->
			?TESTNET_TARGET_BLOCK_TIME;
		false ->
			?TARGET_BLOCK_TIME
	end.
-else.
target_block_time(_Height) ->
	?TARGET_BLOCK_TIME.
-endif.
