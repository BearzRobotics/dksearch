# 0013. Optional English stemming

- Status: Accepted (2026-11-14), after the maintainer agreed to the proposal ("the rest seems good to me"): keep `unicode61` as the default and make stemming a configuration choice
- Date: 2026-11-14

## Context

English was chosen first. The index used only the `unicode61` tokenizer, which folds case and diacritics but treats "run", "running" and "runs" as different words. SQLite FTS5 ships a `porter` wrapper that stems English words.

## Decisions

1. **`[index] tokenizer = "unicode61" | "porter"`**, default `unicode61`. `porter` is `porter unicode61 remove_diacritics 2`: the same splitting and folding, plus English stemming at both index and query time.
2. **Not the default**, because stemming changes ranking and matching in ways that are wrong for other languages and for exact terms (names, code), and the choice should be the administrator's.
3. **The index remembers its tokenizer.** The tokenizer lives in the FTS table's definition, so no schema version change was needed and existing indexes keep working. Opening an index with a different tokenizer than the configuration asks for is refused with a message to run `dksearch rebuild`; `rebuild` is the one command allowed to drop and recreate the index with the new tokenizer, then refills it from the retained content. `check` and tests that state no preference keep whatever the index has.
4. Other languages, and languages without word separators, are still not handled; the FTS5 `trigram` tokenizer is the likely route when someone needs it.

## Consequences

Switching is a configuration edit plus one `rebuild`, with no re-import, because the index is derived data. Result counts for the same query can differ between the two settings, so any saved expectations about results should be re-checked after switching.
