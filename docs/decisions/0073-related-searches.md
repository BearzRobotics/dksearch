# 0073: Related searches from the titles of the results

Status: accepted

## Context

dksearch keeps no history of searches, so "what others searched for" cannot be offered. Refinements of a search can still be taken from the results themselves.

## Decision

Under the results of a plain search (first page, five or more results, no operators) the page offers up to six words that recur in the titles of the results (`related.zig`): in at least two results on at least two sites, not a word of the query or a form of one, not a filler or dull word ("documentation", "wiki", "guide"), and not in most of the titles (that is the topic of the whole search). Each is a link that searches again with the word added.

## Consequences

It costs nothing (the titles are already in hand) and cannot reveal anything about what anyone searched. Its suggestions are only as good as the titles: they have not yet been judged on real searches.
