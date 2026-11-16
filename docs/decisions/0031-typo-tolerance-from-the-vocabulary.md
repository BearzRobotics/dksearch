# 0031: Typo tolerance from the index's vocabulary (edit distance 2)

Status: implemented. Supersedes decision 4 of ADR 0024 (fuzzy = one edit).

## Context

ADR 0024 expanded a fuzzy word into every spelling one edit away, because FTS5 has no edit distance. Two typos in one word were not caught, and the expansion was an OR of up to a thousand terms most of which are not words. The Lucene study (`docs/research/lucene.md`) showed that Lucene reaches distance two cheaply by matching against the terms that actually exist in the index.

## Decision

- The index keeps an `fts5vocab` virtual table over its full-text table (`fts_vocab`, the index's words with their document counts; created when the index is opened for writing, derived data, nothing to rebuild).
- A fuzzy word is looked up in that vocabulary with a bounded edit distance (insertion, deletion, substitution, swap of neighbours; counted on characters; SQL function `dk_edits`, `src/editdistance.zig`). Words that begin with the same letter are scanned first (a range of the vocabulary); only if there are none are all words of about the same length looked at. The closest, then the most common, twelve are OR-ed with the word itself. The scan has a time limit (at most 1.5 seconds, inside the search's own).
- Allowed edits: one for words of three to five letters, two from six, unless the query says `word~1` or `word~2`. Automatic typo tolerance (few results) uses the same rule.
- An index without the vocabulary table (opened read-only before being opened for writing once) falls back to the old generation of variants.

## Consequences

- Searches are smaller (a dozen real words instead of hundreds of candidates) and catch two typos.
- A typo in the first letter of a long word with a same-first-letter neighbour in the index finds only those neighbours (the second tier runs only when the first finds nothing). Accepted: most typos keep the first letter.
- Words longer than 48 characters, or not valid UTF-8, are not matched fuzzily.
- The vocabulary scan costs time proportional to the number of words with the same first letter and similar length; on very large indexes it is the slowest part of a typo-tolerant search (measure on English Wikipedia before relying on it for `fuzzy = "always"`).
