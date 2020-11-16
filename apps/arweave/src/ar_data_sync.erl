-module(ar_data_sync).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2]).
-export([terminate/2]).

-export([
	join/1,
	add_tip_block/2, add_block/2,
	add_chunk/1, add_chunk/2, add_chunk/3,
	add_data_root_to_disk_pool/3, maybe_drop_data_root_from_disk_pool/3,
	get_chunk/1, get_tx_root/1, get_tx_data/1, get_tx_offset/1,
	get_sync_record_etf/0, get_sync_record_json/0,
	request_tx_data_removal/1
]).

-include("ar.hrl").
-include("ar_data_sync.hrl").

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link(Args) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%% @doc Notify the server the node has joined the network on the given block index.
join(BI) ->
	gen_server:cast(?MODULE, {join, BI}).

%% @doc Notify the server about the new tip block.
add_tip_block(BlockTXPairs, RecentBI) ->
	gen_server:cast(?MODULE, {add_tip_block, BlockTXPairs, RecentBI}).

%% @doc Store the given chunk if the proof is valid.
add_chunk(Proof) ->
	add_chunk(Proof, 5000, do_not_write_to_free_space_buffer).

%% @doc Store the given chunk if the proof is valid.
add_chunk(Proof, Timeout) ->
	add_chunk(Proof, Timeout, do_not_write_to_free_space_buffer).

%% @doc Store the given chunk if the proof is valid.
add_chunk(
	#{
		data_root := DataRoot,
		offset := Offset,
		data_path := DataPath,
		chunk := Chunk,
		data_size := TXSize
	},
	Timeout,
	WriteToFreeSpaceBuffer
) ->
	Command = {add_chunk, DataRoot, DataPath, Chunk, Offset, TXSize, WriteToFreeSpaceBuffer},
	case catch gen_server:call(?MODULE, Command, Timeout) of
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Notify the server about the new pending data root (added to mempool).
%% The server may accept pending chunks and store them in the disk pool.
%% @end
add_data_root_to_disk_pool(<<>>, _, _) ->
	ok;
add_data_root_to_disk_pool(_, 0, _) ->
	ok;
add_data_root_to_disk_pool(DataRoot, TXSize, TXID) ->
	gen_server:cast(?MODULE, {add_data_root_to_disk_pool, {DataRoot, TXSize, TXID}}).

%% @doc Notify the server the given data root has been removed from the mempool.
maybe_drop_data_root_from_disk_pool(<<>>, _, _) ->
	ok;
maybe_drop_data_root_from_disk_pool(_, 0, _) ->
	ok;
maybe_drop_data_root_from_disk_pool(DataRoot, TXSize, TXID) ->
	gen_server:cast(?MODULE, {maybe_drop_data_root_from_disk_pool, {DataRoot, TXSize, TXID}}).

%% @doc Fetch the chunk containing the given global offset, including right bound,
%% excluding left bound.
get_chunk(Offset) ->
	case ets:lookup(?MODULE, chunks_index) of
		[] ->
			{error, not_joined};
		[{_, ChunksIndex}] ->
			[{_, ChunkDataIndex}] = ets:lookup(?MODULE, chunk_data_index),
			get_chunk(ChunksIndex, ChunkDataIndex, Offset)
	end.

get_chunk(ChunksIndex, ChunkDataIndex, Offset) ->
	case ar_kv:get_next(ChunksIndex, << Offset:?OFFSET_KEY_BITSIZE >>) of
		{error, _} ->
			{error, chunk_not_found};
		{ok, Key, Value} ->
			<< ChunkOffset:?OFFSET_KEY_BITSIZE >> = Key,
			{DataPathHash, TXRoot, _, TXPath, _, ChunkSize} = binary_to_term(Value),
			case ChunkOffset - Offset >= ChunkSize of
				true ->
					{error, chunk_not_found};
				false ->
					case read_chunk(ChunkDataIndex, DataPathHash) of
						{ok, {Chunk, DataPath}} ->
							Proof = #{
								tx_root => TXRoot,
								chunk => Chunk,
								data_path => DataPath,
								tx_path => TXPath
							},
							{ok, Proof};
						not_found ->
							{error, chunk_not_found};
						{error, Reason} ->
							ar:err([
								{event, failed_to_read_chunk},
								{reason, Reason}
							]),
							{error, failed_to_read_chunk}
					end
			end
	end.

%% @doc Fetch the transaction root containing the given global offset, including left bound,
%% excluding right bound.
get_tx_root(Offset) ->
	case ets:lookup(?MODULE, data_root_offset_index) of
		[] ->
			{error, not_joined};
		[{_, DataRootOffsetIndex}] ->
			get_tx_root(DataRootOffsetIndex, Offset)
	end.

get_tx_root(DataRootOffsetIndex, Offset) ->
	case ar_kv:get_prev(DataRootOffsetIndex, << Offset:?OFFSET_KEY_BITSIZE >>) of
		{error, _} ->
			{error, not_found};
		{ok, Key, Value} ->
			<< BlockStartOffset:?OFFSET_KEY_BITSIZE >> = Key,
			{TXRoot, BlockSize, _DataRootIndexKeySet} = binary_to_term(Value),
			{ok, TXRoot, BlockStartOffset, BlockSize}
	end.

%% @doc Fetch the transaction data.
get_tx_data(TXID) ->
	case ets:lookup(?MODULE, tx_index) of
		[] ->
			{error, not_joined};
		[{_, TXIndex}] ->
			[{_, ChunksIndex}] = ets:lookup(?MODULE, chunks_index),
			[{_, ChunkDataIndex}] = ets:lookup(?MODULE, chunk_data_index),
			get_tx_data(TXIndex, ChunksIndex, ChunkDataIndex, TXID)
	end.

get_tx_data(TXIndex, ChunksIndex, ChunkDataIndex, TXID) ->
	case ar_kv:get(TXIndex, TXID) of
		not_found ->
			{error, not_found};
		{error, Reason} ->
			ar:err([{event, failed_to_get_tx_data}, {reason, Reason}]),
			{error, failed_to_get_tx_data};
		{ok, Value} ->
			{Offset, Size} = binary_to_term(Value),
			case Size > ?MAX_SERVED_TX_DATA_SIZE of
				true ->
					{error, tx_data_too_big};
				false ->
					StartKey = << (Offset - Size):?OFFSET_KEY_BITSIZE >>,
					EndKey = << Offset:?OFFSET_KEY_BITSIZE >>,
					case ar_kv:get_range(ChunksIndex, StartKey, EndKey) of
						{error, Reason} ->
							ar:err([
								{event, failed_to_get_chunks_for_tx_data},
								{reason, Reason}
							]),
							{error, not_found};
						{ok, EmptyMap} when map_size(EmptyMap) == 0 ->
							{error, not_found};
						{ok, Map} ->
							get_tx_data_from_chunks(ChunkDataIndex, Offset, Size, Map)
					end
			end
	end.

%% @doc Return the global end offset and size for the given transaction.
get_tx_offset(TXID) ->
	case ets:lookup(?MODULE, tx_index) of
		[] ->
			{error, not_joined};
		[{_, TXIndex}] ->
			get_tx_offset(TXIndex, TXID)
	end.

get_tx_offset(TXIndex, TXID) ->
	case ar_kv:get(TXIndex, TXID) of
		{ok, Value} ->
			{ok, binary_to_term(Value)};
		not_found ->
			{error, not_found};
		{error, Reason} ->
			ar:err([{event, failed_to_read_tx_offset}, {reason, Reason}]),
			{error, failed_to_read_offset}
	end.

%% @doc Return a set of intervals of synced byte global offsets (with false positives), up
%% to ?MAX_SHARED_SYNCED_INTERVALS_COUNT intervals, serialized as Erlang Term Format.
get_sync_record_etf() ->
	case catch gen_server:call(?MODULE, get_sync_record_etf) of
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Return a set of intervals of synced byte global offsets (with false positives), up
%% to MAX_SHARED_SYNCED_INTERVALS_COUNT, serialized as JSON.
get_sync_record_json() ->
	case catch gen_server:call(?MODULE, get_sync_record_json) of
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Record the metadata of the given block.
add_block(B, SizeTaggedTXs) ->
	gen_server:cast(?MODULE, {add_block, B, SizeTaggedTXs}).

