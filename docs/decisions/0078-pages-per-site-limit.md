# 0078: A limit of pages per site in a run

Status: accepted

## Context

The crawler goes level by level and asks one site at a time, with `delay_ms` (or the site's `Crawl-delay`) between requests. A stack dump of the owner's playground during an apparent stall (no new document for nine hours) showed a level of 87,626 pages of which 64,547 were queued behind one site, `devdocs.io`, which is also rendered by a headless browser (ADR 0060). One worker was making progress on it, a page every ten to fifteen seconds; the other five were blocked on that site's lock, and every other source waited behind the job. At that rate the level would take days. It was not a deadlock, and the refusal limit added earlier the same day (a site that refuses six times in a row is given up for the run) was not the cause.

## Decision

A new crawl option, `max_pages_per_host` (no limit by default), caps the requests one site receives in a run. Once a site has had that many, its remaining pages are skipped (counted as `limit` in the report) without waiting. Like `max_pages`, the same pages come first next time, so a very large site is covered by its top pages in each run rather than in full; a site that matters more can be given its own source with a higher limit.

## Consequences

- One huge site can no longer hold the crawl for days. The cost is that pages beyond the cap on such sites are not reached until the limit is raised.
- The option is in the administration interface's source form (`optioninfo.zig`) and the manual.
- The run-level options (`max_pages`, `max_hosts`) are unchanged.
