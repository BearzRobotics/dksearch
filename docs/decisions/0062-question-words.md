# 0062: Question and filler words are not required

Status: accepted

## Context

"how to program in c" found nothing useful on the playground index: every word was required, so only pages that said "how", "to", "program", "in" and "c" matched, and the page that teaches C programming does not say "how". ADR 0056 already left out words that occur in over 15% of documents, which catches "to" and "in" but not "how". A golden query (`dksearch eval`) showed the C course outside the first 100 results.

## Decision

A fixed list of English question and filler words (how, what, why, when, where, which, who, is, are, do, can, to, in, of, a, the...) is treated like a very common word: not required when the query has other words, listed as ignored on the results page, never applied to quoted phrases, `title:` words or excluded words, and a query of only such words is searched as typed. It applies when the common-word rule is on (`[search] common_word_percent` above 0).

## Consequences

A search for the band "The Who" is searched as typed (all words are fillers). A query such as "who wrote hamlet" becomes "wrote hamlet", which is what is meant. The list is English only; other languages rely on the frequency rule.

## Spelling repeats and suggestions

A search that found nothing is repeated with typo tolerance (ADR 0003-era `fuzzy = auto`), and the page offers "Did you mean". Both used to respell every word: "what lanague is linux written in" became "wheat langue is linus witten in", and found nothing. Now a word the index has is never respelled (`WordKind.known`), question and filler words are left out of the repeat as in the first search, a word that is not in the index may be three edits away when it is seven letters or more ("lanague" is three from "language"), and the suggestion respells only the words the index lacks.
