# 0056: Search speed on a large index: common words and excerpts

Status: accepted

## Context

On an index of 365,000 documents, "how to program in c" took 9.4 s and failed with "the search took too long", while "how to program" took 0.2 s. A profile of the running server (perf, user-space samples) showed all the time inside SQLite's `snippet()`: 75% iterating the occurrences of the matched words and 25% scoring excerpt windows. Its cost grows with the square of the occurrences of a word in a document, and "in" occurs thousands of times in a long article. Matching and ranking took milliseconds.

## Decision

- A plain word in more than `[search] common_word_percent` (default 15) of the documents, by the document counts of the index's vocabulary table, is left out of the required words when the query has other words. The page and the API say which were left out. Phrases, `title:` words, excluded words and queries of only common words are searched as typed.
- Excerpts are made by `snippets.bestExcerpt` from the text in the index: one pass, linear in the text, whatever the word. A stemmed (`porter`) index keeps SQLite's function, which knows the stems.
- The answers of the domain lists are remembered per domain for each connection (`Memo`): a search that matches hundreds of thousands of documents asked the same few domains over and over, and each answer cost several hash look-ups and, for hashed lists, an MD5.

## Consequences

"how to program in c" takes about 0.3 s. A query of only very common words ("the") is still slow (about 3 s on 365,000 documents) because ranking has to read their position lists; its excerpt no longer is. A query that really needs "in" must put it in quotes. The threshold is a share of the documents, so a small index is unaffected.
