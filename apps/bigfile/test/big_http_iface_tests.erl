-module(big_http_iface_tests).

-include_lib("bigfile/include/big_consensus.hrl").
-include_lib("bigfile/include/big_config.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(big_test_node, [wait_until_height/2, wait_until_receives_txs/1,
		read_block_when_stored/1, read_block_when_stored/2, assert_wait_until_height/2]).

start_node() ->
	%% Starting a node is slow so we'll run it once for the whole test module
	Wallet1 = {_, Pub1} = big_wallet:new(),
	Wallet2 = {_, Pub2} = big_wallet:new(),
	%% This wallet is never spent from or deposited to, so the balance is predictable
	StaticWallet = {_, Pub3} = big_wallet:new(),
	[B0] = big_weave:init([
		{big_wallet:to_address(Pub1), ?BIG(10000), <<>>},
		{big_wallet:to_address(Pub2), ?BIG(10000), <<>>},
		{big_wallet:to_address(Pub3), ?BIG(10), <<"TEST_ID">>}
	], 0), %% Set difficulty to 0 to speed up tests
	big_test_node:start(B0),
	big_test_node:start_peer(peer1, B0),
	big_test_node:connect_to_peer(peer1),
	{B0, Wallet1, Wallet2, StaticWallet}.

reset_node() ->
	big_blacklist_middleware:reset(),
	big_test_node:remote_call(peer1, big_blacklist_middleware, reset, []),
	big_test_node:connect_to_peer(peer1).

setup_all_batch() ->
	%% Never retarget the difficulty - this ensures the tests are always
	%% run against difficulty 0. Because of this we also have to hardcode
	%% the TX fee, otherwise it can jump pretty high.
	{Setup, Cleanup} = big_test_node:mock_functions([
		{big_retarget, is_retarget_height, fun(_Height) -> false end},
		{big_retarget, is_retarget_block, fun(_Block) -> false end},
		{big_tx, get_tx_fee, fun(_Args) -> ?BIG(1) end}
		]),
	Functions = Setup(),
	GenesisData = start_node(),
	{GenesisData, {Cleanup, Functions}}.

cleanup_all_batch({_GenesisData, {Cleanup, Functions}}) ->
	Cleanup(Functions).

test_register(TestFun, Fixture) ->
	{timeout, 60, {with, Fixture, [TestFun]}}.

%% -------------------------------------------------------------------
%% The spammer tests must run first. All the other tests will call
%% big_blacklist_middleware:reset() periodically and this will restart
%% the 30-second throttle counter using timer:apply_after(30000, ...).
%% However since most tests are less than 30 seconds, we end up with
%% several pending timer:apply_after that can hit, and reset the
%% throttle counter at any moment. This has caused these spammer tests
%% to fail randomly in the past depending on whether or not the
%% throttle counter was reset before the test finished.
%% -------------------------------------------------------------------

%% @doc Test that nodes sending too many requests are temporarily blocked: (a) GET.
node_blacklisting_get_spammer_test_() ->
	{timeout, 10, fun test_node_blacklisting_get_spammer/0}.

%% @doc Test that nodes sending too many requests are temporarily blocked: (b) POST.
node_blacklisting_post_spammer_test_() ->
	{timeout, 10, fun test_node_blacklisting_post_spammer/0}.

%% @doc Check that we can qickly get the local time from the peer.
get_time_test() ->
	Now = os:system_time(second),
	{ok, {Min, Max}} = big_http_iface_client:get_time(big_test_node:peer_ip(main), 10 * 1000),
	?assert(Min < Now),
	?assert(Now < Max).

batch_test_() ->
	{setup, fun setup_all_batch/0, fun cleanup_all_batch/1,
		fun ({GenesisData, _MockData}) ->
			{foreach, fun reset_node/0, [
				%% ---------------------------------------------------------
				%% The following tests must be run at a block height of 0.
				%% ---------------------------------------------------------
				test_register(fun test_get_total_supply/1, GenesisData),
				test_register(fun test_get_current_block/1, GenesisData),
				test_register(fun test_get_height/1, GenesisData),
				%% ---------------------------------------------------------
				%% The following tests are read-only and will not modify
				%% state. They assume that the blockchain state
				%% is fixed (and set by start_node and test_get_height).
				%% ---------------------------------------------------------
				test_register(fun test_get_wallet_list_in_chunks/1, GenesisData),
				test_register(fun test_get_info/1, GenesisData),
				test_register(fun test_get_last_tx_single/1, GenesisData),
				test_register(fun test_get_block_by_hash/1, GenesisData),
				test_register(fun test_get_block_by_height/1, GenesisData),
				test_register(fun test_get_non_existent_block/1, GenesisData),
				%% ---------------------------------------------------------
				%% The following tests are *not* read-only and may modify
				%% state. They can *not* assume a fixed blockchain state.
				%% ---------------------------------------------------------
				test_register(fun test_addresses_with_checksum/1, GenesisData),
				test_register(fun test_single_regossip/1, GenesisData),
				test_register(fun test_get_balance/1, GenesisData),
				test_register(fun test_get_format_2_tx/1, GenesisData),
				test_register(fun test_get_format_1_tx/1, GenesisData),
				test_register(fun test_add_external_tx_with_tags/1, GenesisData),
				test_register(fun test_find_external_tx/1, GenesisData),
				test_register(fun test_add_tx_and_get_last/1, GenesisData),
				test_register(fun test_get_subfields_of_tx/1, GenesisData),
				test_register(fun test_get_pending_tx/1, GenesisData),
				test_register(fun test_get_tx_body/1, GenesisData),
				test_register(fun test_get_tx_status/1, GenesisData),
				test_register(fun test_post_unsigned_tx/1, GenesisData),
				test_register(fun test_get_error_of_data_limit/1, GenesisData),
				test_register(fun test_send_missing_tx_with_the_block/1, GenesisData),
				test_register(
					fun test_fallback_to_block_endpoint_if_cannot_send_tx/1, GenesisData),
				test_register(fun test_get_recent_hash_list_diff/1, GenesisData),
				test_register(fun test_get_total_supply/1, GenesisData)
			]}
		end
	}.

