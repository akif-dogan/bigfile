%%
%% This file is loaded upon starting Erlang REPL, and loads all the records
%% from user_default.hrl file.
%% Another possibility is to add some broadly-user functions here: these
%% functions will be useable from the REPL as first-class commands. As an
%% example, running the `config().` in the REPL will return current node config.
%%

-module(user_default).
-include_lib("bigfile/include/user_default.hrl").
-compile([export_all, nowarn_export_all]).



config() ->
  {ok, Config} = application:get_env(bigfile, config),
  Config.
