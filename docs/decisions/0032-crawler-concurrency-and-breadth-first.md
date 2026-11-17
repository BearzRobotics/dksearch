# 0032: Crawler concurrency and breadth-first order

Status: implemented. Supersedes the "one at a time, no concurrency" rule of ADR 0018 for the crawl as a whole (the rule for a single site stays).

## Context

A head-to-head with YaCy on the same 785 seeds (`docs/research/crawl-comparison.md`) showed dksearch fetching about 0.1 pages per second against YaCy's 2.6 real pages per second: the crawler did everything serially, so each slow answer, each new site's `robots.txt` and each politeness wait stalled the whole run. A first concurrent version was fast but narrow (it went deep into the first seeds), and plain levels let all workers pile up behind the lock of one popular site.

## Decision

- **Workers.** `workers` (default 8, 1 to 64) tasks fetch at the same time, each with its own HTTP client. They share the table of sites (and their parsed `robots.txt`), the set of addresses already seen, and the page budget; the pipeline's sink is serialised by a lock.
- **Politeness stays per site.** A site has a lock held while it is being asked, through the wait for its turn and the request, so one worker at a time talks to a site and requests stay at least `delay_ms` (or the site's `crawl-delay`) apart. A new site's lock is taken before anyone can find it and released when its `robots.txt` has been read.
- **Breadth-first inside windows.** Seeds are taken `window` at a time (default 100; 0 = all). Inside a window every seed's first page is fetched, then every page one link away, and so on; each level is spread over the workers with consecutive pages from different seeds. A worker that meets a page whose site is being asked sets it aside and takes other work (the set-aside pages are fetched when the level's queue is empty).
- **Resume.** The position is the last seed before which every seed is finished; a window finishes all its seeds together, so an interrupted crawl repeats at most its current window (the pipeline skips unchanged pages). `window = 1` gives the old per-seed behaviour.
- **Text.** Found while comparing extracted text with YaCy's: a `>` inside a quoted attribute value must not end a tag (embedded JSON and inline SVG leaked into the text). Fixed in `htmltext.zig` with a budget against unclosed quotes.

## Alternatives

- A global frontier ordered by depth across all seeds: the best breadth, but a crawl could not resume except from the start.
- Per-seed page caps: simple, but arbitrary, and still serial within a seed.
- One task per page with a work-stealing pool: more machinery than the level structure needs.

## Consequences

- Measured on the same seeds in six minutes: 3,085 real pages against YaCy's 855, 123 seed addresses against 131, 389 sites against 541. A larger `window` would raise the sites count.
- A level ends only when its last page is done, so one very slow site delays the next level (the per-request timeout bounds it).
- Counters shown while a crawl runs still lag by the pipeline's batch size.
- Many workers hitting many sites raise the load on the machine and the network; the default of 8 is a compromise and the per-site rules are unchanged.
