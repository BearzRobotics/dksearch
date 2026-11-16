# Apache Nutch

Status: not started. Research order: 3 of 10.

- Focus: Crawler state and ingestion architecture.
- Source: <https://github.com/apache/nutch>
- Version or commit examined: (to be recorded)

## What to examine

- Crawl database and URL states
- Fetch lists, scheduling, politeness, retries
- Recrawl intervals and incremental fetching
- Parsing pipeline and plugins

## Experiments planned

- [ ] Crawl a small local site; stop and restart; change pages; test redirects, duplicates, robots.txt

## Findings

(Nothing yet. Record observations from the source and from experiments here, with file names and commit.)

## Useful patterns

## Limitations and trade-offs

## Potential dksearch applications

## Questions for dksearch

- How should recrawl schedules be kept? (dksearch re-fetches whole seed lists and skips unchanged pages; no conditional requests yet)
- How should crawl errors be reported? (examples per reason are now stored with each job)

## Decisions and follow-ups

(Link an ADR in `docs/decisions/` when this leads to a decision.)
