# 0019. Internet Archive metadata connector

- Status: Accepted (2026-11-15), SPEC milestone 5 ("Internet Archive metadata connector"); implemented
- Date: 2026-11-15

## Context

Milestone 5 lists an Internet Archive metadata connector. The user approved continuing with the remaining milestone items after the crawler (ADR 0018), whose HTTP client, certificate bundle and politeness rules it reuses.

## Decisions

1. **Metadata only.** The connector indexes what the Archive's search service returns for each item (identifier, title, creator, description, subjects, dates, language, license URL, rights statement, media type). It never downloads item files. Full-text indexing of items is a different, much larger job (and the items have their own terms).
2. **The documented scrape search interface** (`/services/search/v1/scrape`) is used, because the older paged search stops at 10,000 results ("deep paging limit", as the service itself says) and the scrape interface pages with a cursor. The cursor is the resume checkpoint, so an interrupted run continues where it stopped.
3. **Live testing changed one decision.** The interface documents a minimum page size of 100, but against the live service (2026-11-15) pages of 200 or fewer ignored the query and repeated the first page for every cursor (silently: the run "succeeded" with duplicates), while 1000 or more paged correctly. The connector therefore never asks for fewer than 1000 items per request. This was found only by running against the real service: the offline tests, whose server I wrote, could not have shown it. A reminder that the offline fixtures encode my understanding of an API, not the API.
4. **Opt-in and polite**, like the crawler: required `user_agent`, `delay_ms` between requests (default 1000), per-request deadline, response size cap (64 MiB), HTTPS verified against the bundled roots, no proxy. It is built with `-Dcrawler` (default on), which now means "the network connectors".
5. **`max_items` defaults to 10,000.** Collections can hold millions of items; a forgotten default should not become a multi-hour crawl of someone else's service. When the limit is hit the run ends as completed and the next run starts over (same items first); the pipeline skips unchanged ones. Raising it is the administrator's decision.
6. **Rights are `unknown`.** The metadata does not say what may be done with an item. `licenseurl` and the `rights` text are recorded for reference.
7. **Failure handling.** An item with no usable identifier or no text is counted as skipped (`limit`, `no_text`). A failed request after the first page fails the run with the cursor saved; a first request that cannot connect is Offline; a non-success answer (including "too many requests") is a failure to retry later.

## Not done

Following an item's own files; incremental runs by date (`publicdate` ranges) so that a large collection can be kept current without re-reading it; per-collection rate settings; the Archive's authenticated APIs.