%% @doc Request the removal of the transaction data.
request_tx_data_removal(TXID) ->
	gen_server:cast(?MODULE, {remove_tx_data, TXID}).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	ar:info([{event, ar_data_sync_start}]),
	process_flag(trap_exit, true),
	State = init_kv(),
	{SyncRecord, CurrentBI, DiskPoolDataRoots, DiskPoolSize, WeaveSize, CompactedSize} =
		read_data_sync_state(),
	State2 = State#sync_data_state{
		sync_record = SyncRecord,
		peer_sync_records = #{},
		block_index = CurrentBI,
		weave_size = WeaveSize,
		disk_pool_data_roots = DiskPoolDataRoots,
		disk_pool_size = DiskPoolSize,
		disk_pool_cursor = first,
		missing_data_cursor = first,
		compacted_size = CompactedSize
	},
	gen_server:cast(self(), check_space_update_peer_sync_records),
	gen_server:cast(self(), check_space_sync_random_interval),
	gen_server:cast(self(), check_space_compact_intervals),
	gen_server:cast(self(), update_disk_pool_data_roots),
	gen_server:cast(self(), process_disk_pool_item),
	migrate_index(State#sync_data_state.migrations_index),
	record_v2_index_data_size(State2),
	{ok, State2}.

handle_cast({migrate, Key = <<"store_data_in_v2_index">>, Cursor}, State) ->
	#sync_data_state{
		chunks_index = ChunksIndex,
		chunk_data_index = ChunkDataIndex,
		migrations_index = MigrationsIndex
	} = State,
	{MigrateChunkResult, NextCursor} =
		case ar_kv:cyclic_iterator_move(ChunksIndex, Cursor) of
			none ->
				{ar_kv:put(MigrationsIndex, Key, <<"complete">>), none};
			{ok, ChunkKey, Value, NextCursor2} ->
				{DataPathHash, _, _, _, _, _} = binary_to_term(Value),
				Result =
					case ar_storage:read_chunk(DataPathHash) of
						{ok, ChunkData} ->
							ChunkDataValue = term_to_binary(ChunkData),
							case ar_kv:put(ChunkDataIndex, DataPathHash, ChunkDataValue) of
								ok ->
									ar_storage:delete_chunk(DataPathHash);
								Error ->
									Error
							end;
						not_found ->
							case ar_kv:get(ChunkDataIndex, DataPathHash) of
								not_found ->
									%% It may produce a false positive in the sync record,
									%% but the process is capable of handling false positives.
									ar_kv:delete(ChunksIndex, ChunkKey);
								{ok, _Value} ->
									ok;
								Error ->
									Error
							end;
						Error ->
							Error
					end,
				case Result of
					ok ->
						case NextCursor2 of
							first ->
								{ar_kv:put(MigrationsIndex, Key, <<"complete">>), none};
							{seek, NextCursor3} ->
								{ar_kv:put(MigrationsIndex, Key, NextCursor3), NextCursor2}
						end;
					Error2 ->
						Error2
				end;
			Error ->
				Error
		end,
	case {MigrateChunkResult, NextCursor} of
		{ok, none} ->
			ets:insert(?MODULE, {store_data_in_v2_index_completed}),
			ok;
		{ok, _} ->
			gen_server:cast(?MODULE, {migrate, Key, NextCursor});
		{{error, Reason}, _} ->
			ar:err([
				{event, ar_data_sync_migration_error},
				{key, Key},
				{reason, Reason},
				{cursor,
					case Cursor of first -> first; _ -> ar_util:encode(element(2, Cursor)) end}
			]),
			cast_after(?MIGRATION_RETRY_DELAY_MS, {migrate, Key, Cursor})
	end,
	{noreply, State};

handle_cast({join, BI}, State) ->
	#sync_data_state{
		data_root_offset_index = DataRootOffsetIndex,
		disk_pool_data_roots = DiskPoolDataRoots,
		sync_record = SyncRecord,
		block_index = CurrentBI
	} = State,
	[{_, WeaveSize, _} | _] = BI,
	{DiskPoolDataRoots2, SyncRecord2} =
		case {CurrentBI, ar_util:get_block_index_intersection(BI, CurrentBI)} of
			{[], _Intersection} ->
				ok = data_root_offset_index_from_block_index(DataRootOffsetIndex, BI, 0),
				{DiskPoolDataRoots, SyncRecord};
			{_CurrentBI, none} ->
				throw(last_stored_block_index_has_no_intersection_with_the_new_one);
			{_CurrentBI, {{H, Offset, _TXRoot}, _Height}} ->
				PreviousWeaveSize = element(2, hd(CurrentBI)),
				{ok, OrphanedDataRoots} = remove_orphaned_data(State, Offset, PreviousWeaveSize),
				ok = data_root_offset_index_from_block_index(
					DataRootOffsetIndex,
					lists:takewhile(fun({BH, _, _}) -> BH /= H end, BI),
					Offset
				),
				{reset_orphaned_data_roots_disk_pool_timestamps(
						DiskPoolDataRoots,
						OrphanedDataRoots
					), ar_intervals:cut(SyncRecord, Offset)}
		end,
	State2 =
		State#sync_data_state{
			disk_pool_data_roots = DiskPoolDataRoots2,
			sync_record = SyncRecord2,
			weave_size = WeaveSize,
			block_index = lists:sublist(BI, ?TRACK_CONFIRMATIONS)
		},
	ok = store_sync_state(State2),
	{noreply, State2};

handle_cast({add_tip_block, BlockTXPairs, BI}, State) ->
	#sync_data_state{
		tx_index = TXIndex,
		tx_offset_index = TXOffsetIndex,
		sync_record = SyncRecord,
		weave_size = CurrentWeaveSize,
		disk_pool_data_roots = DiskPoolDataRoots,
		disk_pool_size = DiskPoolSize,
		block_index = CurrentBI
	} = State,
	{BlockStartOffset, Blocks} = pick_missing_blocks(CurrentBI, BlockTXPairs),
	{ok, OrphanedDataRoots} = remove_orphaned_data(State, BlockStartOffset, CurrentWeaveSize),
	{WeaveSize, AddedDataRoots, UpdatedDiskPoolSize} = lists:foldl(
		fun ({_BH, []}, Acc) ->
				Acc;
			({_BH, SizeTaggedTXs}, {StartOffset, CurrentAddedDataRoots, CurrentDiskPoolSize}) ->
				{ok, DataRoots} = add_block_data_roots(State, SizeTaggedTXs, StartOffset),
				ok = update_tx_index(TXIndex, TXOffsetIndex, SizeTaggedTXs, StartOffset),
				{StartOffset + element(2, lists:last(SizeTaggedTXs)),
					sets:union(CurrentAddedDataRoots, DataRoots),
					sets:fold(
						fun(Key, Acc) ->
							Acc - element(1, maps:get(Key, DiskPoolDataRoots, {0, noop, noop}))
						end,
						CurrentDiskPoolSize,
						DataRoots
					)}
		end,
		{BlockStartOffset, sets:new(), DiskPoolSize},
		Blocks
	),
	UpdatedDiskPoolDataRoots =
		reset_orphaned_data_roots_disk_pool_timestamps(
			add_block_data_roots_to_disk_pool(DiskPoolDataRoots, AddedDataRoots),
			OrphanedDataRoots
		),
	UpdatedState = State#sync_data_state{
		weave_size = WeaveSize,
		sync_record = ar_intervals:cut(SyncRecord, BlockStartOffset),
		block_index = BI,
		disk_pool_data_roots = UpdatedDiskPoolDataRoots,
		disk_pool_size = UpdatedDiskPoolSize
	},
	ok = store_sync_state(UpdatedState),
	{noreply, UpdatedState};

handle_cast({add_data_root_to_disk_pool, {DataRoot, TXSize, TXID}}, State) ->
	#sync_data_state{ disk_pool_data_roots = DiskPoolDataRoots } = State,
	Key = << DataRoot/binary, TXSize:?OFFSET_KEY_BITSIZE >>,
	UpdatedDiskPoolDataRoots = maps:update_with(
		Key,
		fun ({_, _, not_set} = V) ->
				V;
			({S, T, TXIDSet}) ->
				{S, T, sets:add_element(TXID, TXIDSet)}
		end,
		{0, os:system_time(microsecond), sets:from_list([TXID])},
		DiskPoolDataRoots
	),
	{noreply, State#sync_data_state{ disk_pool_data_roots = UpdatedDiskPoolDataRoots }};

handle_cast({maybe_drop_data_root_from_disk_pool, {DataRoot, TXSize, TXID}}, State) ->
	#sync_data_state{
		disk_pool_data_roots = DiskPoolDataRoots,
		disk_pool_size = DiskPoolSize
	} = State,
	Key = << DataRoot/binary, TXSize:?OFFSET_KEY_BITSIZE >>,
	{UpdatedDiskPoolDataRoots, UpdatedDiskPoolSize} = case maps:get(Key, DiskPoolDataRoots, not_found) of
		not_found ->
			{DiskPoolDataRoots, DiskPoolSize};
		{_, _, not_set} ->
			{DiskPoolDataRoots, DiskPoolSize};
		{Size, T, TXIDs} ->
			case sets:subtract(TXIDs, sets:from_list([TXID])) of
				TXIDs ->
					{DiskPoolDataRoots, DiskPoolSize};
				UpdatedSet ->
					case sets:size(UpdatedSet) of
						0 ->
							{maps:remove(Key, DiskPoolDataRoots), DiskPoolSize - Size};
						_ ->
							{DiskPoolDataRoots#{ Key => {Size, T, UpdatedSet} }, DiskPoolSize}
					end
			end
	end,
	{noreply, State#sync_data_state{
		disk_pool_data_roots = UpdatedDiskPoolDataRoots,
		disk_pool_size = UpdatedDiskPoolSize
	}};

handle_cast({add_block, B, SizeTaggedTXs}, State) ->
	add_block(B, SizeTaggedTXs, State),
	{noreply, State};

handle_cast(check_space_update_peer_sync_records, State) ->
	case have_free_space() of
		true ->
			gen_server:cast(self(), update_peer_sync_records);
		false ->
			cast_after(?DISK_SPACE_CHECK_FREQUENCY_MS, check_space_update_peer_sync_records)
	end,
	{noreply, State};