test_addresses_with_checksum({_, Wallet1, {_, Pub2}, _}) ->
	RemoteHeight = height(peer1),
	Address19 = crypto:strong_rand_bytes(19),
	Address65 = crypto:strong_rand_bytes(65),
	Address20 = crypto:strong_rand_bytes(20),
	Address32 = big_wallet:to_address(Pub2),
	TX = big_test_node:sign_tx(Wallet1, #{ last_tx => big_test_node:get_tx_anchor(peer1) }),
	{JSON} = big_serialize:tx_to_json_struct(TX),
	JSON2 = proplists:delete(<<"target">>, JSON),
	TX2 = big_test_node:sign_tx(Wallet1, #{ last_tx => big_test_node:get_tx_anchor(peer1), target => Address32 }),
	{JSON3} = big_serialize:tx_to_json_struct(TX2),
	InvalidPayloads = [
		[{<<"target">>, <<":">>} | JSON2],
		[{<<"target">>, << <<":">>/binary, (big_util:encode(<< 0:32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (big_util:encode(Address19))/binary, <<":">>/binary,
				(big_util:encode(<< (erlang:crc32(Address19)):32 >> ))/binary >>} | JSON2],
		[{<<"target">>, << (big_util:encode(Address65))/binary, <<":">>/binary,
				(big_util:encode(<< (erlang:crc32(Address65)):32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (big_util:encode(Address32))/binary, <<":">>/binary,
				(big_util:encode(<< 0:32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (big_util:encode(Address20))/binary, <<":">>/binary,
				(big_util:encode(<< 1:32 >>))/binary >>} | JSON2],
		[{<<"target">>, << (big_util:encode(Address32))/binary, <<":">>/binary,
				(big_util:encode(<< (erlang:crc32(Address32)):32 >>))/binary,
				<<":">>/binary >>} | JSON2],
		[{<<"target">>, << (big_util:encode(Address32))/binary, <<":">>/binary >>} | JSON3]
	],
	lists:foreach(
		fun(Struct) ->
			Payload = big_serialize:jsonify({Struct}),
			?assertMatch({ok, {{<<"400">>, _}, _, <<"Invalid JSON.">>, _, _}},
					big_test_node:post_tx_json(main, Payload))
		end,
		InvalidPayloads
	),
	ValidPayloads = [
		[{<<"target">>, << (big_util:encode(Address32))/binary, <<":">>/binary,
				(big_util:encode(<< (erlang:crc32(Address32)):32 >>))/binary >>} | JSON3],
		JSON
	],
	lists:foreach(
		fun(Struct) ->
			Payload = big_serialize:jsonify({Struct}),
			?assertMatch({ok, {{<<"200">>, _}, _, <<"OK">>, _, _}},
					big_test_node:post_tx_json(main, Payload))
		end,
		ValidPayloads
	),
	big_test_node:assert_wait_until_receives_txs(peer1, [TX, TX2]),
	big_test_node:mine(),
	[{H, _, _} | _] = big_test_node:wait_until_height(peer1, RemoteHeight + 1),
	B = read_block_when_stored(H),
	ChecksumAddr = << (big_util:encode(Address32))/binary, <<":">>/binary,
			(big_util:encode(<< (erlang:crc32(Address32)):32 >>))/binary >>,
	?assertEqual(2, length(B#block.txs)),
	Balance = get_balance(big_util:encode(Address32)),
	?assertEqual(Balance, get_balance(ChecksumAddr)),
	LastTX = get_last_tx(big_util:encode(Address32)),
	?assertEqual(LastTX, get_last_tx(ChecksumAddr)),
	Price = get_price(big_util:encode(Address32)),
	?assertEqual(Price, get_price(ChecksumAddr)),
	ServeTXTarget = maps:get(<<"target">>, jiffy:decode(get_tx(TX2#tx.id), [return_maps])),
	?assertEqual(big_util:encode(TX2#tx.target), ServeTXTarget).

get_balance(EncodedAddr) ->
	Peer = big_test_node:peer_ip(main),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		big_http:req(#{
			method => get,
			peer => Peer,
			path => "/wallet/" ++ binary_to_list(EncodedAddr) ++ "/balance",
			headers => [{<<"x-p2p-port">>, integer_to_binary(Port)}]
		}),
	binary_to_integer(Reply).

get_last_tx(EncodedAddr) ->
	Peer = big_test_node:peer_ip(main),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		big_http:req(#{
			method => get,
			peer => Peer,
			path => "/wallet/" ++ binary_to_list(EncodedAddr) ++ "/last_tx",
			headers => [{<<"x-p2p-port">>, integer_to_binary(Port)}]
		}),
	Reply.

get_price(EncodedAddr) ->
	Peer = big_test_node:peer_ip(main),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		big_http:req(#{
			method => get,
			peer => Peer,
			path => "/price/0/" ++ binary_to_list(EncodedAddr),
			headers => [{<<"x-p2p-port">>, integer_to_binary(Port)}]
		}),
	binary_to_integer(Reply).

get_tx(ID) ->
	Peer = big_test_node:peer_ip(main),
	{_, _, _, _, Port} = Peer,
	{ok, {{<<"200">>, _}, _, Reply, _, _}} =
		big_http:req(#{
			method => get,
			peer => Peer,
			path => "/tx/" ++ binary_to_list(big_util:encode(ID)),
			headers => [{<<"x-p2p-port">>, integer_to_binary(Port)}]
		}),
	Reply.

%% @doc Ensure that server info can be retreived via the HTTP interface.
test_get_info(_) ->
	?assertEqual(info_unavailable,
		big_http_iface_client:get_info(big_test_node:peer_ip(main), bad_key)),
	?assertEqual(<<?NETWORK_NAME>>,
			big_http_iface_client:get_info(big_test_node:peer_ip(main), network)),
	?assertEqual(?RELEASE_NUMBER,
			big_http_iface_client:get_info(big_test_node:peer_ip(main), release)),
	?assertEqual(
		?CLIENT_VERSION,
		big_http_iface_client:get_info(big_test_node:peer_ip(main), version)),
	?assertEqual(1, big_http_iface_client:get_info(big_test_node:peer_ip(main), peers)),
	big_util:do_until(
		fun() ->
			1 == big_http_iface_client:get_info(big_test_node:peer_ip(main), blocks)
		end,
		100,
		2000
	),
	?assertEqual(1, big_http_iface_client:get_info(big_test_node:peer_ip(main), height)).

%% @doc Ensure that transactions are only accepted once.
test_single_regossip(_) ->
	big_test_node:disconnect_from(peer1),
	TX = big_tx:new(),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		big_http_iface_client:send_tx_json(big_test_node:peer_ip(main), TX#tx.id,
				big_serialize:jsonify(big_serialize:tx_to_json_struct(TX)))
	),
	?assertMatch(
		{ok, {{<<"200">>, _}, _, _, _, _}},
		big_test_node:remote_call(peer1, big_http_iface_client, send_tx_binary, [big_test_node:peer_ip(peer1), TX#tx.id,
				big_serialize:tx_to_binary(TX)])
	),
	?assertMatch(
		{ok, {{<<"208">>, _}, _, _, _, _}},
		big_test_node:remote_call(peer1, big_http_iface_client, send_tx_binary, [big_test_node:peer_ip(peer1), TX#tx.id,
				big_serialize:tx_to_binary(TX)])
	),
	?assertMatch(
		{ok, {{<<"208">>, _}, _, _, _, _}},
		big_test_node:remote_call(peer1, big_http_iface_client, send_tx_json, [big_test_node:peer_ip(peer1), TX#tx.id,
				big_serialize:jsonify(big_serialize:tx_to_json_struct(TX))])
	).

test_node_blacklisting_get_spammer() ->
	{ok, Config} = application:get_env(bigfile, config),
	{RequestFun, ErrorResponse} = get_fun_msg_pair(get_info),
	node_blacklisting_test_frame(
		RequestFun,
		ErrorResponse,
		Config#config.requests_per_minute_limit div 2 + 1,
		1
	).

test_node_blacklisting_post_spammer() ->
	{ok, Config} = application:get_env(bigfile, config),
	{RequestFun, ErrorResponse} = get_fun_msg_pair(send_tx_binary),
	NErrors = 11,
	NRequests = Config#config.requests_per_minute_limit div 2 + NErrors,
	node_blacklisting_test_frame(RequestFun, ErrorResponse, NRequests, NErrors).

%% @doc Given a label, return a fun and a message.
-spec get_fun_msg_pair(atom()) -> {fun(), any()}.
get_fun_msg_pair(get_info) ->
	{ fun(_) ->
			big_http_iface_client:get_info(big_test_node:peer_ip(main))
		end
	, info_unavailable};
get_fun_msg_pair(send_tx_binary) ->
	{ fun(_) ->
			InvalidTX = (big_tx:new())#tx{ owner = <<"key">>, signature = <<"invalid">> },
			case big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main),
					InvalidTX#tx.id, big_serialize:tx_to_binary(InvalidTX)) of
				{ok,
					{{<<"429">>, <<"Too Many Requests">>}, _,
						<<"Too Many Requests">>, _, _}} ->
					too_many_requests;
				{ok, _} ->
					ok;
				{error, Error} ->
					?debugFmt("Unexpected response: ~p.~n", [Error]),
					?assert(false)
			end
		end
	, too_many_requests}.

%% @doc Frame to test spamming an endpoint.
%% TODO: Perform the requests in parallel. Just changing the lists:map/2 call
%% to an big_util:pmap/2 call fails the tests currently.
-spec node_blacklisting_test_frame(fun(), any(), non_neg_integer(), non_neg_integer()) -> ok.
node_blacklisting_test_frame(RequestFun, ErrorResponse, NRequests, ExpectedErrors) ->
	big_blacklist_middleware:reset(),
	big_rate_limiter:off(),
	Responses = lists:map(RequestFun, lists:seq(1, NRequests)),
	?assertEqual(length(Responses), NRequests),
	big_blacklist_middleware:reset(),
	ByResponseType = count_by_response_type(ErrorResponse, Responses),
	Expected = #{
		error_responses => ExpectedErrors,
		ok_responses => NRequests - ExpectedErrors
	},
	?assertEqual(Expected, ByResponseType),
	big_rate_limiter:on().

%% @doc Count the number of successful and error responses.
count_by_response_type(ErrorResponse, Responses) ->
	count_by(
		fun
			(Response) when Response == ErrorResponse -> error_responses;
			(_) -> ok_responses
		end,
		Responses
	).

%% @doc Count the occurances in the list based on the predicate.
count_by(Pred, List) ->
	maps:map(fun (_, Value) -> length(Value) end, group(Pred, List)).

%% @doc Group the list based on the key generated by Grouper.
group(Grouper, Values) ->
	group(Grouper, Values, maps:new()).

group(_, [], Acc) ->
	Acc;
group(Grouper, [Item | List], Acc) ->
	Key = Grouper(Item),
	Updater = fun (Old) -> [Item | Old] end,
	NewAcc = maps:update_with(Key, Updater, [Item], Acc),
	group(Grouper, List, NewAcc).

%% @doc Check that balances can be retreived over the network.
test_get_balance({B0, _, _, {_, Pub1}}) ->
	LocalHeight = big_node:get_height(),
	Addr = binary_to_list(big_util:encode(big_wallet:to_address(Pub1))),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet/" ++ Addr ++ "/balance"
		}),
	?assertEqual(?BIG(10), binary_to_integer(Body)),
	RootHash = binary_to_list(big_util:encode(B0#block.wallet_list)),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet_list/" ++ RootHash ++ "/" ++ Addr ++ "/balance"
		}),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet_list/" ++ RootHash ++ "/" ++ Addr ++ "/balance"
		}).

test_get_wallet_list_in_chunks({B0, {_, Pub1}, {_, Pub2}, {_, StaticPub}}) ->
	Addr1 = big_wallet:to_address(Pub1),
	Addr2 = big_wallet:to_address(Pub2),
	StaticAddr = big_wallet:to_address(StaticPub),
	NonExistentRootHash = binary_to_list(big_util:encode(crypto:strong_rand_bytes(32))),
	{ok, {{<<"404">>, _}, _, <<"Root hash not found.">>, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet_list/" ++ NonExistentRootHash
		}),

	[TX] = B0#block.txs,
	GenesisAddr = big_wallet:to_address(TX#tx.owner, {?RSA_SIGN_ALG, 65537}),
	TXID = TX#tx.id,
	ExpectedWallets = lists:sort([
			{Addr1, {?BIG(10000), <<>>}},
			{Addr2, {?BIG(10000), <<>>}},
			{StaticAddr, {?BIG(10), <<"TEST_ID">>}},
			{GenesisAddr, {0, TXID}}]),
	{ExpectedWallets1, ExpectedWallets2} = lists:split(2, ExpectedWallets),
	RootHash = binary_to_list(big_util:encode(B0#block.wallet_list)),
	{ok, {{<<"200">>, _}, _, Body1, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet_list/" ++ RootHash
		}),
	Cursor = maps:get(next_cursor, binary_to_term(Body1)),
	?assertEqual(#{
			next_cursor => Cursor,
			wallets => lists:reverse(ExpectedWallets1)
		}, binary_to_term(Body1)),

	{ok, {{<<"200">>, _}, _, Body2, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet_list/" ++ RootHash ++ "/" ++ big_util:encode(Cursor)
		}),
	?assertEqual(#{
			next_cursor => last,
			wallets => lists:reverse(ExpectedWallets2)
		}, binary_to_term(Body2)).

%% @doc Test that heights are returned correctly.
test_get_height(_) ->
	0 = big_http_iface_client:get_height(big_test_node:peer_ip(main)),
	big_test_node:mine(),
	wait_until_height(main, 1),
	1 = big_http_iface_client:get_height(big_test_node:peer_ip(main)).

%% @doc Test that last tx associated with a wallet can be fetched.
test_get_last_tx_single({_, _, _, {_, StaticPub}}) ->
	Addr = binary_to_list(big_util:encode(big_wallet:to_address(StaticPub))),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet/" ++ Addr ++ "/last_tx"
		}),
	?assertEqual(<<"TEST_ID">>, big_util:decode(Body)).

%% @doc Ensure that blocks can be received via a hash.
test_get_block_by_hash({B0, _, _, _}) ->
	{_Peer, B1, _Time, _Size} = big_http_iface_client:get_block_shadow(B0#block.indep_hash,
			big_test_node:peer_ip(main), binary, #{}),
	TXIDs = [TX#tx.id || TX <- B0#block.txs],
	?assertEqual(B0#block{ size_tagged_txs = unset, account_tree = undefined, txs = TXIDs,
			reward_history = [], block_time_history = [] }, B1).

%% @doc Ensure that blocks can be received via a height.
test_get_block_by_height({B0, _, _, _}) ->
	{_Peer, B1, _Time, _Size} = big_http_iface_client:get_block_shadow(0, big_test_node:peer_ip(main), binary, #{}),
	TXIDs = [TX#tx.id || TX <- B0#block.txs],
	?assertEqual(B0#block{ size_tagged_txs = unset, account_tree = undefined, txs = TXIDs,
			reward_history = [], block_time_history = [] }, B1).

test_get_current_block({B0, _, _, _}) ->
	Peer = big_test_node:peer_ip(main),
	{ok, BI} = big_http_iface_client:get_block_index(Peer, 0, 100),
	{_Peer, B1, _Time, _Size} =
	big_http_iface_client:get_block_shadow(hd(BI), Peer, binary, #{}),
	TXIDs = [TX#tx.id || TX <- B0#block.txs],
	?assertEqual(B0#block{ size_tagged_txs = unset, txs = TXIDs, reward_history = [],
			block_time_history = [], account_tree = undefined }, B1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main), path => "/block/current" }),
	{JSONStruct} = jiffy:decode(Body),
	?assertEqual(big_util:encode(B0#block.indep_hash),
			proplists:get_value(<<"indep_hash">>, JSONStruct)).

%% @doc Test that the various different methods of GETing a block all perform
%% correctly if the block cannot be found.
test_get_non_existent_block(_) ->
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main), path => "/block/height/100" }),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main), path => "/block2/height/100" }),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main), path => "/block/hash/abcd" }),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main), path => "/block2/hash/abcd" }),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
				path => "/block/height/101/wallet_list" }),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
				path => "/block/hash/abcd/wallet_list" }),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
				path => "/block/height/101/hash_list" }),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
				path => "/block/hash/abcd/hash_list" }).

