-module(ar_kv_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-include_lib("bigfile/include/ar_sup.hrl").
-include_lib("bigfile/include/ar_config.hrl").

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks.
%% ===================================================================

init([]) ->
	ar_kv:create_ets(),
	{ok, {{one_for_one, 5, 10}, [?CHILD(ar_kv, worker)]}}.
