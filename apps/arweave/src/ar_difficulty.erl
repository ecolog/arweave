-module(ar_difficulty).

-export([next_cumulative_diff/3, twice_smaller_diff/1, multiply_diff/2]).

-include_lib("arweave/include/ar.hrl").

%% @doc Calculate the cumulative difficulty for the next block.
next_cumulative_diff(OldCDiff, NewDiff, Height) ->
	case Height >= ?FORK_1_6 of
		true ->
			next_cumulative_diff2(OldCDiff, NewDiff, Height);
		false ->
			0
	end.

next_cumulative_diff2(OldCDiff, NewDiff, Height) ->
	Delta = case Height >= ar_fork:height_1_8() of
		false ->
			NewDiff * NewDiff;
		true  ->
			MaxDiff = ar_mine:max_difficulty(),
			%% The number of hashes to try on average to find a solution.
			erlang:trunc(MaxDiff / (MaxDiff - NewDiff))
	end,
	OldCDiff + Delta.

%% @doc Get a difficulty that makes it twice easier to mine.
twice_smaller_diff(Diff) ->
	MaxDiff = ar_mine:max_difficulty(),
	MaxDiff - 2 * (MaxDiff - Diff).

%% @doc Get a difficulty that makes it harder to mine
%% by `Multiplier` number of times.
multiply_diff(Diff, Multiplier) ->
	MaxDiff = ar_mine:max_difficulty(),
	MaxDiff - erlang:trunc(1 / Multiplier * (MaxDiff - Diff)).
