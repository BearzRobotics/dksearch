# 0024. Query language and typo tolerance

- Status: Accepted (2026-11-15), the user's requests: the advanced syntax table (phrase, AND, OR, NOT, grouping, prefix, fuzzy, proximity, +, -) and typo tolerance without anyone opting in
- Date: 2026-11-15

## Context

User text was never interpreted: every word was quoted, operators were ordinary words (a deliberate safety choice, ADR 0003 and the manual). The user asked for a real query language and, separately, said people should not have to opt into typo tolerance, "especially in domains you are not familiar with".

## Decisions

1. **A small parser (`queryparse.zig`) writes the FTS5 expression; the user never does.** Words, phrases, prefixes, fuzzy words and proximity groups are always emitted as double-quoted FTS5 strings; the only operators in the output are `AND`, `OR`, `NOT`, `NEAR(..., n)` and parentheses, which the parser itself chooses. Column filters (`title:x`), `^` and every other FTS5 construct stay inert text. A randomised test checks that, outside quoted strings, nothing but those operators can appear, and another that SQLite accepts every expression it produces.
2. **Forgiving, bounded.** A stray `)` is ignored, a missing one supplied; operators are operators only in capitals (`and` stays a word, and `"OR"` in quotes is the word). 1024 bytes, 32 terms, 8 levels, a cap on expression size. Only negative terms is an `empty_query` error. `[search] query_syntax = "simple"` restores the old behaviour.
3. **AND binds tighter than OR** (as in FTS5 and most search engines); a negative group is emitted as `(positives) NOT (negatives)` so SQLite's precedence cannot change the meaning.
4. **Fuzzy = one edit (superseded for indexes with a vocabulary: see ADR 0031).** FTS5 has no edit distance, so `word~` expands to the word plus every word one edit away (deletion, neighbour swap, substitution, insertion over a-z and 0-9), as an OR of quoted terms: at most about a thousand terms for the longest word allowed (12 letters; plain letters and digits only; three letters or more when written `word~`, four or more when applied automatically). Two typos in one word are not caught; catching them would need the index's vocabulary (fts5vocab) and an edit-distance scan, which is a possible later step.
5. **Typo tolerance on by default, without a switch.** `[search] fuzzy = "auto"`: an exact search that finds fewer than 3 results is repeated with every eligible word made fuzzy, and the fuller result is used if it finds more; the response carries `fuzzy: true` and the page says "Showing results that include similar spellings" with a "Search exactly as typed" link. `always` and `off` exist for operators. A bare `SqliteIndex` stays exact (so library users and tests get exact words); `serve` applies the configuration.
6. **Transparency.** When a query used the language or typo tolerance, the page and API say how it was read (`interpreted`, "Searching for: linux OR bsd NOT android"), and `/help/search` and `/help/regex` explain the syntax and the regex filter (with this server's limits).

## Cost

An automatic retry doubles the work of a search that found little; the existing per-search time limit (ADR 0021) bounds it. Expanded terms that do not exist in the index cost one failed lookup each.

## Not done

Edit distance 2; stop-word handling; synonyms; spelling suggestions ("did you mean") as a separate hint; fielded search (`title:`) as a feature.
