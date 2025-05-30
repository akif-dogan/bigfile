-module(big_tx_blacklist_tests).

-export([init/2]).

-include_lib("eunit/include/eunit.hrl").

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_config.hrl").

-import(big_test_node, [
		sign_v1_tx/2, random_v1_data/1, 
		wait_until_height/2,
		assert_wait_until_height/2]).

init(Req, State) ->
	SplitPath = big_http_iface_server:split_path(cowboy_req:path(Req)),
	handle(SplitPath, Req, State).

handle([<<"empty">>], Req, State) ->
	{ok, cowboy_req:reply(200, #{}, <<>>, Req), State};

handle([<<"good">>], Req, State) ->
	{ok, cowboy_req:reply(200, #{}, big_util:encode(hd(State)), Req), State};

handle([<<"bad">>, <<"and">>, <<"good">>], Req, State) ->
	Reply =
		list_to_binary(
			io_lib:format(
				"~s\nbad base64url \n~s\n",
				lists:map(fun big_util:encode/1, State)
			)
		),
	{ok, cowboy_req:reply(200, #{}, Reply, Req), State}.

uses_blacklists_test_() ->
	{timeout, 300, fun test_uses_blacklists/0}.

test_uses_blacklists() ->
	{
		BlacklistFiles,
		B0,
		Wallet,
		TXs,
		GoodTXIDs,
		BadTXIDs,
		V1TX,
		GoodOffsets,
		BadOffsets,
		DataTrees
	} = setup(),
	WhitelistFile = random_filename(),
	ok = file:write_file(WhitelistFile, <<>>),
	RewardAddr = big_wallet:to_address(big_wallet:new_keyfile()),
	{ok, Config} = application:get_env(bigfile, config),
	try
		big_test_node:start(#{ b0 => B0, addr => RewardAddr,
				config => Config#config{
			transaction_blacklist_files = BlacklistFiles,
			transaction_whitelist_files = [WhitelistFile],
			sync_jobs = 10,
			transaction_blacklist_urls = [
				%% Serves empty body.
				"http://localhost:1985/empty",
				%% Serves a valid TX ID (one from the BadTXIDs list).
				"http://localhost:1985/good",
				%% Serves some valid TX IDs (from the BadTXIDs list) and a line
				%% with invalid Base64URL.
				"http://localhost:1985/bad/and/good"
			],
			enable = [pack_served_chunks | Config#config.enable]},
			storage_modules => [{30 * 1024 * 1024, 0, {composite, RewardAddr, 1}}]
		}),
		big_test_node:connect_to_peer(peer1),
		BadV1TXIDs = [V1TX#tx.id],
		lists:foreach(
			fun({TX, Height}) ->
				big_test_node:assert_post_tx_to_peer(peer1, TX),
				big_test_node:assert_wait_until_receives_txs([TX]),
				case Height == length(TXs) of
					true ->
						big_test_node:assert_post_tx_to_peer(peer1, V1TX),
						big_test_node:assert_wait_until_receives_txs([V1TX]);
					_ ->
						ok
				end,
				big_test_node:mine(peer1),
				upload_data([TX], DataTrees),
				wait_until_height(main, Height)
			end,
			lists:zip(TXs, lists:seq(1, length(TXs)))
		),
		assert_present_txs(GoodTXIDs),
		assert_present_txs(BadTXIDs), % V2 headers must not be removed.
		assert_removed_txs(BadV1TXIDs),
		assert_present_offsets(GoodOffsets),
		assert_removed_offsets(BadOffsets),
		assert_does_not_accept_offsets(BadOffsets),
		%% Add a new transaction to the blacklist, add a blacklisted transaction to whitelist.
		ok = file:write_file(lists:nth(3, BlacklistFiles), <<>>),
		ok = file:write_file(WhitelistFile, big_util:encode(lists:nth(2, BadTXIDs))),
		ok = file:write_file(lists:nth(4, BlacklistFiles), io_lib:format("~s~n~s",
				[big_util:encode(hd(GoodTXIDs)), big_util:encode(V1TX#tx.id)])),
		[UnblacklistedOffsets, WhitelistOffsets | BadOffsets2] = BadOffsets,
		RestoredOffsets = [UnblacklistedOffsets, WhitelistOffsets] ++
				[lists:nth(6, lists:reverse(BadOffsets))],
		BadOffsets3 = BadOffsets2 -- [lists:nth(6, lists:reverse(BadOffsets))],
		[_UnblacklistedTXID, _WhitelistTXID | BadTXIDs2] = BadTXIDs,
		%% Expect the transaction data to be resynced.
		assert_present_offsets(RestoredOffsets),
		%% Expect the freshly blacklisted transaction to be erased.
		assert_present_txs([hd(GoodTXIDs)]), % V2 headers must not be removed.
		assert_removed_offsets([hd(GoodOffsets)]),
		assert_does_not_accept_offsets([hd(GoodOffsets)]),
		%% Expect the previously blacklisted transactions to stay blacklisted.
		assert_present_txs(BadTXIDs2), % V2 headers must not be removed.
		assert_removed_txs(BadV1TXIDs),
		assert_removed_offsets(BadOffsets3),
		assert_does_not_accept_offsets(BadOffsets3),
		%% Blacklist the last transaction. Fork the weave. Assert the blacklisted offsets are moved.
		big_test_node:disconnect_from(peer1),
		TX = big_test_node:sign_tx(Wallet, #{ data => crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
				last_tx => big_test_node:get_tx_anchor(peer1) }),
		big_test_node:assert_post_tx_to_peer(main, TX),
		big_test_node:mine(),
		[{_, WeaveSize, _} | _] = wait_until_height(main, length(TXs) + 1),
		assert_present_offsets([[WeaveSize]]),
		ok = file:write_file(lists:nth(3, BlacklistFiles), big_util:encode(TX#tx.id)),
		assert_removed_offsets([[WeaveSize]]),
		TX2 = sign_v1_tx(Wallet, #{ data => random_v1_data(2 * ?DATA_CHUNK_SIZE),
				last_tx => big_test_node:get_tx_anchor(peer1) }),
		big_test_node:assert_post_tx_to_peer(peer1, TX2),
		big_test_node:mine(peer1),
		assert_wait_until_height(peer1, length(TXs) + 1),
		big_test_node:assert_post_tx_to_peer(peer1, TX),
		big_test_node:mine(peer1),
		assert_wait_until_height(peer1, length(TXs) + 2),
		big_test_node:connect_to_peer(peer1),
		[{_, WeaveSize2, _} | _] = wait_until_height(main, length(TXs) + 2),
		assert_removed_offsets([[WeaveSize2]]),
		assert_present_offsets([[WeaveSize]])
	after
		teardown(Config)
	end.

setup() ->
	{B0, Wallet} = setup(peer1),
	{TXs, DataTrees} = create_txs(Wallet),
	TXIDs = [TX#tx.id || TX <- TXs],
	BadTXIDs = [lists:nth(1, TXIDs), lists:nth(3, TXIDs)],
	V1TX = sign_v1_tx(Wallet, #{ data => random_v1_data(3 * ?DATA_CHUNK_SIZE),
			last_tx => big_test_node:get_tx_anchor(peer1), reward => ?BIG(10000) }),
	DataSizes = [TX#tx.data_size || TX <- TXs],
	S0 = B0#block.block_size,
	[S1, S2, S3, S4, S5, S6, S7, S8 | _] = DataSizes,
	BadOffsets = [S0 + O || O <- [S1, S1 + S2 + S3, % Blacklisted in the file.
			S1 + S2 + S3 + S4 + S5,
			S1 + S2 + S3 + S4 + S5 + S6 + S7]], % Blacklisted in the endpoint.
	BlacklistFiles = create_files([V1TX#tx.id | BadTXIDs],
			[{S0 + S1 + S2 + S3 + ?DATA_CHUNK_SIZE, S0 + S1 + S2 + S3 + ?DATA_CHUNK_SIZE * 2},
				{S0 + S1 + S2 + S3 + S4 + S5,
						S0 + S1 + S2 + S3 + S4 + S5 + ?DATA_CHUNK_SIZE * 5},
				% This one just repeats the range of a blacklisted tx:
				{S0 + S1 + S2 + S3 + S4 + S5 + S6, S0 + S1 + S2 + S3 + S4 + S5 + S6 + S7}
			]),
	BadTXIDs2 = [lists:nth(5, TXIDs), lists:nth(7, TXIDs)], % The endpoint.
	BadTXIDs3 = [lists:nth(4, TXIDs), lists:nth(6, TXIDs)], % Ranges.
	Routes = [{"/[...]", big_tx_blacklist_tests, BadTXIDs2}],
	{ok, _PID} =
		big_test_node:remote_call(peer1, cowboy, start_clear, [
			big_tx_blacklist_test_listener,
			[{port, 1985}],
			#{ env => #{ dispatch => cowboy_router:compile([{'_', Routes}]) } }
		]),
	GoodTXIDs = TXIDs -- (BadTXIDs ++ BadTXIDs2 ++ BadTXIDs3),
	BadOffsets2 =
		lists:map(
			fun(TXOffset) ->
				%% Every TX in this test consists of 10 chunks.
				%% Only every second chunk is uploaded in this test
				%% for (originally) blacklisted transactions.
				[TXOffset - ?DATA_CHUNK_SIZE * I || I <- lists:seq(0, 9, 2)]
			end,
			BadOffsets
		),
	BadOffsets3 = BadOffsets2 ++ [S0 + O || O <- [S1 + S2 + S3 + ?DATA_CHUNK_SIZE * 2,
			S1 + S2 + S3 + S4 + S5 + ?DATA_CHUNK_SIZE,
			S1 + S2 + S3 + S4 + S5 + ?DATA_CHUNK_SIZE * 2,
			S1 + S2 + S3 + S4 + S5 + ?DATA_CHUNK_SIZE * 3,
			S1 + S2 + S3 + S4 + S5 + ?DATA_CHUNK_SIZE * 4,
			S1 + S2 + S3 + S4 + S5 + ?DATA_CHUNK_SIZE * 5]], % Blacklisted as a range.
	GoodOffsets = [S0 + O || O <- [S1 + S2, S1 + S2 + S3 + S4, S1 + S2 + S3 + S4 + S5 + S6,
			S1 + S2 + S3 + S4 + S5 + S6 + S7 + S8]],
	GoodOffsets2 =
		lists:map(
			fun(TXOffset) ->
				%% Every TX in this test consists of 10 chunks.
				[TXOffset - ?DATA_CHUNK_SIZE * I || I <- lists:seq(0, 9)] -- BadOffsets3
			end,
			GoodOffsets
		),
	{
		BlacklistFiles,
		B0,
		Wallet,
		TXs,
		GoodTXIDs,
		BadTXIDs ++ BadTXIDs2 ++ BadTXIDs3,
		V1TX,
		GoodOffsets2,
		BadOffsets3,
		DataTrees
	}.

setup(Node) ->
	{ok, Config} = big_test_node:get_config(Node),
	Wallet = {_, Pub} = big_test_node:remote_call(Node, big_wallet, new_keyfile, []),
	RewardAddr = big_wallet:to_address(Pub),
	[B0] = big_weave:init([{RewardAddr, ?BIG(100000000), <<>>}]),
	big_test_node:start_peer(Node, B0, RewardAddr, Config#config{
		enable = [pack_served_chunks | Config#config.enable]
	}),
	{B0, Wallet}.

create_txs(Wallet) ->
	lists:foldl(
		fun
			(_, {TXs, DataTrees}) ->
				Chunks =
					lists:sublist(
						big_tx:chunk_binary(?DATA_CHUNK_SIZE,
								crypto:strong_rand_bytes(10 * ?DATA_CHUNK_SIZE)),
						10
					), % Exclude empty chunk created by chunk_to_binary.
				SizedChunkIDs = big_tx:sized_chunks_to_sized_chunk_ids(
					big_tx:chunks_to_size_tagged_chunks(Chunks)
				),
				{DataRoot, DataTree} = big_merkle:generate_tree(SizedChunkIDs),
				TX = big_test_node:sign_tx(Wallet, #{ format => 2, data_root => DataRoot,
						data_size => 10 * ?DATA_CHUNK_SIZE, last_tx => big_test_node:get_tx_anchor(peer1),
						reward => ?BIG(10000), denomination => 1 }),
				{[TX | TXs], maps:put(TX#tx.id, {DataTree, Chunks}, DataTrees)}
		end,
		{[], #{}},
		lists:seq(1, 10)
	).

create_files(BadTXIDs, [{Start1, End1}, {Start2, End2}, {Start3, End3}]) ->
	Files = [
		{random_filename(), <<>>},
		{random_filename(), <<"bad base64url ">>},
		{random_filename(), big_util:encode(lists:nth(2, BadTXIDs))},
		{random_filename(),
			list_to_binary(
				io_lib:format(
					"~s\nbad base64url \n~s\n~s\n~B,~B\n",
					lists:map(fun big_util:encode/1, BadTXIDs) ++ [Start1, End1]
				)
			)},
		{random_filename(), list_to_binary(io_lib:format("~B,~B\n~B,~B",
				[Start2, End2, Start3, End3]))}
	],
	lists:foreach(
		fun
			({Filename, Binary}) ->
				ok = file:write_file(Filename, Binary)
		end,
		Files
	),
	[Filename || {Filename, _} <- Files].

random_filename() ->
	{ok, Config} = big_test_node:remote_call(peer1, application, get_env, [bigfile, config]),
	filename:join(Config#config.data_dir,
		"big-tx-blacklist-tests-transaction-blacklist-"
		++
		binary_to_list(big_util:encode(crypto:strong_rand_bytes(32)))).

encode_chunk(Proof) ->
	big_serialize:jsonify(#{
		chunk => big_util:encode(maps:get(chunk, Proof)),
		data_path => big_util:encode(maps:get(data_path, Proof)),
		data_root => big_util:encode(maps:get(data_root, Proof)),
		data_size => integer_to_binary(maps:get(data_size, Proof)),
		offset => integer_to_binary(maps:get(offset, Proof))
	}).

upload_data(TXs, DataTrees) ->
	lists:foreach(
		fun(TX) ->
			#tx{
				id = TXID,
				data_root = DataRoot,
				data_size = DataSize
			} = TX,
			{DataTree, Chunks} = maps:get(TXID, DataTrees),
			ChunkOffsets = lists:zip(Chunks,
					lists:seq(?DATA_CHUNK_SIZE, 10 * ?DATA_CHUNK_SIZE, ?DATA_CHUNK_SIZE)),
			UploadChunks = ChunkOffsets,
			lists:foreach(
				fun({Chunk, Offset}) ->
					DataPath = big_merkle:generate_path(DataRoot, Offset - 1, DataTree),
					{ok, {{<<"200">>, _}, _, _, _, _}} =
						big_test_node:post_chunk(peer1, encode_chunk(#{
							data_root => DataRoot,
							chunk => Chunk,
							data_path => DataPath,
							offset => Offset - 1,
							data_size => DataSize
						}))
				end,
				UploadChunks
			)
		end,
		TXs
	).

assert_present_txs(GoodTXIDs) ->
	?debugFmt("Waiting until these txids are stored: ~p.",
			[[big_util:encode(TXID) || TXID <- GoodTXIDs]]),
	true = big_util:do_until(
		fun() ->
			lists:all(
				fun(TXID) ->
					is_record(big_storage:read_tx(TXID), tx)
				end,
				GoodTXIDs
			)
		end,
		500,
		10000
	),
	lists:foreach(
		fun(TXID) ->
			?assertMatch({ok, {_, _}}, big_storage:get_tx_confirmation_data(TXID))
		end,
		GoodTXIDs
	).

assert_removed_txs(BadTXIDs) ->
	?debugFmt("Waiting until these txids are removed: ~p.",
			[[big_util:encode(TXID) || TXID <- BadTXIDs]]),
	true = big_util:do_until(
		fun() ->
			lists:all(
				fun(TXID) ->
					{error, not_found} == big_data_sync:get_tx_data(TXID)
							%% Do not use big_storage:read_tx because the
							%% transaction is temporarily kept in the disk cache,
							%% even when blacklisted.
							andalso big_kv:get(tx_db, TXID) == not_found
				end,
				BadTXIDs
			)
		end,
		500,
		30000
	),
	%% We have to keep the confirmation data even for blacklisted transactions.
	lists:foreach(
		fun(TXID) ->
			?assertMatch({ok, {_, _}}, big_storage:get_tx_confirmation_data(TXID))
		end,
		BadTXIDs
	).

assert_present_offsets(GoodOffsets) ->
	true = big_util:do_until(
		fun() ->
			lists:all(
				fun(Offset) ->
					case big_test_node:get_chunk(main, Offset) of
						{ok, {{<<"200">>, _}, _, _, _, _}} ->
							true;
						_ ->
							?debugFmt("Waiting until the end offset ~B is stored.", [Offset]),
							false
					end
				end,
				lists:flatten(GoodOffsets)
			)
		end,
		500,
		120000
	).

assert_removed_offsets(BadOffsets) ->
	true = big_util:do_until(
		fun() ->
			lists:all(
				fun(Offset) ->
					case big_test_node:get_chunk(main, Offset) of
						{ok, {{<<"404">>, _}, _, _, _, _}} ->
							true;
						_ ->
							?debugFmt("Waiting until the end offset ~B is removed.", [Offset]),
							false
					end
				end,
				lists:flatten(BadOffsets)
			)
		end,
		500,
		60000
	).

assert_does_not_accept_offsets(BadOffsets) ->
	true = big_util:do_until(
		fun() ->
			lists:all(
				fun(Offset) ->
					case big_test_node:get_chunk(main, Offset) of
						{ok, {{<<"404">>, _}, _, _, _, _}} ->
							{ok, {{<<"200">>, _}, _, EncodedProof, _, _}} =
								big_test_node:get_chunk(peer1, Offset),
							Proof = decode_chunk(EncodedProof),
							DataPath = maps:get(data_path, Proof),
							{ok, DataRoot} = big_merkle:extract_root(DataPath),
							RelativeOffset = big_merkle:extract_note(DataPath),
							Proof2 = Proof#{
								offset => RelativeOffset - 1,
								data_root => DataRoot,
								data_size => 10 * ?DATA_CHUNK_SIZE
							},
							EncodedProof2 = encode_chunk(Proof2),
							%% The node returns 200 but does not store the chunk.
							case big_test_node:post_chunk(main, EncodedProof2) of
								{ok, {{<<"200">>, _}, _, _, _, _}} ->
									case big_test_node:get_chunk(main, Offset) of
										{ok, {{<<"404">>, _}, _, _, _, _}} ->
											true;
										_ ->
											false
									end;
								_ ->
									false
							end;
						_ ->
							false
					end
				end,
				lists:flatten(BadOffsets)
			)
		end,
		500,
		60000
	).

decode_chunk(EncodedProof) ->
	big_serialize:json_map_to_poa_map(
		jiffy:decode(EncodedProof, [return_maps])
	).

teardown(Config) ->
	ok = big_test_node:remote_call(peer1, cowboy, stop_listener, [big_tx_blacklist_test_listener]),
	application:set_env(bigfile, config, Config).
