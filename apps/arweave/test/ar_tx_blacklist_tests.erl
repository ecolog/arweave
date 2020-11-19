-module(ar_tx_blacklist_tests).

-export([init/2]).

-include_lib("eunit/include/eunit.hrl").

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").

-import(ar_test_node, [
	slave_start/1, start/3, connect_to_slave/0,
	get_tx_anchor/1,
	sign_tx/2,
	slave_call/3,
	assert_post_tx_to_slave/1,
	slave_mine/0,
	wait_until_height/1,
	get_chunk/1, get_chunk/2, post_chunk/1
]).

init(Req, State) ->
	SplitPath = ar_http_iface_server:split_path(cowboy_req:path(Req)),
	handle(SplitPath, Req, State).

handle([<<"empty">>], Req, State) ->
	{ok, cowboy_req:reply(200, #{}, <<>>, Req), State};

handle([<<"good">>], Req, State) ->
	{ok, cowboy_req:reply(200, #{}, ar_util:encode(hd(State)), Req), State};

handle([<<"bad">>, <<"and">>, <<"good">>], Req, State) ->
	Reply =
		list_to_binary(
			io_lib:format(
				"~s\nbad base64url \n~s\n",
				lists:map(fun ar_util:encode/1, State)
			)
		),
	{ok, cowboy_req:reply(200, #{}, Reply, Req), State}.

uses_blacklists_test_() ->
	{timeout, 120, fun test_uses_blacklists/0}.

test_uses_blacklists() ->
	{
		BlacklistFiles,
		B0,
		_SlaveNode,
		TXs,
		GoodTXIDs,
		BadTXIDs,
		GoodOffsets,
		BadOffsets
	} = setup(),
	WhitelistFile = random_filename(),
	ok = file:write_file(WhitelistFile, <<>>),
	{_, _} =
		start(B0, unclaimed, (element(2, application:get_env(arweave, config)))#config{
			transaction_blacklist_files = BlacklistFiles,
			transaction_whitelist_files = [WhitelistFile],
			transaction_blacklist_urls = [
				%% Serves empty body.
				"http://localhost:1985/empty",
				%% Serves a valid TX ID (one from the BadTXIDs list).
				"http://localhost:1985/good",
				%% Serves some valid TX IDs (from the BadTXIDs list) and a line
				%% with invalid Base64URL.
				"http://localhost:1985/bad/and/good"
			]
		}),
	connect_to_slave(),
	lists:foreach(
		fun({TX, Height}) ->
			assert_post_tx_to_slave(TX),
			slave_mine(),
			wait_until_height(Height)
		end,
		lists:zip(TXs, lists:seq(1, length(TXs)))
	),
	assert_present_txs(GoodTXIDs),
	assert_removed_txs(BadTXIDs),
	assert_present_offsets(GoodOffsets),
	assert_removed_offsets(BadOffsets),
	%% Add a new transaction to the blacklist, add a blacklisted transaction to whitelist.
	ok = file:write_file(WhitelistFile, ar_util:encode(lists:nth(2, BadTXIDs))),
	%% Reseting the contents of the files does not remove the corresponding txs from blacklist.
	ok = file:write_file(lists:nth(2, BlacklistFiles), <<>>),
	ok = file:write_file(lists:nth(3, BlacklistFiles), <<>>),
	ok = file:write_file(lists:nth(4, BlacklistFiles), ar_util:encode(hd(GoodTXIDs))),
	[UnblacklistedOffsets, WhitelistOffsets | BadOffsets2] = BadOffsets,
	RestoredOffsets = [UnblacklistedOffsets, WhitelistOffsets],
	[_UnblacklistedTXID, _WhitelistTXID | BadTXIDs2] = BadTXIDs,
	%% Expect the transaction data to be resynced.
	assert_present_offsets(RestoredOffsets),
	%% Expect the freshly blacklisted transaction to be erased.
	assert_removed_txs([hd(GoodTXIDs)]),
	assert_removed_offsets([hd(GoodOffsets)]),
	%% Expect the previously blacklisted transactions to stay blacklisted.
	assert_removed_txs(BadTXIDs2),
	assert_removed_offsets(BadOffsets2),
	teardown().

setup() ->
	{B0, Wallet, Node} = setup_slave(),
	TXs = create_txs(Wallet),
	TXIDs = [TX#tx.id || TX <- TXs],
	BadTXIDs = [lists:nth(1, TXIDs), lists:nth(3, TXIDs)],
	BlacklistFiles = create_files(BadTXIDs),
	BadTXIDs2 = [lists:nth(5, TXIDs), lists:nth(7, TXIDs)],
	Routes = [{"/[...]", ar_tx_blacklist_tests, BadTXIDs2}],
	{ok, _PID} =
		slave_call(cowboy, start_clear, [
			ar_tx_blacklist_test_listener,
			[{port, 1985}],
			#{ env => #{ dispatch => cowboy_router:compile([{'_', Routes}]) } }
		]),
	GoodTXIDs = TXIDs -- (BadTXIDs ++ BadTXIDs2),
	DataSizes = [TX#tx.data_size || TX <- TXs],
	[S1, S2, S3, S4, S5, S6, S7, S8 | _] = DataSizes,
	BadOffsets = [S1, S1 + S2 + S3, S1 + S2 + S3 + S4 + S5, S1 + S2 + S3 + S4 + S5 + S6 + S7],
	GoodOffsets = [
		S1 + S2, S1 + S2 + S3 + S4, S1 + S2 + S3 + S4 + S5 + S6,
		S1 + S2 + S3 + S4 + S5 + S6 + S7 + S8
	],
	{
		BlacklistFiles,
		B0,
		Node,
		TXs,
		GoodTXIDs,
		BadTXIDs ++ BadTXIDs2,
		GoodOffsets,
		BadOffsets
	}.

setup_slave() ->
	Wallet = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(200), <<>>}]),
	{Node, _} = slave_start(B0),
	{B0, Wallet, Node}.

create_txs(Wallet) ->
	lists:map(
		fun
			(_) ->
				sign_tx(
					Wallet,
					#{
						last_tx => get_tx_anchor(slave),
						data => crypto:strong_rand_bytes(100 * 1024)
					}
				)
		end,
		lists:seq(1, 10)
	).

create_files(BadTXIDs) ->
	Files = [
		{random_filename(), <<>>},
		{random_filename(), <<"bad base64url ">>},
		{random_filename(), ar_util:encode(hd(BadTXIDs))},
		{random_filename(),
			list_to_binary(
				io_lib:format(
					"~s\nbad base64url \n~s\n",
					lists:map(fun ar_util:encode/1, BadTXIDs)
				)
			)}
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
	filename:join(
		slave_call(ar_meta_db, get, [data_dir]),
		"ar-tx-blacklist-tests-transaction-blacklist-"
		++
		binary_to_list(ar_util:encode(crypto:strong_rand_bytes(32)))
	).

assert_present_txs(GoodTXIDs) ->
	true = ar_util:do_until(
		fun() ->
			lists:all(
				fun(TXID) ->
					is_record(ar_storage:read_tx(TXID), tx)
				end,
				GoodTXIDs
			)
		end,
		500,
		10000
	).

assert_removed_txs(BadTXIDs) ->
	true = ar_util:do_until(
		fun() ->
			lists:all(
				fun(TXID) ->
					unavailable == ar_storage:read_tx(TXID)
				end,
				BadTXIDs
			)
		end,
		500,
		5000
	).

assert_present_offsets(GoodOffsets) ->
	true = ar_util:do_until(
		fun() ->
			lists:all(
				fun(Offset) ->
					case get_chunk(Offset) of
						{ok, {{<<"200">>, _}, _, _, _, _}} ->
							true;
						_ ->
							false
					end
				end,
				GoodOffsets
			)
		end,
		500,
		10000
	).

assert_removed_offsets(BadOffsets) ->
	true = ar_util:do_until(
		fun() ->
			lists:all(
				fun(Offset) ->
					case get_chunk(Offset) of
						{ok, {{<<"404">>, _}, _, _, _, _}} ->
							{ok, {{<<"200">>, _}, _, EncodedProof, _, _}} =
								get_chunk(slave, Offset),
							Proof = decode_chunk(EncodedProof),
							{ok, DataRoot} = ar_merkle:extract_root(maps:get(data_path, Proof)),
							Proof2 = Proof#{
								offset => Offset - 1,
								data_root => DataRoot,
								data_size => byte_size(maps:get(chunk, Proof))
							},
							EncodedProof2 = encode_chunk(Proof2),
							%% The node returns 200 but does not store the chunk.
							case post_chunk(EncodedProof2) of
								{ok, {{<<"200">>, _}, _, _, _, _}} ->
									case get_chunk(Offset) of
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
				BadOffsets
			)
		end,
		500,
		10000
	).

decode_chunk(EncodedProof) ->
	ar_serialize:json_map_to_chunk_proof(
		jiffy:decode(EncodedProof, [return_maps])
	).

encode_chunk(Proof) ->
	ar_serialize:jsonify(#{
		chunk => ar_util:encode(maps:get(chunk, Proof)),
		data_path => ar_util:encode(maps:get(data_path, Proof)),
		data_root => ar_util:encode(maps:get(data_root, Proof)),
		data_size => integer_to_binary(maps:get(data_size, Proof)),
		offset => integer_to_binary(maps:get(data_size, Proof))
	}).

teardown() ->
	{ok, Config} = application:get_env(arweave, config),
	ok = slave_call(cowboy, stop_listener, [ar_tx_blacklist_test_listener]),
	application:set_env(arweave, config, Config#config{
		transaction_blacklist_files = [],
		transaction_blacklist_urls = [],
		transaction_whitelist_files = []
	}).