handle_cast(update_peer_sync_records, State) ->
	case whereis(http_bridge_node) of
		undefined ->
			timer:apply_after(200, gen_server, cast, [self(), update_peer_sync_records]);
		Bridge ->
			Peers = ar_bridge:get_remote_peers(Bridge),
			BestPeers = pick_random_peers(
				Peers,
				?CONSULT_PEER_RECORDS_COUNT,
				?PICK_PEERS_OUT_OF_RANDOM_N
			),
			Self = self(),
			spawn(
				fun() ->
					PeerSyncRecords = lists:foldl(
						fun(Peer, Acc) ->
							case ar_http_iface_client:get_sync_record(Peer) of
								{ok, SyncRecord} ->
									maps:put(Peer, SyncRecord, Acc);
								_ ->
									Acc
							end
						end,
						#{},
						BestPeers
					),
					gen_server:cast(Self, {update_peer_sync_records, PeerSyncRecords})
				end
			)
	end,
	{noreply, State};

handle_cast({update_peer_sync_records, PeerSyncRecords}, State) ->
	timer:apply_after(
		?PEER_SYNC_RECORDS_FREQUENCY_MS,
		gen_server,
		cast,
		[self(), check_space_update_peer_sync_records]
	),
	{noreply, State#sync_data_state{
		peer_sync_records = PeerSyncRecords
	}};

handle_cast(check_space_sync_random_interval, State) ->
	FreeSpace = ar_storage:get_free_space(),
	case FreeSpace > ?DISK_DATA_BUFFER_SIZE of
		true ->
			gen_server:cast(self(), {sync_random_interval, []});
		false ->
			Msg =
				"The node has stopped syncing data - the available disk space is"
				" less than ~s. Add more disk space if you wish to store more data.",
			ar:console(Msg, [ar_util:bytes_to_mb_string(?DISK_DATA_BUFFER_SIZE)]),
			cast_after(?DISK_SPACE_CHECK_FREQUENCY_MS, check_space_sync_random_interval)
	end,
	{noreply, State};

%% Pick a random not synced interval and sync it.
handle_cast({sync_random_interval, RecentlyFailedPeers}, State) ->
	#sync_data_state{
		sync_record = SyncRecord,
		weave_size = WeaveSize,
		peer_sync_records = PeerSyncRecords,
		chunks_index = ChunksIndex,
		missing_data_cursor = Cursor,
		missing_chunks_index = MissingChunksIndex
	} = State,
	FilteredPeerSyncRecords = maps:without(RecentlyFailedPeers, PeerSyncRecords),
	case get_random_interval(SyncRecord, FilteredPeerSyncRecords, WeaveSize) of
		none ->
			case ar_kv:cyclic_iterator_move(MissingChunksIndex, Cursor) of
				none ->
					timer:apply_after(
						?SCAN_MISSING_CHUNKS_INDEX_FREQUENCY_MS,
						gen_server,
						cast,
						[self(), check_space_sync_random_interval]
					),
					{noreply, State#sync_data_state{ missing_data_cursor = first }};
				{ok, Key, Value, _NextCursor} ->
					<< End:?OFFSET_KEY_BITSIZE >> = Key,
					<< Start:?OFFSET_KEY_BITSIZE >> = Value,
					Step = ?DATA_CHUNK_SIZE div 8,
					Byte =
						case Cursor of
							first ->
								%% Randomize to account for small chunks we can find that
								%% are possibly hidden behind the small chunks we cannot find.
								Start + rand:uniform(min(Step, End - Start));
							_ ->
								{seek, << Offset:?OFFSET_KEY_BITSIZE >>} = Cursor,
								case Offset > Start andalso Offset =< End of
									true ->
										Offset;
									false ->
										Start + rand:uniform(min(Step, End - Start))
								end
						end,
					case has_chunk(ChunksIndex, Byte) of
						{true, ChunkEnd, ChunkStart} ->
							ok = ar_kv:delete(MissingChunksIndex, Key),
							ok = ar_intervals:fold(
								fun ({E, S}, ok) ->
										ar_kv:put(
											MissingChunksIndex,
											<< E:?OFFSET_KEY_BITSIZE >>,
											<< S:?OFFSET_KEY_BITSIZE >>
										);
									(_, Error) ->
										Error
								end,
								ok,
								ar_intervals:outerjoin(
									ar_intervals:add(ar_intervals:new(), ChunkEnd, ChunkStart),
									ar_intervals:add(ar_intervals:new(), End, Start)
								)
							),
							gen_server:cast(self(), {sync_random_interval, []});
						false ->
							%% Do not remove recently failed peers from the state as
							%% we are very likely to hit the false positives at this point.
							case get_peer_with_byte(Byte, PeerSyncRecords) of
								not_found ->
									timer:apply_after(
										?SCAN_MISSING_CHUNKS_INDEX_FREQUENCY_MS,
										gen_server,
										cast,
										[self(), check_space_sync_random_interval]
									);
								{ok, Peer} ->
									%% Sync one chunk.
									L = Byte - 1,
									R = Byte,
									timer:apply_after(
										?SCAN_MISSING_CHUNKS_INDEX_FREQUENCY_MS,
										gen_server,
										cast,
										[self(), {sync_chunk, Peer, L, L, R, R}]
									)
							end
					end,
					NextCursor = {seek, << (Byte + Step):?OFFSET_KEY_BITSIZE >>},
					{noreply, State#sync_data_state{ missing_data_cursor = NextCursor }}
			end;
		{ok, {Peer, LeftBound, RightBound}} ->
			%% The beginning of the chosen interval might be a false positive so we
			%% start from the random point inside and then attempt to download the whole
			%% interval by going from that point to the right and then from the left bound
			%% to that point. If a chunk cannot be fetched, we temporarily remove the peer
			%% from the map (otherwise, a malicious peer can make us spend a lot of time
			%% trying to fetch chunks from them) and look for a new interval to sync.
			Byte = LeftBound + rand:uniform(RightBound - LeftBound) - 1,
			gen_server:cast(self(), {sync_chunk, Peer, LeftBound, Byte, Byte, RightBound}),
			{noreply, State#sync_data_state{ peer_sync_records = FilteredPeerSyncRecords }}
	end;

handle_cast(check_space_compact_intervals, State) ->
	case have_free_space() of
		true ->
			gen_server:cast(self(), compact_intervals);
		false ->
			cast_after(?DISK_SPACE_CHECK_FREQUENCY_MS, check_space_compact_intervals)
	end,
	{noreply, State};

%% Keep the number of intervals below ?MAX_SHARED_SYNCED_INTERVALS_COUNT,
%% possibly introducing false positives. Over time, the number of intervals that
%% cannot be synced grows because some data is never uploaded, be it by mistake
%% or on purpose. When the number of intervals exceeds ?MAX_SHARED_SYNCED_INTERVALS_COUNT,
%% join the neighboring intervals together, starting from the intervals at the smallest
%% distance apart from each other. The false positives added this way are synced after no
%% byte that is not in our sync record is found in any of the peers' sync records.
%% The process then starts scanning the missing chunks index looking for the missing data.
handle_cast(compact_intervals, State) ->
	#sync_data_state{
		sync_record = SyncRecord,
		compacted_size = CompactedSize,
		missing_data_cursor = Cursor,
		missing_chunks_index = MissingChunksIndex
	} = State,
	{CompactedIntervals, SyncRecord2} =
		ar_intervals:compact(SyncRecord, ?MAX_SHARED_SYNCED_INTERVALS_COUNT),
	CompactedSize2 =
		CompactedSize + lists:foldl(
			fun({End, Start}, Acc) ->
				ok = ar_kv:put(
					MissingChunksIndex,
					<< End:?OFFSET_KEY_BITSIZE >>,
					<< Start:?OFFSET_KEY_BITSIZE >>
				),
				Acc + End - Start
			end,
			0,
			CompactedIntervals
		),
	NextCursor =
		case CompactedIntervals of
			[] ->
				Cursor;
			[{_End, Start} | _] ->
				%% Point the missing data cursor at the start of the biggest removed
				%% interval so that we try to sync it first after we cannot find anything
				%% to sync that is not in our sync record (with false positives).
				{seek, << (Start + 1):?OFFSET_KEY_BITSIZE >>}
		end,
	{noreply, State#sync_data_state{
		sync_record = SyncRecord2,
		compacted_size = CompactedSize2,
		missing_data_cursor = NextCursor
	}};

handle_cast({sync_chunk, _, LeftBound, LByte, RByte, RightBound}, State)
		when RByte >= RightBound andalso LByte < LeftBound ->
	gen_server:cast(self(), check_space_sync_random_interval),
	{noreply, State};
handle_cast({sync_chunk, Peer, LeftBound, LByte, RByte, RightBound}, State) ->
	Self = self(),
	spawn(
		fun() ->
			Step = ?DATA_CHUNK_SIZE div 8,
			{Byte, LeftBound2, RByte2} =
				case RByte < RightBound of
					true ->
						{RByte + 1, LeftBound, RByte + Step};
					false ->
						case LByte >= LeftBound of
							true ->
								{LeftBound + 1, LeftBound + Step, RByte};
							false ->
								gen_server:cast(Self, check_space_sync_random_interval)
						end
				end,
			case ar_tx_blacklist:is_byte_blacklisted(Byte) of
				true ->
					gen_server:cast(
						Self,
						{sync_chunk, Peer, LeftBound2, LByte, RByte2, RightBound}
					);
				false ->
					case ar_http_iface_client:get_chunk(Peer, Byte) of
						{ok, Proof} ->
							gen_server:cast(
								Self,
								{
									store_fetched_chunk,
									Peer,
									LeftBound,
									LByte,
									RByte,
									RightBound,
									Proof
								}
							);
						{error, _} ->
							gen_server:cast(Self, {sync_random_interval, [Peer]})
					end
			end
		end
	),
	{noreply, State};

handle_cast(
	{store_fetched_chunk, Peer, _, _, _, _, #{ data_path := Path, chunk := Chunk }}, State
) when ?IS_CHUNK_PROOF_RATIO_NOT_ATTRACTIVE(Chunk, Path) ->
	#sync_data_state{
		peer_sync_records = PeerSyncRecords
	} = State,
	gen_server:cast(self(), {sync_random_interval, []}),
	{noreply, State#sync_data_state{
		peer_sync_records = maps:remove(Peer, PeerSyncRecords)
	}};
