# 0063: Other forms of a word are found by the query, not by the index

Status: accepted

## Context

"how to program in c" did not find the page that teaches C programming because the page says "programming" and the search asked for "program". Stemming in the index (`[index] tokenizer = "porter"`) answers that, but it needs a rebuild of the whole index, stems only English well, and makes excerpts come from SQLite's `snippet()`, which is the slow path ADR 0056 removed.

## Decision

With `[search] word_forms` (on by default) a plain word of at least five letters is searched as `"word" OR "stem"*`, where the stem comes from a plain English suffix strip (`wordforms.zig`: ing, ed, er, es, s, ion, ly, ment, ness...; doubled consonants and a final e are dropped; stems of fewer than five letters are not used). Quoted phrases, `-` words, short words and words with a field stay as typed. The excerpt looks for any word that begins with the stem.

## Consequences

No rebuild and no change to the index. A search may also match words that merely share a stem ("frobnicate" finds "frobnicator"); the exact word still ranks by its own score. Prefix matches read more of the index than one word does, so very short stems are not used. English only. Turn it off with `word_forms = false`.
