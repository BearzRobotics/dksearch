# Apache StormCrawler

Status: not started. Research order: 10 of 10.

- Focus: Distributed crawling and backpressure.
- Source: <https://github.com/apache/stormcrawler>
- Version or commit examined: (to be recorded)

## What to examine

- Fetcher/parser separation, URL queues
- Backpressure, queue limits, retries
- Worker failure recovery

## Experiments planned

- [ ] Slow parsing and queue growth; interrupt workers; per-domain limits

## Findings

(Nothing yet. Record observations from the source and from experiments here, with file names and commit.)

## Useful patterns

## Limitations and trade-offs

## Potential dksearch applications

## Questions for dksearch

- Which operations should run asynchronously?
- Can one job system serve local and distributed deployments? (dksearch runs one background task at a time today)

## Decisions and follow-ups

(Link an ADR in `docs/decisions/` when this leads to a decision.)
