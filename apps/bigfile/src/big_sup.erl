%% This Source Code Form is subject to the terms of the GNU General
%% Public License, v. 2.0. If a copy of the GPLv2 was not distributed
%% with this file, You can obtain one at
%% https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html

-module(big_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("bigfile/include/big.hrl").
-include_lib("bigfile/include/big_sup.hrl").
-include_lib("bigfile/include/big_config.hrl").

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
	%% These ETS tables should belong to the supervisor.
	ets:new(big_peers, [set, public, named_table, {read_concurrency, true}]),
	ets:new(big_http, [set, public, named_table]),
	ets:new(big_blacklist_middleware, [set, public, named_table]),
	ets:new(blacklist, [set, public, named_table]),
	ets:new(ignored_ids, [bag, public, named_table]),
	ets:new(ar_tx_emitter_recently_emitted, [set, public, named_table]),
	ets:new(big_tx_db, [set, public, named_table]),
	ets:new(big_packing_server, [set, public, named_table]),
	ets:new(replica_2_9_entropy_cache, [set, public, named_table]),
	ets:new(replica_2_9_entropy_cache_ordered_keys, [ordered_set, public, named_table]),
	ets:new(big_nonce_limiter, [set, public, named_table]),
	ets:new(big_nonce_limiter_server, [set, public, named_table]),
	ets:new(big_header_sync, [set, public, named_table, {read_concurrency, true}]),
	ets:new(big_data_discovery, [ordered_set, public, named_table, {read_concurrency, true}]),
	ets:new(big_data_sync_worker_master, [set, public, named_table]),
	ets:new(big_data_sync_state, [set, public, named_table, {read_concurrency, true}]),
	ets:new(big_chunk_storage, [set, public, named_table]),
	ets:new(big_entropy_storage, [set, public, named_table]),
	ets:new(big_mining_stats, [set, public, named_table]),
	ets:new(big_global_sync_record, [set, public, named_table]),
	ets:new(big_disk_pool_data_roots, [set, public, named_table, {read_concurrency, true}]),
	ets:new(big_tx_blacklist, [set, public, named_table, {read_concurrency, true}]),
	ets:new(big_tx_blacklist_pending_headers,
			[set, public, named_table, {read_concurrency, true}]),
	ets:new(big_tx_blacklist_pending_data,
			[set, public, named_table, {read_concurrency, true}]),
	ets:new(big_tx_blacklist_offsets,
			[ordered_set, public, named_table, {read_concurrency, true}]),
	ets:new(big_tx_blacklist_pending_restore_headers,
			[ordered_set, public, named_table, {read_concurrency, true}]),
	ets:new(block_cache, [set, public, named_table]),
	ets:new(tx_prefixes, [bag, public, named_table]),
	ets:new(block_index, [ordered_set, public, named_table]),
	ets:new(node_state, [set, public, named_table]),
	ets:new(mining_state, [set, public, named_table, {read_concurrency, true}]),
	Children = [
		?CHILD(big_rate_limiter, worker),
		?CHILD(big_disksup, worker),
		?CHILD_SUP(big_events_sup, supervisor),
		?CHILD_SUP(big_http_sup, supervisor),
		?CHILD_SUP(big_kv_sup, supervisor),
		?CHILD_SUP(big_storage_sup, supervisor),
		?CHILD(big_peers, worker),
		?CHILD(big_disk_cache, worker),
		?CHILD(big_watchdog, worker),
		?CHILD(big_tx_blacklist, worker),
		?CHILD_SUP(big_bridge_sup, supervisor),
		?CHILD(big_packing_server, worker),
		?CHILD_SUP(big_sync_record_sup, supervisor),
		?CHILD(big_data_discovery, worker),
		?CHILD(big_header_sync, worker),
		?CHILD_SUP(big_data_sync_sup, supervisor),
		?CHILD_SUP(big_chunk_storage_sup, supervisor),
		?CHILD_SUP(big_verify_chunks_sup, supervisor),
		?CHILD(big_global_sync_record, worker),
		?CHILD_SUP(big_nonce_limiter_sup, supervisor),
		?CHILD_SUP(big_mining_sup, supervisor),
		?CHILD(big_coordination, worker),
		?CHILD_SUP(big_tx_emitter_sup, supervisor),
		?CHILD(big_tx_poller, worker),
		?CHILD_SUP(big_block_pre_validator_sup, supervisor),
		?CHILD_SUP(big_poller_sup, supervisor),
		?CHILD_SUP(big_node_sup, supervisor),
		?CHILD_SUP(big_webhook_sup, supervisor),
		?CHILD(big_p3, worker),
		?CHILD(big_p3_db, worker),
		?CHILD(big_pool, worker),
		?CHILD(big_pool_job_poller, worker),
		?CHILD(big_pool_cm_job_poller, worker),
		?CHILD(big_chain_stats, worker)
	],
	{ok, Config} = application:get_env(bigfile, config),
	DebugChildren = case Config#config.debug of
		true -> [?CHILD(big_process_sampler, worker)];
		false -> []
	end,
	{ok, {{one_for_one, 5, 10}, Children ++ DebugChildren}}.