handle_cast({store_fetched_chunk, Peer, LeftBound, LByte, RByte, RightBound, Proof}, State) ->
	#sync_data_state{
		data_root_offset_index = DataRootOffsetIndex,
		data_root_index = DataRootIndex,
		peer_sync_records = PeerSyncRecords
	} = State,
	#{ data_path := DataPath, tx_path := TXPath, chunk := Chunk } = Proof,
	ChunkSize = byte_size(Chunk),
	{Byte, LeftBound2, RByte2} =
		case RByte < RightBound of
			true ->
				{RByte, LeftBound, RByte + ChunkSize};
			false ->
				{LeftBound, LeftBound + ChunkSize, RByte}
		end,
	{ok, Key, Value} = ar_kv:get_prev(DataRootOffsetIndex, << Byte:?OFFSET_KEY_BITSIZE >>),
	<< BlockStartOffset:?OFFSET_KEY_BITSIZE >> = Key,
	{TXRoot, BlockSize, DataRootIndexKeySet} = binary_to_term(Value),
	Offset = Byte - BlockStartOffset,
	case validate_proof(TXRoot, TXPath, DataPath, Offset, Chunk, BlockSize) of
		false ->
			gen_server:cast(self(), {sync_random_interval, []}),
			{noreply, State#sync_data_state{
				peer_sync_records = maps:remove(Peer, PeerSyncRecords)
			}};
		{true, DataRoot, TXStartOffset, ChunkEndOffset, TXSize} ->
			AbsoluteTXStartOffset = BlockStartOffset + TXStartOffset,
			DataRootKey = << DataRoot/binary, TXSize:?OFFSET_KEY_BITSIZE >>,
			case sets:is_element(DataRootKey, DataRootIndexKeySet) of
				true ->
					do_not_update_data_root_index;
				false ->
					UpdatedValue =
						term_to_binary({
							TXRoot,
							BlockSize,
							sets:add_element(DataRootKey, DataRootIndexKeySet)
						}),
					ok = ar_kv:put(
						DataRootOffsetIndex,
						Key,
						UpdatedValue
					),
					ok = ar_kv:put(
						DataRootIndex,
						DataRootKey,
						term_to_binary(
							#{ TXRoot => #{ AbsoluteTXStartOffset => TXPath } }
						)
					)
			end,
			gen_server:cast(self(), {sync_chunk, Peer, LeftBound2, LByte, RByte2, RightBound}),
			DataPathHash = crypto:hash(sha256, DataPath),
			case store_chunk(
				State,
				TXSize,
				AbsoluteTXStartOffset + ChunkEndOffset,
				ChunkEndOffset,
				DataPathHash,
				DataPath,
				TXRoot,
				DataRoot,
				TXPath,
				byte_size(Chunk),
				Chunk,
				store_data
			) of
				{updated, SyncRecord, CompactedSize} ->
					State2 =
						State#sync_data_state{
							sync_record = SyncRecord,
							compacted_size = CompactedSize
						},
					record_v2_index_data_size(State2),
					{noreply, State2};
				_ ->
					{noreply, State}
			end
	end;

handle_cast(process_disk_pool_item, State) ->
	#sync_data_state{
		disk_pool_cursor = Cursor,
		disk_pool_chunks_index = DiskPoolChunksIndex
	} = State,
	case ar_kv:cyclic_iterator_move(DiskPoolChunksIndex, Cursor) of
		{ok, Key, Value, NextCursor} ->
			timer:apply_after(
				case NextCursor of
					first ->
						?DISK_POOL_SCAN_FREQUENCY_MS;
					_ ->
						0
				end,
				gen_server,
				cast,
				[self(), process_disk_pool_item]
			),
			process_disk_pool_item(State, Key, Value, NextCursor);
		none ->
			%% Since we are not persisting the number of chunks in the disk pool metric on
			%% every update, it can go out of sync with the actual value. Here is one place
			%% where we can reset it if we detect the whole column has been traversed.
			prometheus_gauge:set(disk_pool_chunks_count, 0),
			timer:apply_after(
				?DISK_POOL_SCAN_FREQUENCY_MS,
				gen_server,
				cast,
				[self(), process_disk_pool_item]
			),
			{noreply, State}
	end;

handle_cast(update_disk_pool_data_roots, State) ->
	#sync_data_state{ disk_pool_data_roots = DiskPoolDataRoots } = State,
	Now = os:system_time(microsecond),
	UpdatedDiskPoolDataRoots = maps:filter(
		fun(_, {_, Timestamp, _}) ->
			Timestamp + ar_meta_db:get(disk_pool_data_root_expiration_time_us) > Now
		end,
		DiskPoolDataRoots
	),
	DiskPoolSize = maps:fold(
		fun(_, {Size, _, _}, Acc) ->
			Acc + Size
		end,
		0,
		UpdatedDiskPoolDataRoots
	),
	prometheus_gauge:set(pending_chunks_size, DiskPoolSize),
	timer:apply_after(
		?REMOVE_EXPIRED_DATA_ROOTS_FREQUENCY_MS,
		gen_server,
		cast,
		[self(), update_disk_pool_data_roots]
	),
	{noreply, State#sync_data_state{
		disk_pool_data_roots = UpdatedDiskPoolDataRoots,
		disk_pool_size = DiskPoolSize
	}};

handle_cast({remove_tx_data, TXID}, State) ->
	#sync_data_state{ tx_index = TXIndex } = State,
	case ar_kv:get(TXIndex, TXID) of
		{ok, Value} ->
			{End, Size} = binary_to_term(Value),
			Start = End - Size,
			gen_server:cast(?MODULE, {remove_tx_data, TXID, End, Start + 1}),
			{noreply, State};
		not_found ->
			ar:err([
				{event, blacklisted_tx_offset_not_found},
				{tx, ar_util:encode(TXID)}
			]),
			{noreply, State};
		{error, Reason} ->
			ar:err([
				{event, failed_to_fetch_blacklisted_tx_offset},
				{tx, ar_util:encode(TXID)},
				{reason, Reason}
			]),
			{noreply, State}
	end;

handle_cast({remove_tx_data, TXID, End, Cursor}, State) when Cursor > End ->
	ar_tx_blacklist:notify_about_removed_tx_data(TXID),
	{noreply, State};
handle_cast({remove_tx_data, TXID, End, Cursor}, State) ->
	#sync_data_state{
		chunks_index = ChunksIndex,
		chunk_data_index = ChunkDataIndex,
		sync_record = SyncRecord
	} = State,
	case ar_kv:get_next(ChunksIndex, << Cursor:?OFFSET_KEY_BITSIZE >>) of
		{ok, Key, Chunk} ->
			<< ChunkEnd:?OFFSET_KEY_BITSIZE >> = Key,
			case ChunkEnd > End of
				true ->
					ar_tx_blacklist:notify_about_removed_tx_data(TXID),
					{noreply, State};
				false ->
					ok = ar_kv:delete(ChunksIndex, Key),
					{DataPathHash, _, _, _, _, ChunkSize} = binary_to_term(Chunk),
					delete_chunk(ChunkDataIndex, DataPathHash),
					ChunkStart = ChunkEnd - ChunkSize,
					SyncRecord2 = ar_intervals:delete(SyncRecord, ChunkEnd, ChunkStart),
					State2 =
						State#sync_data_state{
							sync_record = SyncRecord2
						},
					gen_server:cast(?MODULE, {remove_tx_data, TXID, End, ChunkEnd + 1}),
					ar_meta_db:increase(used_space, -ChunkSize),
					{noreply, State2}
			end;
		_ ->
			{noreply, State}
	end.

handle_call(
	{add_chunk, DataRoot, DataPath, Chunk, Offset, TXSize, WriteToFreeSpaceBuffer}, _From, State
) ->
	case WriteToFreeSpaceBuffer == write_to_free_space_buffer orelse have_free_space() of
		false ->
			{reply, {error, disk_full}, State};
		true ->
			case add_chunk(State, DataRoot, DataPath, Chunk, Offset, TXSize) of
				{ok, UpdatedState} ->
					{reply, ok, UpdatedState};
				{{error, Reason}, MaybeUpdatedState} ->
					ar:err([{event, ar_data_sync_failed_to_store_chunk}, {reason, Reason}]),
					{reply, {error, Reason}, MaybeUpdatedState}
			end
	end;

