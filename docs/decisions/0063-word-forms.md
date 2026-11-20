# 0063: Other forms of a word are found by the query, not by the index

Status: accepted as an opt-in option (off by default); measured and found to make ranking worse

## Context

"how to program in c" did not find the page that teaches C programming because the page says "programming" and the search asked for "program". Stemming in the index (`[index] tokenizer = "porter"`) answers that, but it needs a rebuild of the whole index, stems only English well, and makes excerpts come from SQLite's `snippet()`, which is the slow path ADR 0056 removed.

A first try searched `"stem"*`. It found the page, but a prefix also matches words that only start the same ("comprehension" and "comprehensive"), and because a prefix counts as one term, the rarity of the exact word was lost: the Python glossary, the one page that defines "list comprehension", fell from first to eleventh. Asking for the word and its prefix together counted every occurrence twice.

## Decision

With `[search] word_forms` (on by default) a plain word of at least five letters is looked up in the index's own vocabulary (`fts_vocab`, the words that begin with its stem: a plain English suffix strip, see `wordforms.zig`). The words that are the stem plus an ending from a short list (s, es, ed, ing, er, ers, ion, ions, ation, ly, ment, ness...; a doubled last consonant allowed) are other forms. The query searches the typed word and up to seven of the commonest forms as separate words, `("program" OR "programming" OR "programs")`, so each counts by how rare it is. Quoted phrases, `-` words, short words and words with a field stay as typed; a word with no other form is searched as typed. The excerpt highlights every form that was searched.

## Consequences

No rebuild and no change to the index; one small vocabulary lookup per word. English only. Turn it off with `word_forms = false`.

## Measurement

With the golden queries of the playground index (`dksearch eval`, 11 queries, pictures left out, one result per page, English preferred): word forms off, mean reciprocal rank 0.657 and mean nDCG@10 0.718; on, 0.348 and 0.420. The searches that lost were those where the right page matches every word once and other pages repeat one word's forms many times ("linux kernel scheduler": pages about Kubernetes scheduling, which repeat schedule/scheduling/scheduler, outranked the kernel documentation). Best-match scoring adds up the weights of the forms as if they were different words, where a stemming index counts one word. So the default is off and the answer to "program does not find programming" is an index that stems (`[index] tokenizer = "porter"`), measured separately.

## The stemming index, measured

The playground's stored texts (414,489 documents) were rebuilt with `[index] tokenizer = "porter"` on a copy (19 minutes) and run through the same golden queries. "how to program in c" now finds the C course (rank 7, was not in the first 100), but "python list comprehension" lost the glossary page and "learn c programming" fell from first to second; mean reciprocal rank 0.530 against 0.657 for the unstemmed index. The golden set is small (11) and biased toward queries the unstemmed index already answers, so it cannot show stemming to be a win or a loss; with excerpts also going back to SQLite's slow `snippet()` and a full rebuild needed, the default stays unstemmed. The next step is a larger, unbiased set of judged queries, taken from real searches.

## Forms in the title only, with the owner's marks

A last variant searched the typed word anywhere and its other forms only in the title (`"program" OR title : ("programming" OR "programs")`), meant for pages like "C (programming language)". Against the golden queries with the owner's first marks (the Wikipedia article on C and the edX course wanted for "how to program in c", the Avalon file listing and "Meeting C++ program" not), it scored a mean reciprocal rank of 0.438 against 0.667 without it; the Wikipedia article moved from tenth to seventh, and "context switch", "learn c programming" and "linux kernel scheduler" fell. It was not kept. Query-side word forms stay an option (`word_forms`, off); the lexical engine does not answer "how to program in c" well, and meaning-based ranking (ADR 0038) is what is meant for questions put in plain words.