%% @doc A test for retrieving format=2 transactions from HTTP API.
test_get_format_2_tx(_) ->
	LocalHeight = big_node:get_height(),
	DataRoot = (big_tx:generate_chunk_tree(#tx{ data = <<"DATA">> }))#tx.data_root,
	ValidTX = #tx{ id = TXID } = (big_tx:new(<<"DATA">>))#tx{
			format = 2,
			data_root = DataRoot },
	InvalidDataRootTX = #tx{ id = InvalidTXID } = (big_tx:new(<<"DATA">>))#tx{ format = 2 },
	EmptyTX = #tx{ id = EmptyTXID } = (big_tx:new())#tx{ format = 2 },
	EncodedTXID = binary_to_list(big_util:encode(TXID)),
	EncodedInvalidTXID = binary_to_list(big_util:encode(InvalidTXID)),
	EncodedEmptyTXID = binary_to_list(big_util:encode(EmptyTXID)),
	big_http_iface_client:send_tx_json(big_test_node:peer_ip(main), ValidTX#tx.id,
			big_serialize:jsonify(big_serialize:tx_to_json_struct(ValidTX))),
	{ok, {{<<"400">>, _}, _, <<"The attached data is split in an unknown way.">>, _, _}} =
		big_http:req(#{
			method => post,
			peer => big_test_node:peer_ip(main),
			path => "/tx",
			body => big_serialize:jsonify(big_serialize:tx_to_json_struct(InvalidDataRootTX))
		}),
	big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main),
			InvalidDataRootTX#tx.id,
			big_serialize:tx_to_binary(InvalidDataRootTX#tx{ data = <<>> })),
	big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main), EmptyTX#tx.id,
			big_serialize:tx_to_binary(EmptyTX)),
	wait_until_receives_txs([ValidTX, EmptyTX, InvalidDataRootTX]),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	%% Ensure format=2 transactions can be retrieved over the HTTP
	%% interface with no populated data, while retaining info on all other fields.
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/tx/" ++ EncodedTXID
		}),
	?assertEqual(ValidTX#tx{
			data = <<>>,
			data_size = 4
		}, big_serialize:json_struct_to_tx(Body)),
	%% Ensure data can be fetched for format=2 transactions via /tx/[ID]/data.
	{ok, Data} = wait_until_syncs_tx_data(TXID),
	?assertEqual(big_util:encode(<<"DATA">>), Data),
	{ok, {{<<"404">>, _}, _, _, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/tx/" ++ EncodedInvalidTXID ++ "/data"
		}),
	%% Ensure /tx/[ID]/data works for format=2 transactions when the data is empty.
	{ok, {{<<"200">>, _}, _, <<>>, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/tx/" ++ EncodedEmptyTXID ++ "/data"
		}),
	%% Ensure data can be fetched for format=2 transactions via /tx/[ID]/data.html.
	{ok, {{<<"200">>, _}, Headers, HTMLData, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/tx/" ++ EncodedTXID ++ "/data.html"
		}),
	?assertEqual(<<"DATA">>, HTMLData),
	?assertEqual(
		[{<<"content-type">>, <<"text/html">>}],
		proplists:lookup_all(<<"content-type">>, Headers)
	).