handle_call(get_sync_record_etf, _From, #sync_data_state{ sync_record = SyncRecord } = State) ->
	Limit = ?MAX_SHARED_SYNCED_INTERVALS_COUNT,
	{reply, {ok, ar_intervals:to_etf(SyncRecord, Limit)}, State};

handle_call(get_sync_record_json, _From, #sync_data_state{ sync_record = SyncRecord } = State) ->
	Limit = ?MAX_SHARED_SYNCED_INTERVALS_COUNT,
	{reply, {ok, ar_intervals:to_json(SyncRecord, Limit)}, State}.

handle_info(_Message, State) ->
	{noreply, State}.

terminate(Reason, State) ->
	#sync_data_state{ chunks_index = {DB, _} } = State,
	ar:info([{event, ar_data_sync_terminate}, {reason, Reason}]),
	ok = store_sync_state(State),
	ar_kv:close(DB).

%%%===================================================================
%%% Private functions.
%%%===================================================================

read_chunk(ChunkDataIndex, DataPathHash) ->
	case ar_kv:get(ChunkDataIndex, DataPathHash) of
		not_found ->
			case ets:member(?MODULE, store_data_in_v2_index_completed) of
				false ->
					ar_storage:read_chunk(DataPathHash);
				true ->
					not_found
			end;
		{ok, Value} ->
			{ok, binary_to_term(Value)};
		Error ->
			Error
	end.

delete_chunk(ChunkDataIndex, DataPathHash) ->
	case ar_kv:delete(ChunkDataIndex, DataPathHash) of
		ok ->
			case ets:member(?MODULE, store_data_in_v2_index_completed) of
				false ->
					ar_storage:delete_chunk(DataPathHash);
				true ->
					ok
			end;
		Error ->
			Error
	end.

init_kv() ->
	Opts = [
		{cache_index_and_filter_blocks, true},
		{bloom_filter_policy, 10}, % ~1% false positive probability
		{prefix_extractor, {capped_prefix_transform, 28}},
		{optimize_filters_for_hits, true},
		{max_open_files, 100000},
		%% 640 MiB per SST file. RocksDB opens every SST file on startup and keeps
		%% them open.
		{target_file_size_base, 64 * 10 * 1024 * 1024},
		%% The tuning guide recommends to set it to 10 times target_file_size_base.
		%% https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide.
		{max_bytes_for_level_base, 64 * 10 * 10 * 1024 * 1024}
	],
	ColumnFamilies = [
		"default",
		"chunks_index",
		"missing_chunks_index",
		"data_root_index",
		"data_root_offset_index",
		"tx_index",
		"tx_offset_index",
		"disk_pool_chunks_index",
		"migrations_index",
		"chunk_data_index"
	],
	ColumnFamilyDescriptors = [{Name, Opts} || Name <- ColumnFamilies],
	{ok, DB, [_, CF1, CF2, CF3, CF4, CF5, CF6, CF7, CF8, CF9]} =
		ar_kv:open("ar_data_sync_db", ColumnFamilyDescriptors),
	State = #sync_data_state{
		chunks_index = {DB, CF1},
		missing_chunks_index = {DB, CF2},
		data_root_index = {DB, CF3},
		data_root_offset_index = {DB, CF4},
		tx_index = {DB, CF5},
		tx_offset_index = {DB, CF6},
		disk_pool_chunks_index = {DB, CF7},
		migrations_index = {DB, CF8},
		chunk_data_index = {DB, CF9}
	},
	ets:insert(?MODULE, [
		{chunks_index, {DB, CF1}},
		{missing_chunks_index, {DB, CF2}},
		{data_root_index, {DB, CF3}},
		{data_root_offset_index, {DB, CF4}},
		{tx_index, {DB, CF5}},
		{tx_offset_index, {DB, CF6}},
		{disk_pool_chunks_index, {DB, CF7}},
		{chunk_data_index, {DB, CF9}}
	]),
	State.

read_data_sync_state() ->
	case ar_storage:read_term(data_sync_state) of
		{ok, {SyncRecord, RecentBI, RawDiskPoolDataRoots, DiskPoolSize, CompactedSize}} ->
			DiskPoolDataRoots = filter_invalid_data_roots(RawDiskPoolDataRoots),
			WeaveSize = case RecentBI of [] -> 0; _ -> element(2, hd(RecentBI)) end,
			{SyncRecord, RecentBI, DiskPoolDataRoots, DiskPoolSize, WeaveSize, CompactedSize};
		{ok, {SyncRecord, RecentBI, RawDiskPoolDataRoots, DiskPoolSize}} ->
			DiskPoolDataRoots = filter_invalid_data_roots(RawDiskPoolDataRoots),
			WeaveSize = case RecentBI of [] -> 0; _ -> element(2, hd(RecentBI)) end,
			{SyncRecord, RecentBI, DiskPoolDataRoots, DiskPoolSize, WeaveSize, 0};
		not_found ->
			{ar_intervals:new(), [], #{}, 0, 0, 0}
	end.

migrate_index(MigrationsIndex) ->
	%% To add a migration, add a key to the migrations column family with a value
	%% representing the current migration's stage, and trigger the migration here.
	Key = <<"store_data_in_v2_index">>,
	case ar_kv:get(MigrationsIndex, Key) of
		{ok, <<"complete">>} ->
			ets:insert(?MODULE, {store_data_in_v2_index_completed}),
			ok;
		not_found ->
			gen_server:cast(?MODULE, {migrate, Key, first});
		{ok, Cursor} ->
			gen_server:cast(?MODULE, {migrate, Key, {seek, Cursor}})
	end.

filter_invalid_data_roots(DiskPoolDataRoots) ->
	%% Filter out the keys with the invalid values, if any,
	%% produced by a bug in 2.1.0.0.
	maps:filter(
		fun (_, {_, _, _}) ->
				true;
			(_, _) ->
				false
		end,
		DiskPoolDataRoots
	).

data_root_offset_index_from_block_index(Index, BI, StartOffset) ->
	data_root_offset_index_from_reversed_block_index(Index, lists:reverse(BI), StartOffset).

data_root_offset_index_from_reversed_block_index(
	Index,
	[{_, Offset, _} | BI],
	Offset
) ->
	data_root_offset_index_from_reversed_block_index(Index, BI, Offset);
data_root_offset_index_from_reversed_block_index(
	Index,
	[{_, WeaveSize, TXRoot} | BI],
	StartOffset
) ->
	case ar_kv:put(
		Index,
		<< StartOffset:?OFFSET_KEY_BITSIZE >>,
		term_to_binary({TXRoot, WeaveSize - StartOffset, sets:new()})
	) of
		ok ->
			data_root_offset_index_from_reversed_block_index(Index, BI, WeaveSize);
		Error ->
			Error
	end;
data_root_offset_index_from_reversed_block_index(_Index, [], _StartOffset) ->
	ok.	

remove_orphaned_data(State, BlockStartOffset, WeaveSize) ->
	ok = remove_orphaned_txs(State, BlockStartOffset, WeaveSize),
	{ok, OrphanedDataRoots} = remove_orphaned_data_roots(State, BlockStartOffset),
	ok = remove_orphaned_data_root_offsets(State, BlockStartOffset, WeaveSize),
	ok = remove_orphaned_chunks(State, BlockStartOffset, WeaveSize),
	{ok, OrphanedDataRoots}.

remove_orphaned_txs(State, BlockStartOffset, WeaveSize) ->
	#sync_data_state{
		tx_offset_index = TXOffsetIndex,
		tx_index = TXIndex
	} = State,
	ok = case ar_kv:get_range(TXOffsetIndex, << BlockStartOffset:?OFFSET_KEY_BITSIZE >>) of
		{ok, EmptyMap} when map_size(EmptyMap) == 0 ->
			ok;
		{ok, Map} ->
			maps:fold(
				fun
					(_, _Value, {error, _} = Error) ->
						Error;
					(_, TXID, ok) ->
						ar_kv:delete(TXIndex, TXID)
				end,
				ok,
				Map
			);
		Error ->
			Error
	end,
	ar_kv:delete_range(
		TXOffsetIndex,
		<< BlockStartOffset:?OFFSET_KEY_BITSIZE >>,
		<< (WeaveSize + 1):?OFFSET_KEY_BITSIZE >>
	).

remove_orphaned_chunks(State, BlockStartOffset, WeaveSize) ->
	#sync_data_state{ chunks_index = ChunksIndex } = State,
	EndKey = << (WeaveSize + 1):?OFFSET_KEY_BITSIZE >>,
	ar_kv:delete_range(ChunksIndex, << (BlockStartOffset + 1):?OFFSET_KEY_BITSIZE >>, EndKey).

remove_orphaned_data_roots(State, BlockStartOffset) ->
	#sync_data_state{
		data_root_offset_index = DataRootOffsetIndex,
		data_root_index = DataRootIndex
	} = State,
	case ar_kv:get_range(DataRootOffsetIndex, << BlockStartOffset:?OFFSET_KEY_BITSIZE >>) of
		{ok, EmptyMap} when map_size(EmptyMap) == 0 ->
			{ok, sets:new()};
		{ok, Map} ->
			maps:fold(
				fun
					(_, _Value, {error, _} = Error) ->
						Error;
					(_, Value, {ok, OrphanedDataRoots}) ->
						{TXRoot, _BlockSize, DataRootIndexKeySet} = binary_to_term(Value),
						sets:fold(
							fun (_Key, {error, _} = Error) ->
									Error;
								(Key, {ok, Orphaned}) ->
									case remove_orphaned_data_root(
										DataRootIndex,
										Key,
										TXRoot,
										BlockStartOffset
									) of
										removed ->
											{ok, sets:add_element(Key, Orphaned)};
										ok ->
											{ok, Orphaned};
										Error ->
											Error
									end
							end,
							{ok, OrphanedDataRoots},
							DataRootIndexKeySet
						)
				end,
				{ok, sets:new()},
				Map
			);	
		Error ->
			Error
	end.

