# 0069: A search of only common words is a phrase, or not ranked

Status: accepted

## Context

"the" and "a" took 5.0 seconds (the query time limit) and "to be or not to be" 2.0 seconds on the 414,000-document playground index, against a median of 47 ms for ordinary searches (35 queries, `crap` and `curl` against the live server). When every word of a query is too common to leave out (ADR 0056) or a question word (ADR 0062), the query is searched as typed, and ranking millions of matches is what took the time. A profile showed the rest: the per-domain step (ADR 0061) reads up to `max_cursor_window` (100,000) rows before it applies its window.

## Decision

For such a "heavy" search of two or more plain words, the words are first searched as one phrase (`"to be or not to be"`), which is selective and ranked as usual. When there is no phrase hit, and for a single word, the matches are not ranked: the most recently stored documents come first (`ORDER BY rowid DESC`, which SQLite can stop reading after a page) and the per-domain window is skipped.

## Consequences

Measured with `crap` (wall time of the request through `curl`, live index): "the" 5.21 s to 9.5 ms; "to be or not to be" 2.03 s to 0.37 s; "linux kernel scheduler" 49 ms to 47 ms (not affected). The results of a search for "the" are arbitrary by nature and are now said to be so by being unranked; a famous line is found as a phrase.