test_get_format_1_tx(_) ->
	LocalHeight = big_node:get_height(),
	TX = #tx{ id = TXID } = big_tx:new(<<"DATA">>),
	EncodedTXID = binary_to_list(big_util:encode(TXID)),
	big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main), TX#tx.id,
			big_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	{ok, Body} =
		big_util:do_until(
			fun() ->
				case big_http:req(#{
					method => get,
					peer => big_test_node:peer_ip(main),
					path => "/tx/" ++ EncodedTXID
				}) of
					{ok, {{<<"404">>, _}, _, _, _, _}} ->
						false;
					{ok, {{<<"200">>, _}, _, Payload, _, _}} ->
						{ok, Payload}
				end
			end,
			100,
			2000
		),
	?assertEqual(TX, big_serialize:json_struct_to_tx(Body)).

%% @doc Test adding transactions to a block.
test_add_external_tx_with_tags(_) ->
	LocalHeight = big_node:get_height(),
	TX = big_tx:new(<<"DATA">>),
	TaggedTX =
		TX#tx {
			tags =
				[
					{<<"TEST_TAG1">>, <<"TEST_VAL1">>},
					{<<"TEST_TAG2">>, <<"TEST_VAL2">>}
				]
		},
	big_http_iface_client:send_tx_json(big_test_node:peer_ip(main), TaggedTX#tx.id,
			big_serialize:jsonify(big_serialize:tx_to_json_struct(TaggedTX))),
	wait_until_receives_txs([TaggedTX]),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	[B1Hash | _] = big_node:get_blocks(),
	B1 = read_block_when_stored(B1Hash, true),
	TXID = TaggedTX#tx.id,
	?assertEqual([TXID], [TX2#tx.id || TX2 <- B1#block.txs]),
	?assertEqual(TaggedTX, big_storage:read_tx(hd(B1#block.txs))).

%% @doc Test getting transactions
test_find_external_tx(_) ->
	LocalHeight = big_node:get_height(),
		TX = big_tx:new(<<"DATA">>),
	big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main), TX#tx.id,
			big_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	{ok, FoundTXID} =
		big_util:do_until(
			fun() ->
				case big_http_iface_client:get_tx(big_test_node:peer_ip(main), TX#tx.id) of
					not_found ->
						false;
					TX ->
						{ok, TX#tx.id}
				end
			end,
			100,
			5000
		),
	?assertEqual(FoundTXID, TX#tx.id).

%% @doc Post a tx to the network and ensure that last_tx call returns the ID of last tx.
test_add_tx_and_get_last({_B0, Wallet1, Wallet2, _StaticWallet}) ->
	LocalHeight = big_node:get_height(),
	big_test_node:disconnect_from(peer1),
	{_Priv1, Pub1} = Wallet1,
	{_Priv2, Pub2} = Wallet2,
	SignedTX = big_test_node:sign_tx(Wallet1, #{
		target => big_wallet:to_address(Pub2),
		quantity => ?BIG(2),
		reward => ?BIG(1)}),
	ID = SignedTX#tx.id,
	big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main), SignedTX#tx.id,
			big_serialize:tx_to_binary(SignedTX)),
	wait_until_receives_txs([SignedTX]),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/wallet/"
					++ binary_to_list(big_util:encode(big_wallet:to_address(Pub1)))
					++ "/last_tx"
		}),
	?assertEqual(ID, big_util:decode(Body)).

%% @doc Post a tx to the network and ensure that its subfields can be gathered
test_get_subfields_of_tx(_) ->
	LocalHeight = big_node:get_height(),
	TX = big_tx:new(<<"DATA">>),
	big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main), TX#tx.id,
			big_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	{ok, Body} = wait_until_syncs_tx_data(TX#tx.id),
	Orig = TX#tx.data,
	?assertEqual(Orig, big_util:decode(Body)).

%% @doc Correctly check the status of pending is returned for a pending transaction
test_get_pending_tx(_) ->
	TX = big_tx:new(<<"DATA1">>),
	big_http_iface_client:send_tx_json(big_test_node:peer_ip(main), TX#tx.id,
			big_serialize:jsonify(big_serialize:tx_to_json_struct(TX))),
	wait_until_receives_txs([TX]),
	{ok, {{<<"202">>, _}, _, Body, _, _}} =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/tx/" ++ binary_to_list(big_util:encode(TX#tx.id))
		}),
	?assertEqual(<<"Pending">>, Body).

