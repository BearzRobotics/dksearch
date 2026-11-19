# 0063: Other forms of a word are found by the query, not by the index

Status: accepted

## Context

"how to program in c" did not find the page that teaches C programming because the page says "programming" and the search asked for "program". Stemming in the index (`[index] tokenizer = "porter"`) answers that, but it needs a rebuild of the whole index, stems only English well, and makes excerpts come from SQLite's `snippet()`, which is the slow path ADR 0056 removed.

A first try searched `"stem"*`. It found the page, but a prefix also matches words that only start the same ("comprehension" and "comprehensive"), and because a prefix counts as one term, the rarity of the exact word was lost: the Python glossary, the one page that defines "list comprehension", fell from first to eleventh. Asking for the word and its prefix together counted every occurrence twice.

## Decision

With `[search] word_forms` (on by default) a plain word of at least five letters is looked up in the index's own vocabulary (`fts_vocab`, the words that begin with its stem: a plain English suffix strip, see `wordforms.zig`). The words that are the stem plus an ending from a short list (s, es, ed, ing, er, ers, ion, ions, ation, ly, ment, ness...; a doubled last consonant allowed) are other forms. The query searches the typed word and up to seven of the commonest forms as separate words, `("program" OR "programming" OR "programs")`, so each counts by how rare it is. Quoted phrases, `-` words, short words and words with a field stay as typed; a word with no other form is searched as typed. The excerpt highlights every form that was searched.

## Consequences

No rebuild and no change to the index; one small vocabulary lookup per word. English only. Turn it off with `word_forms = false`.
