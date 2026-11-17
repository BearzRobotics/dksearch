# 0036: Conditional requests when crawling again

Status: implemented for pages at the depth limit.

## Context

A recrawl downloads every page again even when almost none changed. HTTP has validators (`ETag`, `Last-Modified`) so that a server can answer 304 without a body. The crawler could not use them: connectors do not see the state of earlier runs, and a 304 has no body, so no links can be taken from it.

## Decision

- A source option `validators_file` names a file the crawler keeps itself: `URL<TAB>ETag<TAB>Last-Modified`, loaded at the start of a run, replaced atomically at the end (a partial run keeps the validators of pages it did not reach).
- Conditional requests are made only for pages at the depth limit: they follow no links, so a 304 loses nothing. These are most of the pages of a typical crawl (every page with `max_depth = 0`, the last level otherwise) and sitemap-listed pages. A page that is not at the limit is always fetched in full.
- A 304 is neither stored nor counted as a refusal. A page that answers 200 is processed as before, and its validators replace the old ones; the pipeline's own content hash still decides whether the stored document changed.
- Only the first request of a redirect chain is conditional (the validators belong to the first address).
- Nothing is persisted when `validators_file` is not set, so the feature is off by default and a damaged file only costs bandwidth.

## Alternatives

- Keeping the outgoing links of every page so interior pages could be skipped too: the file would be as large as the link graph, for the sake of a smaller share of pages.
- Keeping validators in `state.db`: needs the connector interface to read prior state; a bigger change for the same result.
- Sitemap `lastmod` instead: only for sites that publish one and trust it; compatible with this and can be added.

## Consequences

- A crawl with `max_depth = 2` saves downloads only at the last level, which is where most pages are.
- Sites that send no validators are fetched in full, as before.