remove_orphaned_data_root(DataRootIndex, DataRootKey, TXRoot, StartOffset) ->
	case ar_kv:get(DataRootIndex, DataRootKey) of
		not_found ->
			ok;
		{ok, Value} ->
			TXRootMap = binary_to_term(Value),
			case maps:is_key(TXRoot, TXRootMap) of
				false ->
					ok;
				true ->
					OffsetMap = maps:get(TXRoot, TXRootMap),
					UpdatedTXRootMap = case maps:filter(
						fun(TXStartOffset, _) ->
							TXStartOffset < StartOffset
						end,
						OffsetMap
					) of
						EmptyMap when map_size(EmptyMap) == 0 ->
							maps:remove(TXRoot, TXRootMap);
						UpdatedOffsetMap ->
							maps:put(TXRoot, UpdatedOffsetMap, TXRootMap)
					end,
					case UpdatedTXRootMap of
						EmptyTXRootMap when map_size(EmptyTXRootMap) == 0 ->
							case ar_kv:delete(DataRootIndex, DataRootKey) of
								ok ->
									removed;
								Error ->
									Error
							end;
						_ ->
							ar_kv:put(
								DataRootIndex,
								DataRootKey,
								term_to_binary(UpdatedTXRootMap)
							)
					end
			end
	end.

remove_orphaned_data_root_offsets(State, BlockStartOffset, WeaveSize) ->
	#sync_data_state{
		data_root_offset_index = DataRootOffsetIndex
	} = State,
	ar_kv:delete_range(
		DataRootOffsetIndex,
		<< BlockStartOffset:?OFFSET_KEY_BITSIZE >>,
		<< (WeaveSize + 1):?OFFSET_KEY_BITSIZE >>
	).

have_free_space() ->
	ar_storage:get_free_space() > ?DISK_DATA_BUFFER_SIZE.

add_block(B, SizeTaggedTXs, State) ->
	#sync_data_state{
		tx_index = TXIndex,
		tx_offset_index = TXOffsetIndex
	} = State,
	BlockStartOffset = B#block.weave_size - B#block.block_size,
	{ok, _} = add_block_data_roots(State, SizeTaggedTXs, BlockStartOffset),
	ok = update_tx_index(TXIndex, TXOffsetIndex, SizeTaggedTXs, BlockStartOffset).

update_tx_index(_TXIndex, _TXOffsetIndex, [], _BlockStartOffset) ->
	ok;
update_tx_index(TXIndex, TXOffsetIndex, SizeTaggedTXs, BlockStartOffset) ->
	lists:foldl(
		fun ({_, Offset}, Offset) ->
				Offset;
			({{TXID, _}, TXEndOffset}, PreviousOffset) ->
				AbsoluteEndOffset = BlockStartOffset + TXEndOffset,
				TXSize = TXEndOffset - PreviousOffset,
				AbsoluteStartOffset = AbsoluteEndOffset - TXSize,
				case ar_kv:put(
					TXOffsetIndex,
					<< AbsoluteStartOffset:?OFFSET_KEY_BITSIZE >>,
					TXID
				) of
					ok ->
						case ar_kv:put(
							TXIndex,
							TXID,
							term_to_binary({AbsoluteEndOffset, TXSize})
						) of
							ok ->
								TXEndOffset;
							{error, Reason} ->
								ar:err([{event, failed_to_update_tx_index}, {reason, Reason}]),
								TXEndOffset
						end;
					{error, Reason} ->
						ar:err([{event, failed_to_update_tx_offset_index}, {reason, Reason}]),
						TXEndOffset
				end
		end,
		0,
		SizeTaggedTXs
	),
	ok.

add_block_data_roots(_State, [], _CurrentWeaveSize) ->
	{ok, sets:new()};
add_block_data_roots(State, SizeTaggedTXs, CurrentWeaveSize) ->
	#sync_data_state{
		data_root_offset_index = DataRootOffsetIndex
	} = State,
	SizeTaggedDataRoots = [{Root, Offset} || {{_, Root}, Offset} <- SizeTaggedTXs],
	{TXRoot, TXTree} = ar_merkle:generate_tree(SizeTaggedDataRoots),
	{BlockSize, DataRootIndexKeySet} = lists:foldl(
		fun ({_DataRoot, Offset}, {Offset, _} = Acc) ->
				Acc;
			({DataRoot, TXEndOffset}, {TXStartOffset, CurrentDataRootSet}) ->
				TXPath = ar_merkle:generate_path(TXRoot, TXEndOffset - 1, TXTree),
				TXOffset = CurrentWeaveSize + TXStartOffset,
				TXSize = TXEndOffset - TXStartOffset,
				DataRootKey = << DataRoot/binary, TXSize:?OFFSET_KEY_BITSIZE >>,
				ok = update_data_root_index(
					State,
					DataRootKey,
					TXRoot,
					TXOffset,
					TXPath
				),
				{TXEndOffset, sets:add_element(DataRootKey, CurrentDataRootSet)}
		end,
		{0, sets:new()},
		SizeTaggedDataRoots
	),
	case BlockSize > 0 of
		true ->
			ok = ar_kv:put(
				DataRootOffsetIndex,
				<< CurrentWeaveSize:?OFFSET_KEY_BITSIZE >>,
				term_to_binary({TXRoot, BlockSize, DataRootIndexKeySet})
			);
		false ->
			do_not_update_data_root_offset_index
	end,
	{ok, DataRootIndexKeySet}.

update_data_root_index(State, DataRootKey, TXRoot, AbsoluteTXStartOffset, TXPath) ->
	#sync_data_state{
		data_root_index = DataRootIndex
	} = State,
	TXRootMap = case ar_kv:get(DataRootIndex, DataRootKey) of
		not_found ->
			#{};
		{ok, Value} ->
			binary_to_term(Value)
	end,
	OffsetMap = maps:get(TXRoot, TXRootMap, #{}),
	UpdatedValue = term_to_binary(
		TXRootMap#{ TXRoot => OffsetMap#{ AbsoluteTXStartOffset => TXPath } }
	),
	ar_kv:put(DataRootIndex, DataRootKey, UpdatedValue).

add_block_data_roots_to_disk_pool(DataRoots, DataRootIndexKeySet) ->
	{U, _} = sets:fold(
		fun(R, {M, T}) ->
			{maps:update_with(
				R,
				fun({_, Timeout, _}) -> {0, Timeout, not_set} end,
				{0, T, not_set},
				M
			), T + 1}
		end,
		{DataRoots, os:system_time(microsecond)},
		DataRootIndexKeySet
	),
	U.

reset_orphaned_data_roots_disk_pool_timestamps(DataRoots, DataRootIndexKeySet) ->
	{U, _} = sets:fold(
		fun(R, {M, T}) ->
			{maps:update_with(
				R,
				fun({Size, _, TXIDSet}) -> {Size, T, TXIDSet} end,
				{0, T, not_set},
				M
			), T + 1}
		end,
		{DataRoots, os:system_time(microsecond)},
		DataRootIndexKeySet
	),
	U.

store_chunk(
	State,
	TXSize,
	AbsoluteChunkOffset,
	ChunkOffset,
	DataPathHash,
	DataPath,
	TXRoot,
	DataRoot,
	TXPath,
	ChunkSize,
	Chunk,
	IndexOnly
) ->
	#sync_data_state{
		sync_record = SyncRecord,
		chunks_index = ChunksIndex,
		chunk_data_index = ChunkDataIndex
	} = State,
	Key = << AbsoluteChunkOffset:?OFFSET_KEY_BITSIZE >>,
	%% The check is inversed to account for false positives possibly present
	%% in the sync record. Checking the sync record saves us one extra disk
	%% read per new chunk not present in the sync record (most of the chunks
	%% should be like this).
	ChunkNotStored =
		not ar_intervals:is_inside(SyncRecord, AbsoluteChunkOffset)
			orelse ar_kv:get(ChunksIndex, Key) == not_found,
	case ChunkNotStored of
		false ->
			not_updated;
		true ->
			case ar_tx_blacklist:is_byte_blacklisted(AbsoluteChunkOffset) of
				true ->
					not_updated;
				false ->
					WriteChunkResult =
						case IndexOnly of
							store_data ->
								write_chunk(ChunkDataIndex, DataPathHash, Chunk, DataPath);
							index_only ->
								ok
						end,
					case WriteChunkResult of
						ok ->
							update_chunks_index(
								State,
								TXSize,
								AbsoluteChunkOffset,
								ChunkOffset,
								DataPathHash,
								TXRoot,
								DataRoot,
								TXPath,
								ChunkSize
							);
						{error, Reason} = Error ->
							ar:err([
								{event, failed_to_store_chunk},
								{reason, Reason},
								{data_path_hash, ar_util:encode(DataPathHash)}
							]),
							Error
					end
			end
	end.