%% @doc Mine a transaction into a block and retrieve it's binary body via HTTP.
test_get_tx_body(_) ->
	big_test_node:disconnect_from(peer1),
	LocalHeight = big_node:get_height(),
	TX = big_tx:new(<<"TEST DATA">>),
	big_test_node:assert_post_tx_to_peer(main, TX),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	{ok, Data} = wait_until_syncs_tx_data(TX#tx.id),
	?assertEqual(<<"TEST DATA">>, big_util:decode(Data)).

test_get_tx_status(_) ->
	big_test_node:connect_to_peer(peer1),
	Height = big_node:get_height(),
	assert_wait_until_height(peer1, Height),
	big_test_node:disconnect_from(peer1),
	TX = (big_tx:new())#tx{ tags = [{<<"TestName">>, <<"TestVal">>}] },
	big_test_node:assert_post_tx_to_peer(main, TX),
	FetchStatus = fun() ->
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/tx/" ++ binary_to_list(big_util:encode(TX#tx.id)) ++ "/status"
		})
	end,
	?assertMatch({ok, {{<<"202">>, _}, _, <<"Pending">>, _, _}}, FetchStatus()),
	big_test_node:mine(),
	wait_until_height(main, Height + 1),
	{ok, {{<<"200">>, _}, _, Body, _, _}} = FetchStatus(),
	{Res} = big_serialize:dejsonify(Body),
	BI = big_node:get_block_index(),
	?assertEqual(
		#{
			<<"block_height">> => length(BI) - 1,
			<<"block_indep_hash">> => big_util:encode(element(1, hd(BI))),
			<<"number_of_confirmations">> => 1
		},
		maps:from_list(Res)
	),
	big_test_node:mine(),
	wait_until_height(main, Height + 2),
	big_util:do_until(
		fun() ->
			{ok, {{<<"200">>, _}, _, Body2, _, _}} = FetchStatus(),
			{Res2} = big_serialize:dejsonify(Body2),
			#{
				<<"block_height">> => length(BI) - 1,
				<<"block_indep_hash">> => big_util:encode(element(1, hd(BI))),
				<<"number_of_confirmations">> => 2
			} == maps:from_list(Res2)
		end,
		200,
		5000
	),
	%% Create a fork which returns the TX to mempool.
	big_test_node:mine(peer1),
	assert_wait_until_height(peer1, Height + 1),
	big_test_node:mine(peer1),
	assert_wait_until_height(peer1, Height + 2),
	big_test_node:connect_to_peer(peer1),
	big_test_node:mine(peer1),
	wait_until_height(main, Height + 3),
	?assertMatch({ok, {{<<"202">>, _}, _, _, _, _}}, FetchStatus()).

