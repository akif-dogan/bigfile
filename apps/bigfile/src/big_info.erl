%%%
%%% @doc Gathers the data for the /info and /recent endpoints.
%%%

-module(big_info).

-export([get_info/0, get_recent/0]).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_chain_stats.hrl").

get_info() ->
	{Time, Current} =
		timer:tc(fun() -> big_node:get_current_block_hash() end),
	{Time2, Height} =
		timer:tc(fun() -> big_node:get_height() end),
	[{_, BlockCount}] = ets:lookup(big_header_sync, synced_blocks),
    #{
        <<"network">> => list_to_binary(?NETWORK_NAME),
        <<"version">> => ?CLIENT_VERSION,
        <<"release">> => ?RELEASE_NUMBER,
        <<"height">> =>
            case Height of
                not_joined -> -1;
                H -> H
            end,
        <<"current">> =>
            case is_atom(Current) of
                true -> atom_to_binary(Current, utf8);
                false -> big_util:encode(Current)
            end,
        <<"blocks">> => BlockCount,
        <<"peers">> => prometheus_gauge:value(bigfile_peer_count),
        <<"queue_length">> =>
            element(
                2,
                erlang:process_info(whereis(big_node_worker), message_queue_len)
            ),
        <<"node_state_latency">> => (Time + Time2) div 2
    }.

get_recent() ->
    #{
        %% #{
        %%   "id": <indep_hash>,
        %%   "received": <received_timestamp>",
        %%   "height": <height>
        %% }
        <<"blocks">> => get_recent_blocks(),
        %% #{
        %%   "id": <hash_of_block_ids>,
        %%   "height": <height_of_first_orphaned_block>,
        %%   "timestamp": <timestamp_of_when_fork_was_abandoned>
        %%   "blocks": [<block_id>, <block_id>, ...]
        %% }
        <<"forks">> => get_recent_forks()
    }.

%% @doc Return the the most recent blocks in reverse chronological order.
%% 
%% There are a few list reversals that happen here:
%% 1. get_block_anchors returns the blocks in reverse chronological order (latest block first)
%% 2. [Element | Acc] reverses the list into chronological order (latest block last)
%% 3. The final lists:reverse puts the list back into reverse chronological order
%%    (latest block first)
get_recent_blocks() ->
    Anchors = lists:sublist(big_node:get_block_anchors(), ?CHECKPOINT_DEPTH),
    Blocks = lists:foldl(
        fun(H, Acc) ->
            B = big_block_cache:get(block_cache, H),
            [#{
                <<"id">> => big_util:encode(H),
                <<"received">> => get_block_timestamp(B, length(Acc)),
                <<"height">> => B#block.height
            } | Acc]
        end,
        [],
        Anchors
    ),
    lists:reverse(Blocks).

%% @doc Return the the most recent forks in reverse chronological order.
get_recent_forks() ->
    CutOffTime = os:system_time(seconds) - ?RECENT_FORKS_AGE,
    case big_chain_stats:get_forks(CutOffTime) of
        {error, _} -> error;
        Forks ->
            lists:foldl(
                fun(Fork, Acc) ->
                    #fork{ 
                        id = ID, height = Height, timestamp = Timestamp, 
                        block_ids = BlockIDs} = Fork,
                    [#{
                        <<"id">> => big_util:encode(ID),
                        <<"height">> => Height,
                        <<"timestamp">> => Timestamp div 1000,
                        <<"blocks">> => [ big_util:encode(BlockID) || BlockID <- BlockIDs ]
                    } | Acc]
                end,
                [],
                lists:sublist(Forks, ?RECENT_FORKS_LENGTH)
            )
    end.

get_block_timestamp(B, Depth)
        when Depth < ?RECENT_BLOCKS_WITHOUT_TIMESTAMP orelse
            B#block.receive_timestamp =:= undefined ->
    <<"pending">>;
get_block_timestamp(B, _Depth) ->
    big_util:timestamp_to_seconds(B#block.receive_timestamp).