update_chunks_index(
	State,
	TXSize,
	AbsoluteChunkOffset,
	ChunkOffset,
	DataPathHash,
	TXRoot,
	DataRoot,
	TXPath,
	ChunkSize
) ->
	#sync_data_state{
		chunks_index = ChunksIndex,
		disk_pool_chunks_index = DiskPoolChunksIndex,
		disk_pool_data_roots = DiskPoolDataRoots,
		sync_record = SyncRecord,
		compacted_size = CompactedSize
	} = State,
	Key = << AbsoluteChunkOffset:?OFFSET_KEY_BITSIZE >>,
	Value = {DataPathHash, TXRoot, DataRoot, TXPath, ChunkOffset, ChunkSize},
	case ar_kv:put(ChunksIndex, Key, term_to_binary(Value)) of
		ok ->
			DataRootKey = << DataRoot/binary, TXSize:?OFFSET_KEY_BITSIZE >>,
			case maps:get(DataRootKey, DiskPoolDataRoots, not_found) of
				{_, Timestamp, _} ->
					DiskPoolChunkKey = << Timestamp:256, DataPathHash/binary >>,
					case ar_kv:get(DiskPoolChunksIndex, DiskPoolChunkKey) of
						not_found ->
							ok = ar_kv:put(
								DiskPoolChunksIndex,
								DiskPoolChunkKey,
								term_to_binary(
									{ChunkOffset, ChunkSize, DataRoot, TXSize}
								)
							),
							prometheus_gauge:inc(disk_pool_chunks_count);
						_ ->
							do_not_update_disk_pool
					end;
				not_found ->
					do_not_update_disk_pool
			end,
			StartOffset = AbsoluteChunkOffset - ChunkSize,
			SyncRecord2 = ar_intervals:add(SyncRecord, AbsoluteChunkOffset, StartOffset),
			MaxSharedIntervals = ?MAX_SHARED_SYNCED_INTERVALS_COUNT,
			ExtraIntervalsBeforeCompaction = ?EXTRA_INTERVALS_BEFORE_COMPACTION,
			Count = ar_intervals:count(SyncRecord2),
			case Count > MaxSharedIntervals + ExtraIntervalsBeforeCompaction of
				true ->
					gen_server:cast(self(), compact_intervals);
				false ->
					ok
			end,
			CompactedSize2 =
				case ar_intervals:is_inside(SyncRecord, AbsoluteChunkOffset) of
					true ->
						CompactedSize - ChunkSize;
					false ->
						CompactedSize
				end,
			{updated, SyncRecord2, CompactedSize2};
		{error, Reason} ->
			ar:err([
				{event, failed_to_update_chunk_index},
				{reason, Reason},
				{data_path_hash, ar_util:encode(DataPathHash)},
				{offset, AbsoluteChunkOffset}
			]),
			{error, Reason}
	end.

store_sync_state(
	#sync_data_state{
		sync_record = SyncRecord,
		disk_pool_data_roots = DiskPoolDataRoots,
		disk_pool_size = DiskPoolSize,
		block_index = BI,
		compacted_size = CompactedSize
	}
) ->
	ar_metrics:store(disk_pool_chunks_count),
	ar_storage:write_term(
		data_sync_state,
		{SyncRecord, BI, DiskPoolDataRoots, DiskPoolSize, CompactedSize}
	).

record_v2_index_data_size(State) ->
	#sync_data_state{
		sync_record = SyncRecord,
		compacted_size = CompactedSize
	} = State,
	prometheus_gauge:set(v2_index_data_size, ar_intervals:sum(SyncRecord) - CompactedSize).

pick_random_peers(Peers, N, M) ->
	lists:sublist(
		lists:sort(fun(_, _) -> rand:uniform() > 0.5 end, lists:sublist(Peers, M)),
		N
	).

get_random_interval(SyncRecord, PeerSyncRecords, WeaveSize) ->
	%% Try keeping no more than ?MAX_SHARED_SYNCED_INTERVALS_COUNT intervals
	%% in the sync record by choosing the appropriate size of continuous
	%% intervals to sync. The motivation is to keep the record size small for
	%% low traffic overhead. When the size increases ?MAX_SHARED_SYNCED_INTERVALS_COUNT,
	%% a random subset of the intervals is served to peers.
	%% Include at least one byte - relevant for tests where the weave can be very small.
	SyncSize = max(1, WeaveSize div ?MAX_SHARED_SYNCED_INTERVALS_COUNT),
	maps:fold(
		fun (_, _, {ok, {Peer, L, R}}) ->
				{ok, {Peer, L, R}};
			(Peer, PeerSyncRecord, none) ->
				PeerSyncRecordBelowWeaveSize = ar_intervals:cut(PeerSyncRecord, WeaveSize),
				I = ar_intervals:outerjoin(SyncRecord, PeerSyncRecordBelowWeaveSize),
				Sum = ar_intervals:sum(I),
				case Sum of
					0 ->
						none;
					_ ->
						RelativeByte = rand:uniform(Sum) - 1,
						{L, Byte, R} =
							ar_intervals:get_interval_by_nth_inner_number(I, RelativeByte),
						LeftBound = max(L, Byte - SyncSize div 2),
						{ok, {Peer, LeftBound, min(R, LeftBound + SyncSize)}}
				end
		end,
		none,
		PeerSyncRecords
	).

has_chunk(ChunksIndex, Byte) ->
	case ar_kv:get_next(ChunksIndex, << Byte:?OFFSET_KEY_BITSIZE >>) of
		{ok, ChunkKey, Chunk}->
			{_, _, _, _, _, ChunkSize} = binary_to_term(Chunk),
			<< ChunkEnd:?OFFSET_KEY_BITSIZE >> = ChunkKey,
			case ChunkEnd - Byte >= ChunkSize of
				true ->
					false;
				false ->
					{true, ChunkEnd, ChunkEnd - ChunkSize}
			end;
		_ ->
			false
	end.

get_peer_with_byte(Byte, PeerSyncRecords) ->
	get_peer_with_byte2(Byte, maps:iterator(PeerSyncRecords)).

get_peer_with_byte2(Byte, PeerSyncRecordsIterator) ->
	case maps:next(PeerSyncRecordsIterator) of
		none ->
			not_found;
		{Peer, SyncRecord, PeerSyncRecordsIterator2} ->
			case ar_intervals:is_inside(SyncRecord, Byte) of
				true ->
					{ok, Peer};
				false ->
					get_peer_with_byte2(Byte, PeerSyncRecordsIterator2)
			end
	end.

validate_proof(_, _, _, _, Chunk, _) when byte_size(Chunk) > ?DATA_CHUNK_SIZE ->
	false;
validate_proof(TXRoot, TXPath, DataPath, Offset, Chunk, BlockSize) ->
	case ar_merkle:validate_path(TXRoot, Offset, BlockSize, TXPath) of
		false ->
			false;
		{DataRoot, TXStartOffset, TXEndOffset} ->
			ChunkOffset = Offset - TXStartOffset,
			TXSize = TXEndOffset - TXStartOffset,
			case ar_merkle:validate_path(DataRoot, ChunkOffset, TXSize, DataPath) of
				false ->
					false;
				{ChunkID, ChunkStartOffset, ChunkEndOffset} ->
					case ar_tx:generate_chunk_id(Chunk) == ChunkID of
						false ->
							false;
						true ->
							case ChunkEndOffset - ChunkStartOffset == byte_size(Chunk) of
								true ->
									{true, DataRoot, TXStartOffset, ChunkEndOffset, TXSize};
								false ->
									false
							end
					end
			end
	end.

validate_data_path(_, _, _, _, Chunk) when byte_size(Chunk) > ?DATA_CHUNK_SIZE ->
	false;
validate_data_path(DataRoot, Offset, TXSize, DataPath, Chunk) ->
	case ar_merkle:validate_path(DataRoot, Offset, TXSize, DataPath) of
		false ->
			false;
		{ChunkID, StartOffset, EndOffset} ->
			case ar_tx:generate_chunk_id(Chunk) == ChunkID of
				false ->
					false;
				true ->
					case EndOffset - StartOffset == byte_size(Chunk) of
						true ->
							{true, EndOffset};
						false ->
							false
					end
			end
	end.