test_post_unsigned_tx({_B0, Wallet1, _Wallet2, _StaticWallet}) ->
	LocalHeight = big_node:get_height(),
	{_, Pub} = Wallet = Wallet1,
	%% Generate a wallet and receive a wallet access code.
	{ok, {{<<"421">>, _}, _, _, _, _}} =
		big_http:req(#{
			method => post,
			peer => big_test_node:peer_ip(main),
			path => "/wallet"
		}),
	{ok, Config} = application:get_env(bigfile, config),
	try
		application:set_env(bigfile, config,
				Config#config{ internal_api_secret = <<"correct_secret">> }),
		{ok, {{<<"421">>, _}, _, _, _, _}} =
			big_http:req(#{
				method => post,
				peer => big_test_node:peer_ip(main),
				path => "/wallet",
				headers => [{<<"X-Internal-Api-Secret">>, <<"incorrect_secret">>}]
			}),
		{ok, {{<<"200">>, <<"OK">>}, _, CreateWalletBody, _, _}} =
			big_http:req(#{
				method => post,
				peer => big_test_node:peer_ip(main),
				path => "/wallet",
				headers => [{<<"X-Internal-Api-Secret">>, <<"correct_secret">>}]
			}),
		application:set_env(bigfile, config, Config#config{ internal_api_secret = not_set }),
		{CreateWalletRes} = big_serialize:dejsonify(CreateWalletBody),
		[WalletAccessCode] = proplists:get_all_values(<<"wallet_access_code">>, CreateWalletRes),
		[Address] = proplists:get_all_values(<<"wallet_address">>, CreateWalletRes),
		%% Top up the new wallet.
		TopUpTX = big_test_node:sign_tx(Wallet, #{
			owner => Pub,
			target => big_util:decode(Address),
			quantity => ?BIG(100),
			reward => ?BIG(1)
			}),
		{ok, {{<<"200">>, _}, _, _, _, _}} =
			big_http:req(#{
				method => post,
				peer => big_test_node:peer_ip(main),
				path => "/tx",
				body => big_serialize:jsonify(big_serialize:tx_to_json_struct(TopUpTX))
			}),
		wait_until_receives_txs([TopUpTX]),
		big_test_node:mine(),
		wait_until_height(main, LocalHeight + 1),
		%% Send an unsigned transaction to be signed with the generated key.
		TX = (big_tx:new())#tx{reward = ?BIG(1), last_tx = TopUpTX#tx.id},
		UnsignedTXProps = [
			{<<"last_tx">>, <<>>},
			{<<"target">>, TX#tx.target},
			{<<"quantity">>, integer_to_binary(TX#tx.quantity)},
			{<<"data">>, TX#tx.data},
			{<<"reward">>, integer_to_binary(TX#tx.reward)},
			{<<"denomination">>, integer_to_binary(TopUpTX#tx.denomination)},
			{<<"wallet_access_code">>, WalletAccessCode}
		],
		{ok, {{<<"421">>, _}, _, _, _, _}} =
			big_http:req(#{
				method => post,
				peer => big_test_node:peer_ip(main),
				path => "/unsigned_tx",
				body => big_serialize:jsonify({UnsignedTXProps})
			}),
		application:set_env(bigfile, config,
				Config#config{ internal_api_secret = <<"correct_secret">> }),
		{ok, {{<<"421">>, _}, _, _, _, _}} =
			big_http:req(#{
				method => post,
				peer => big_test_node:peer_ip(main),
				path => "/unsigned_tx",
				headers => [{<<"X-Internal-Api-Secret">>, <<"incorrect_secret">>}],
				body => big_serialize:jsonify({UnsignedTXProps})
			}),
		{ok, {{<<"200">>, <<"OK">>}, _, Body, _, _}} =
			big_http:req(#{
				method => post,
				peer => big_test_node:peer_ip(main),
				path => "/unsigned_tx",
				headers => [{<<"X-Internal-Api-Secret">>, <<"correct_secret">>}],
				body => big_serialize:jsonify({UnsignedTXProps})
			}),
		application:set_env(bigfile, config, Config#config{ internal_api_secret = not_set }),
		{Res} = big_serialize:dejsonify(Body),
		TXID = proplists:get_value(<<"id">>, Res),
		timer:sleep(200),
		big_test_node:mine(),
		wait_until_height(main, LocalHeight + 2),
		timer:sleep(200),
		{ok, {{<<"200">>, <<"OK">>}, _, GetTXBody, _, _}} =
			big_http:req(#{
				method => get,
				peer => big_test_node:peer_ip(main),
				path => "/tx/" ++ binary_to_list(TXID) ++ "/status"
			}),
		{GetTXRes} = big_serialize:dejsonify(GetTXBody),
		?assertMatch(
			#{
				<<"number_of_confirmations">> := 1
			},
			maps:from_list(GetTXRes)
		)
	after
		ok = application:set_env(bigfile, config, Config)
	end.

%% @doc Ensure the HTTP client stops fetching data from an endpoint when its data size
%% limit is exceeded.
test_get_error_of_data_limit(_) ->
	LocalHeight = big_node:get_height(),
	Limit = 1460,
	TX = big_tx:new(<< <<0>> || _ <- lists:seq(1, Limit * 2) >>),
	big_http_iface_client:send_tx_binary(big_test_node:peer_ip(main), TX#tx.id,
			big_serialize:tx_to_binary(TX)),
	wait_until_receives_txs([TX]),
	big_test_node:mine(),
	wait_until_height(main, LocalHeight + 1),
	{ok, _} = wait_until_syncs_tx_data(TX#tx.id),
	Resp =
		big_http:req(#{
			method => get,
			peer => big_test_node:peer_ip(main),
			path => "/tx/" ++ binary_to_list(big_util:encode(TX#tx.id)) ++ "/data",
			limit => Limit
		}),
	?assertEqual({error, too_much_data}, Resp).

test_send_missing_tx_with_the_block({_B0, Wallet1, _Wallet2, _StaticWallet}) ->
	LocalHeight = big_node:get_height(),
	RemoteHeight = height(peer1),
	big_test_node:disconnect_from(peer1),
	TXs = [big_test_node:sign_tx(Wallet1, #{ last_tx => big_test_node:get_tx_anchor(peer1) }) || _ <- lists:seq(1, 10)],
	lists:foreach(fun(TX) -> big_test_node:assert_post_tx_to_peer(main, TX) end, TXs),
	EverySecondTX = element(2, lists:foldl(fun(TX, {N, Acc}) when N rem 2 /= 0 ->
			{N + 1, [TX | Acc]}; (_TX, {N, Acc}) -> {N + 1, Acc} end, {0, []}, TXs)),
	lists:foreach(fun(TX) -> big_test_node:assert_post_tx_to_peer(peer1, TX) end, EverySecondTX),
	big_test_node:mine(),
	BI = wait_until_height(main, LocalHeight + 1),
	B = big_storage:read_block(hd(BI)),
	B2 = B#block{ txs = big_storage:read_tx(B#block.txs) },
	big_test_node:connect_to_peer(peer1),
	big_bridge ! {event, block, {new, B2, #{ recall_byte => undefined }}},
	assert_wait_until_height(peer1, RemoteHeight + 1).

test_fallback_to_block_endpoint_if_cannot_send_tx({_B0, Wallet1, _Wallet2, _StaticWallet}) ->
	LocalHeight = big_node:get_height(),
	RemoteHeight = height(peer1),
	big_test_node:disconnect_from(peer1),
	TXs = [big_test_node:sign_tx(Wallet1, #{ last_tx => big_test_node:get_tx_anchor(peer1) }) || _ <- lists:seq(1, 10)],
	lists:foreach(fun(TX) -> big_test_node:assert_post_tx_to_peer(main, TX) end, TXs),
	EverySecondTX = element(2, lists:foldl(fun(TX, {N, Acc}) when N rem 2 /= 0 ->
			{N + 1, [TX | Acc]}; (_TX, {N, Acc}) -> {N + 1, Acc} end, {0, []}, TXs)),
	lists:foreach(fun(TX) -> big_test_node:assert_post_tx_to_peer(peer1, TX) end, EverySecondTX),
	big_test_node:mine(),
	BI = wait_until_height(main, LocalHeight + 1),
	B = big_storage:read_block(hd(BI)),
	big_test_node:connect_to_peer(peer1),
	big_bridge ! {event, block, {new, B, #{ recall_byte => undefined }}},
	assert_wait_until_height(peer1, RemoteHeight + 1).

test_get_recent_hash_list_diff({_B0, Wallet1, _Wallet2, _StaticWallet}) ->
	LocalHeight = big_node:get_height(),
	BTip = big_node:get_current_block(),
	big_test_node:disconnect_from(peer1),
	{ok, {{<<"404">>, _}, _, <<>>, _, _}} = big_http:req(#{ method => get,
		peer => big_test_node:peer_ip(main), path => "/recent_hash_list_diff",
		headers => [], body => <<>> }),
	{ok, {{<<"400">>, _}, _, <<>>, _, _}} = big_http:req(#{ method => get,
		peer => big_test_node:peer_ip(main), path => "/recent_hash_list_diff",
		headers => [], body => crypto:strong_rand_bytes(47) }),
	{ok, {{<<"404">>, _}, _, <<>>, _, _}} = big_http:req(#{ method => get,
		peer => big_test_node:peer_ip(main), path => "/recent_hash_list_diff",
		headers => [], body => crypto:strong_rand_bytes(48) }),
	B0H = BTip#block.indep_hash,
	{ok, {{<<"200">>, _}, _, B0H, _, _}} = big_http:req(#{ method => get,
		peer => big_test_node:peer_ip(main), path => "/recent_hash_list_diff",
		headers => [], body => B0H }),
	big_test_node:mine(),
	BI1 = wait_until_height(main, LocalHeight + 1),
	{B1H, _, _} = hd(BI1),
	{ok, {{<<"200">>, _}, _, << B0H:48/binary, B1H:48/binary, 0:16 >> , _, _}} =
		big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
				path => "/recent_hash_list_diff", headers => [], body => B0H }),
	TXs = [big_test_node:sign_tx(main, Wallet1, #{ last_tx => big_test_node:get_tx_anchor(peer1) }) || _ <- lists:seq(1, 3)],
	lists:foreach(fun(TX) -> big_test_node:assert_post_tx_to_peer(main, TX) end, TXs),
	big_test_node:mine(),
	BI2 = wait_until_height(main, LocalHeight + 2),
	{B2H, _, _} = hd(BI2),
	[TXID1, TXID2, TXID3] = [TX#tx.id || TX <- (big_node:get_current_block())#block.txs],
	{ok, {{<<"200">>, _}, _, << B0H:48/binary, B1H:48/binary, 0:16, B2H:48/binary,
			3:16, TXID1:32/binary, TXID2:32/binary, TXID3/binary >> , _, _}}
			= big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
			path => "/recent_hash_list_diff", headers => [], body => B0H }),
	{ok, {{<<"200">>, _}, _, << B0H:48/binary, B1H:48/binary, 0:16, B2H:48/binary,
			3:16, TXID1:32/binary, TXID2:32/binary, TXID3/binary >> , _, _}}
			= big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
			path => "/recent_hash_list_diff", headers => [],
			body => << B0H/binary, (crypto:strong_rand_bytes(48))/binary >>}),
	{ok, {{<<"200">>, _}, _, << B1H:48/binary, B2H:48/binary,
			3:16, TXID1:32/binary, TXID2:32/binary, TXID3/binary >> , _, _}}
			= big_http:req(#{ method => get, peer => big_test_node:peer_ip(main),
			path => "/recent_hash_list_diff", headers => [],
			body => << B0H/binary, B1H/binary, (crypto:strong_rand_bytes(48))/binary >>}).

test_get_total_supply(_Args) ->
	BlockDenomination = (big_node:get_current_block())#block.denomination,
	TotalSupply =
		big_patricia_tree:foldr(
			fun	(_, {B, _}, Acc) ->
					Acc + big_pricing:redenominate(B, 1, BlockDenomination);
				(_, {B, _, Denomination, _}, Acc) ->
					Acc + big_pricing:redenominate(B, Denomination, BlockDenomination)
			end,
			0,
			big_diff_dag:get_sink(sys:get_state(big_wallets))
		),
	TotalSupplyBin = integer_to_binary(TotalSupply),
	?assertMatch({ok, {{<<"200">>, _}, _, TotalSupplyBin, _, _}},
			big_http:req(#{ method => get, peer => big_test_node:peer_ip(main), path => "/total_supply" })).

wait_until_syncs_tx_data(TXID) ->
	big_util:do_until(
		fun() ->
			case big_http:req(#{
				method => get,
				peer => big_test_node:peer_ip(main),
				path => "/tx/" ++ binary_to_list(big_util:encode(TXID)) ++ "/data"
			}) of
				{ok, {{<<"404">>, _}, _, _, _, _}} ->
					false;
				{ok, {{<<"200">>, _}, _, <<>>, _, _}} ->
					false;
				{ok, {{<<"200">>, _}, _, Payload, _, _}} ->
					{ok, Payload}
			end
		end,
		100,
		5000
	).

height(Node) ->
	big_test_node:remote_call(Node, big_node, get_height, []).
