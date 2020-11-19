-module(ar_join).

-export([
	start/2,
	start/3,
	filter_peer_list/1
]).

-include_lib("arweave/include/ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% Represents a process that handles creating an initial, minimal
%%% block list to be used by a node joining a network already in progress.

%%% Define how many recent blocks should have syncing priority.
-define(DOWNLOAD_TOP_PRIORITY_BLOCKS_COUNT, 1000).

%% @doc Start a process that will attempt to join a network from the last
%% sync block.
start(Peers, NewB) when is_record(NewB, block) ->
	spawn(fun() -> start(self(), Peers, NewB) end);
start(Node, Peers) ->
	spawn(fun() -> start(Node, Peers, find_current_block(Peers)) end).

start(_, [], _) ->
	?LOG_INFO([not_joining, {reason, no_peers}]);
start(Node, Peers, B) when is_atom(B) ->
	?LOG_INFO(
		[
			could_not_retrieve_current_block,
			{trying_again_in, ?REJOIN_TIMEOUT, seconds}
		]
	),
	timer:apply_after(?REJOIN_TIMEOUT, ar_join, start, [Node, Peers]);
start(Node, RawPeers, {NewB, BI}) ->
	do_join(Node, RawPeers, NewB, BI).

%% @doc Perform the joining process.
do_join(_Node, _RawPeers, NewB, _BI) when not ?IS_BLOCK(NewB) ->
	?LOG_INFO([
		{event, node_not_joining},
		{reason, cannot_get_full_block_from_peer},
		{received_instead, NewB}
	]);
do_join(_Node, Peers, NewB, BI) ->
	?LOG_INFO("Joining the Arweave network..."),

	ar_arql_db:populate_db(?BI_TO_BHL(BI)),
	ar_randomx_state:init(BI, Peers),
	Blocks = get_block_and_trail(Peers, NewB, BI),
	ar_node ! {join, BI, Blocks},
	join_peers(Peers),

	?LOG_INFO("Joined the Arweave network successfully.").


%% @doc Return the current block from a list of peers.
find_current_block([]) ->
	?LOG_INFO("Did not manage to fetch current block from any of the peers. Will retry later."),
	unavailable;
find_current_block([Peer | Tail]) ->
	try ar_http_iface_client:get_block_index(Peer) of
		[] ->
			find_current_block(Tail);
		BI ->
			{Hash, _, _} = hd(BI),
			?LOG_INFO("Fetching current block. ~p ~p", [{peer, Peer},{hash, Hash}]),
			MaybeB = ar_http_iface_client:get_block([Peer], Hash),
			case MaybeB of
				Atom when is_atom(Atom) ->
					?LOG_ERROR("Failed to fetch block from peer. Will retry using a different one."),
					Atom;
				B ->
					{B, BI}
			end
	catch
		Exc:Reason ->
			Details = [{peer, Peer}, {exception, Exc}, {reason, Reason}],
			?LOG_ERROR("Failed to fetch block from peer. Will retry using a different one. ~p", [Details] ),
			find_current_block(Tail)
	end.

%% @doc Verify peers are on the same network as us and the clocks are in sync.
filter_peer_list(Peers) ->
	%SameNetworkPeers =
		lists:filter(
			fun(Peer) ->
				ar_http_iface_client:get_info(Peer, name) == <<?NETWORK_NAME>>
			end,
			Peers
		).
	%case verify_time_sync(SameNetworkPeers) of
	%	false ->
	%		[];
	%	true ->
	%		SameNetworkPeers
	%end.

join_peers(Peers) ->
	lists:foreach(
		fun(Peer) ->
			ar_http_iface_client:add_peer(Peer)
		end,
		Peers
	).

%% @doc Get a block, and its 2 * ?MAX_TX_ANCHOR_DEPTH previous blocks.
%% If the block list is shorter than 2 * ?MAX_TX_ANCHOR_DEPTH, simply
%% get all existing blocks.
%%
%% The node needs 2 * ?MAX_TX_ANCHOR_DEPTH block anchors so that it
%% can validate transactions even if it enters a ?MAX_TX_ANCHOR_DEPTH-deep
%% fork recovery (which is the deepest fork recovery possible) immediately after
%% joining the network.
get_block_and_trail(Peers, NewB, BI) ->
	get_block_and_trail(Peers, NewB, 2 * ?MAX_TX_ANCHOR_DEPTH, BI).

get_block_and_trail(_Peers, NewB, BehindCurrent, _BI)
		when NewB#block.height == 0 orelse BehindCurrent == 0 ->
	SizeTaggedTXs = ar_block:generate_size_tagged_list_from_txs(NewB#block.txs),
	[NewB#block{ size_tagged_txs = SizeTaggedTXs }];
get_block_and_trail(Peers, NewB, BehindCurrent, BI) ->
	PreviousBlock = ar_http_iface_client:get_block(
		Peers,
		NewB#block.previous_block
	),
	case ?IS_BLOCK(PreviousBlock) of
		true ->
			SizeTaggedTXs = ar_block:generate_size_tagged_list_from_txs(NewB#block.txs),
			[NewB#block{ size_tagged_txs = SizeTaggedTXs } |
				get_block_and_trail(Peers, PreviousBlock, BehindCurrent - 1, BI)];
		false ->
			?LOG_INFO(
				[
					could_not_retrieve_joining_block,
					retrying
				]
			),
			timer:sleep(3000),
			get_block_and_trail(Peers, NewB, BehindCurrent, BI)
	end.

%% @doc Check that nodes can join a running network by using the fork recoverer.
basic_node_join_test() ->
	{timeout, 60, fun() ->
		ar_storage:clear(),
		[B0] = ar_weave:init([]),
		ar_test_node:start(B0),
		ar_node:mine(),
		ar_test_node:wait_until_height(1),
		ar_node:mine(),
		ar_test_node:wait_until_height(2),
		ar_test_node:join_on_master(),
		ar_test_node:assert_slave_wait_until_height(2)
	end}.

%% @doc Ensure that both nodes can mine after a join.
node_join_test() ->
	{timeout, 60, fun() ->
		[B0] = ar_weave:init([]),
		ar_test_node:start(B0),
		ar_node:mine(),
		ar_test_node:wait_until_height(1),
		ar_node:mine(),
		ar_test_node:wait_until_height(2),
		ar_test_node:join_on_master(),
		ar_test_node:assert_slave_wait_until_height(2),
		ar_test_node:slave_mine(),
		ar_test_node:wait_until_height(3)
	end}.