add_chunk(State, DataRoot, DataPath, Chunk, Offset, TXSize) ->
	#sync_data_state{
		data_root_index = DataRootIndex,
		disk_pool_data_roots = DiskPoolDataRoots,
		disk_pool_chunks_index = DiskPoolChunksIndex,
		disk_pool_size = DiskPoolSize,
		chunk_data_index = ChunkDataIndex
	} = State,
	DataRootKey = << DataRoot/binary, TXSize:?OFFSET_KEY_BITSIZE >>,
	case ar_kv:get(DataRootIndex, DataRootKey) of
		not_found ->
			case maps:get(DataRootKey, DiskPoolDataRoots, not_found) of
				not_found ->
					{{error, data_root_not_found}, State};
				{Size, Timestamp, TXIDSet} ->
					DataRootLimit =
						ar_meta_db:get(max_disk_pool_data_root_buffer_mb) * 1024 * 1024,
					DiskPoolLimit = ar_meta_db:get(max_disk_pool_buffer_mb) * 1024 * 1024,
					ChunkSize = byte_size(Chunk),
					case Size + ChunkSize > DataRootLimit
							orelse DiskPoolSize + ChunkSize > DiskPoolLimit of
						true ->
							{{error, exceeds_disk_pool_size_limit}, State};
						false ->
							case
								validate_data_path(DataRoot, Offset, TXSize, DataPath, Chunk)
							of
								false ->
									{{error, invalid_proof}, State};
								{true, EndOffset} ->
									DataPathHash = crypto:hash(sha256, DataPath),
									Key = << Timestamp:256, DataPathHash/binary >>,
									V = term_to_binary(
										{EndOffset, ChunkSize, DataRoot, TXSize}
									),
									case ar_kv:get(DiskPoolChunksIndex, Key) of
										not_found ->
											ok = ar_kv:put(DiskPoolChunksIndex, Key, V),
											prometheus_gauge:inc(disk_pool_chunks_count),
											ok =
												write_chunk(
													ChunkDataIndex,
													DataPathHash,
													Chunk,
													DataPath
												),
											UpdatedDiskPoolDataRooots =
												maps:put(
													DataRootKey,
													{Size + ChunkSize, Timestamp, TXIDSet},
													DiskPoolDataRoots
												),
											UpdatedState = State#sync_data_state{
												disk_pool_size = DiskPoolSize + ChunkSize,
												disk_pool_data_roots = UpdatedDiskPoolDataRooots
											},
											{ok, UpdatedState};
										_ ->
											{ok, State}
									end
							end
					end
			end;
		{ok, Value} ->
			case validate_data_path(DataRoot, Offset, TXSize, DataPath, Chunk) of
				false ->
					{{error, invalid_proof}, State};
				{true, EndOffset} ->
					DataPathHash = crypto:hash(sha256, DataPath),
					store_chunk(
						State,
						data_root_index_iterator(binary_to_term(Value)),
						DataRoot,
						EndOffset,
						TXSize,
						DataPathHash,
						DataPath,
						byte_size(Chunk),
						Chunk,
						store_data
					)
			end
	end.

store_chunk(
	State,
	DataRootIndexIterator,
	DataRoot,
	EndOffset,
	TXSize,
	DataPathHash,
	DataPath,
	ChunkSize,
	Chunk,
	IndexOnly
) ->
	case next(DataRootIndexIterator) of
		none ->
			{ok, State};
		{{TXRoot, TXStartOffset, TXPath}, UpdatedDataRootIndexIterator} ->
			AbsoluteEndOffset = TXStartOffset + EndOffset,
			case store_chunk(
				State,
				TXSize,
				AbsoluteEndOffset,
				EndOffset,
				DataPathHash,
				DataPath,
				TXRoot,
				DataRoot,
				TXPath,
				ChunkSize,
				Chunk,
				IndexOnly
			) of
				{updated, SyncRecord, CompactedSize} ->
					State2 =
						State#sync_data_state{
							sync_record = SyncRecord,
							compacted_size = CompactedSize
						},
					record_v2_index_data_size(State2),
					store_chunk(
						State2,
						UpdatedDataRootIndexIterator,
						DataRoot,
						EndOffset,
						TXSize,
						DataPathHash,
						DataPath,
						ChunkSize,
						Chunk,
						index_only % We just stored the chunk data.
					);
				not_updated ->
					store_chunk(
						State,
						UpdatedDataRootIndexIterator,
						DataRoot,
						EndOffset,
						TXSize,
						DataPathHash,
						DataPath,
						ChunkSize,
						Chunk,
						IndexOnly
					);
				{error, _Reason} ->
					{{error, failed_to_store_chunk}, State}
			end
	end.

write_chunk(ChunkDataIndex, DataPathHash, Chunk, DataPath) ->
	ar_kv:put(ChunkDataIndex, DataPathHash, term_to_binary({Chunk, DataPath})).

pick_missing_blocks([{H, WeaveSize, _} | CurrentBI], BlockTXPairs) ->
	{After, Before} = lists:splitwith(fun({BH, _}) -> BH /= H end, BlockTXPairs),
	case Before of
		[] ->
			pick_missing_blocks(CurrentBI, BlockTXPairs);
		_ ->
			{WeaveSize, lists:reverse(After)}
	end.

cast_after(Delay, Message) ->
	timer:apply_after(Delay, gen_server, cast, [self(), Message]).

process_disk_pool_item(State, Key, Value, NextCursor) ->
	#sync_data_state{
		disk_pool_chunks_index = DiskPoolChunksIndex,
		disk_pool_data_roots = DiskPoolDataRoots,
		data_root_index = DataRootIndex,
		chunk_data_index = ChunkDataIndex
	} = State,
	prometheus_counter:inc(disk_pool_processed_chunks),
	<< Timestamp:256, DataPathHash/binary >> = Key,
	{Offset, Size, DataRoot, TXSize} = binary_to_term(Value),
	DataRootKey = << DataRoot/binary, TXSize:?OFFSET_KEY_BITSIZE >>,
	InDataRootIndex = ar_kv:get(DataRootIndex, DataRootKey),
	InDiskPool = maps:is_key(DataRootKey, DiskPoolDataRoots),
	case {InDataRootIndex, InDiskPool} of
		{not_found, true} ->
			%% Increment the timestamp by one (microsecond), so that the new cursor is
			%% a prefix of the first key of the next data root. We want to quickly skip
			%% the all chunks belonging to the same data root for now.
			{noreply, State#sync_data_state{
				disk_pool_cursor = {seek, << (Timestamp + 1):256 >>}
			}};
		{not_found, false} ->
			ok = ar_kv:delete(DiskPoolChunksIndex, Key),
			prometheus_gauge:dec(disk_pool_chunks_count),
			delete_chunk(ChunkDataIndex, DataPathHash),
			{noreply, State#sync_data_state{ disk_pool_cursor = NextCursor }};
		{{ok, DataRootIndexValue}, _} ->
			State2 =
				case store_chunk(
					State,
					data_root_index_iterator(binary_to_term(DataRootIndexValue)),
					DataRoot,
					Offset,
					TXSize,
					DataPathHash,
					no_data_path,
					Size,
					no_chunk,
					index_only
				) of
					{ok, State3} ->
						State3;
					{{error, Reason}, State3} ->
						ar:err([
							{event, failed_to_record_disk_pool_chunk_offsets},
							{reason, Reason},
							{data_path_hash, ar_util:encode(DataPathHash)}
						]),
						State3
				end,
			case InDiskPool of
				false ->
					ok = ar_kv:delete(DiskPoolChunksIndex, Key),
					prometheus_gauge:dec(disk_pool_chunks_count);
				true ->
					do_not_remove_from_disk_pool_chunks_index
			end,
			{noreply, State2#sync_data_state{ disk_pool_cursor = NextCursor }}
	end.

get_tx_data_from_chunks(ChunkDataIndex, Offset, Size, Map) ->
	get_tx_data_from_chunks(ChunkDataIndex, Offset, Size, Map, <<>>).

get_tx_data_from_chunks(_ChunkDataIndex, _Offset, 0, _Map, Data) ->
	{ok, iolist_to_binary(Data)};
get_tx_data_from_chunks(ChunkDataIndex, Offset, Size, Map, Data) ->
	case maps:get(<< Offset:?OFFSET_KEY_BITSIZE >>, Map, not_found) of
		not_found ->
			{error, not_found};
		Value ->
			{DataPathHash, _, _, _, _, ChunkSize} = binary_to_term(Value),
			case read_chunk(ChunkDataIndex, DataPathHash) of
				not_found ->
					{error, not_found};
				{error, Reason} ->
					ar:err([{event, failed_to_read_chunk_for_tx_data}, {reason, Reason}]),
					{error, not_found};
				{ok, {Chunk, _}} ->
					get_tx_data_from_chunks(
						ChunkDataIndex,
						Offset - ChunkSize,
						Size - ChunkSize,
						Map,
						[Chunk | Data]
					)
			end
	end.

data_root_index_iterator(TXRootMap) ->
	{maps:iterator(TXRootMap), none}.

next({TXRootMapIterator, none}) ->
	case maps:next(TXRootMapIterator) of
		none ->
			none;
		{TXRoot, OffsetMap, UpdatedTXRootMapIterator} ->
			OffsetMapIterator = maps:iterator(OffsetMap),
			{Offset, TXPath, UpdatedOffsetMapIterator} = maps:next(OffsetMapIterator),
			UpdatedIterator = {UpdatedTXRootMapIterator, {TXRoot, UpdatedOffsetMapIterator}},
			{{TXRoot, Offset, TXPath}, UpdatedIterator}
	end;
next({TXRootMapIterator, {TXRoot, OffsetMapIterator}}) ->
	case maps:next(OffsetMapIterator) of
		none ->
			next({TXRootMapIterator, none});
		{Offset, TXPath, UpdatedOffsetMapIterator} ->
			UpdatedIterator = {TXRootMapIterator, {TXRoot, UpdatedOffsetMapIterator}},
			{{TXRoot, Offset, TXPath}, UpdatedIterator}
	end.
