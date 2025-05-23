% 25 checkpoints 40 ms each = 1000 ms
-define(VDF_CHECKPOINT_COUNT_IN_STEP, 25).

-define(VDF_BYTE_SIZE, 32).

%% Typical ryzen 5900X iterations for 1 sec
-define(VDF_SHA_1S, 15_000_000).

-ifndef(VDF_DIFFICULTY).
	-define(VDF_DIFFICULTY, ?VDF_SHA_1S div ?VDF_CHECKPOINT_COUNT_IN_STEP).
-endif.

-ifdef(BIG_TEST).
	% NOTE. VDF_DIFFICULTY_RETARGET should be > 10 because it's > 10 in mainnet
	% So VDF difficulty should change slower than difficulty
	-define(VDF_DIFFICULTY_RETARGET, 720).
	-define(VDF_HISTORY_CUT, 50).
-else.
	-ifndef(VDF_DIFFICULTY_RETARGET).
		-define(VDF_DIFFICULTY_RETARGET, 720).
	-endif.
	-ifndef(VDF_HISTORY_CUT).
		-define(VDF_HISTORY_CUT, 50).
	-endif.
-endif.


