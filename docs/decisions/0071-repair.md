# 0071: Repairing what was stored before the crawler learned better

Status: accepted

## Context

The crawler improved during ADRs 0058 and 0061: it tidies addresses (dot segments, tracking and session parameters), decodes more HTML entities in titles and records a page's language. Documents stored earlier kept what they had: on the playground index, 1,433 titles with `&bull;` and the like, 981 crawl pages at addresses the crawler would no longer use (so the same page was stored again under its tidy address: `dragonflybsd.org/./features/` and `/features/`), and pages with no language, so the ranking of ADR 0061 could not tell a Russian page from an English one.

## Decision

`dksearch repair [--dry-run]` works on the documents of the crawl sources only, without fetching anything (`src/repair.zig`). A first phase reads every record and plans the fixes (`--dry-run` stops there, and can run while `serve` runs); a second applies them in batches in the importer's commit order, with the writers' lock, so it can be interrupted and repeated:

- titles with HTML entities are decoded;
- a document whose address is not tidy is removed if the page is already stored at the tidy address, else moved to it (a new id from the tidy address, the same text and record);
- a page with no language gets one from the first part of its address, else from the script of its text (`langprefer.languageOfText`: Chinese, Japanese, Korean, Hebrew, Greek and Thai by name, `und-Cyrl`, `und-Arab` and `und-Deva` for scripts several languages share). Latin text is left alone: a Latin text could be any of dozens of languages.

A document whose text is not retained is left as it is.

## Consequences

On the playground: 1,433 titles, 981 addresses (166 duplicates removed, 815 moved) and 2,491 languages, in 104 seconds; a second dry run found nothing more but two languages. A verified backup of the records (`dksearch backup`) was taken first. The language of Latin-script pages is still unknown unless the page said it, so a French page without `lang` is not demoted by the language factor.
