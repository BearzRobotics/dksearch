# Apache Nutch

Status: source read; no experiments (a JVM/Hadoop stack was deliberately not built or run). Research order: 3 of 10.

- Focus: Crawler state and ingestion architecture.
- Source: <https://github.com/apache/nutch>, shallow clone at `/mnt/scratch/research/nutch`, commit `35734ec8b1a4` (2026-11-11).
- Claims marked (read) were checked in the files named; (known) are from prior knowledge and not checked. Nothing here is (observed).

## What it does

A batch web crawler built on Hadoop MapReduce (read: `bin/crawl`, `src/java/org/apache/nutch/**`). State lives in three directories of Hadoop files: the **CrawlDb** (one record per URL), **segments** (the output of one fetch round: fetch list, fetched content, parse data, parse text) and the **LinkDb** (inverted links). A crawl is a loop of separate jobs, `inject`, then repeated `generate`, `fetch`, `parse`, `updatedb`, with optional `invertlinks`, `dedup` and `index` (`src/bin/crawl`, lines 314-410). Everything extensible is a plugin (`src/plugin/`, about 80 directories): protocols, URL filters and normalizers, parsers, scoring, index writers (Solr, Elasticsearch, OpenSearch, CSV, Kafka and others).

## Architecture as read

Paths under `src/java/org/apache/nutch/`.

**CrawlDb record (read).** `crawl/CrawlDatum.java`: status byte, fetch time, modified time, retries, fetch interval (seconds), score, 16-byte signature, a metadata map. Persistent DB statuses: unfetched, fetched, gone, redir_temp, redir_perm, notmodified, duplicate, orphan, parse_failed (0x01-0x09); transient statuses used only between jobs: fetch_* (0x21-0x26), signature, injected, linked, parse_meta. The URL is the key; there is no separate id.

**Inject (read).** `crawl/Injector.java`: seed lines are normalised (scope `inject`) and filtered, given fetch time = now, score `db.score.injected` (1.0) and a default interval, and merged with the existing CrawlDb in a reducer (existing records win; `-overwrite`, `-update` change that).

**Generate = the frontier cut (read).** `crawl/Generator.java`: a MapReduce over the whole CrawlDb. The mapper keeps a record only if `schedule.shouldFetch` (fetch time due; `AbstractFetchSchedule.java:193`), not generated recently (`crawl.gen.delay`), and above a score threshold; it sorts by score. The reducer applies `-topN` and `generate.max.count` per host or domain (a hard cap on one site per round; may be an expression per host from the HostDb), splits into `numFetchers` partitions by host/domain/IP (`URLPartitioner`) and writes a segment. The frontier is therefore recomputed from scratch each round by scanning every record.

**Politeness queues (read).** `fetcher/QueueFeeder.java` loads the segment's list into `FetchItemQueues` (`fetcher/FetchItemQueues.java`), one `FetchItemQueue` per host, domain or IP (`fetcher.queue.mode`). A queue hands out an item only if fewer than `fetcher.threads.per.queue` (1) are in flight and `nextFetchTime` has passed (`FetchItemQueue.getFetchItem`, line 123); after each fetch `nextFetchTime = end + crawlDelay` (`fetcher.server.delay`, 1 s). `FetcherThread` (965 lines) pulls from `getFetchItem()` in a loop. Queues with too many exceptions are dropped for the round (`fetcher.max.exceptions.per.queue`), and `fetcher.timelimit.mins` ends the round whatever remains.

**Robots (read).** `protocol/RobotRulesParser.java` uses crawler-commons, with a static cache per host (`CACHE`). `FetcherThread` (lines 360-420) asks for the rules per item; if denied it records `ROBOTS_DENIED`; if the robots Crawl-delay exceeds `fetcher.max.crawl.delay` it skips the whole queue, otherwise sets that queue's delay. HTTP 5xx on robots.txt defers the host (`http.robots.503.defer.visits`, 5 min x 3 retries), `http.robots.403.allow` is a switch. The agent name is mandatory (`conf/nutch-default.xml:78`).

**Conditional requests (read).** The okhttp protocol sends `If-Modified-Since` from `datum.getModifiedTime()` when above 0 (`plugin/protocol-okhttp/.../OkHttpResponse.java:85`; switch `http.enable.if.modified.since.header`, `HttpBase.java:251`); a 304 becomes `ProtocolStatus.NOTMODIFIED` and then `STATUS_FETCH_NOTMODIFIED`. Only the date is sent: a search of the protocol plugins for `If-None-Match` found nothing in okhttp, so **ETags are not used** (the other HTTP plugins: not checked).

**Change detection (read).** After parsing, `ParseSegment`/`ParseOutputFormat` compute a signature (`db.signature.class`: default `MD5Signature` = MD5 of the raw bytes, URL if empty; `TextProfileSignature` = MD5 of a quantised token-frequency profile, which tolerates small edits; `TextMD5Signature`) and write it as a `STATUS_SIGNATURE` datum. In `crawl/CrawlDbReducer.java` (lines 244-270): a fetched record is "modified" if its signature differs from the stored one, "not modified" if equal or on a 304.

**Adaptive schedule (read).** `crawl/AdaptiveFetchSchedule.java` `setFetchSchedule` (line 304): modified: `interval *= 1 - dec_rate (0.2)`; not modified: `interval *= 1 + inc_rate (0.2)`; clamped to `min_interval` 60 s .. `max_interval` 1 year, optionally per host from `adaptive-host-specific-intervals.txt`; the next fetch time is `fetchTime + interval`, with a "sync delta" nudge so the next visit lands near the page's last real modification. The default (`DefaultFetchSchedule`) is a fixed 30 days (`db.fetch.interval.default` 2592000). Failures: `setPageRetrySchedule`, retry up to `db.fetch.retry.max` (3) then `gone`; gone pages are still rechecked later (`AbstractFetchSchedule.java:194`).

**Links (read).** `ParseOutputFormat` writes each outlink as a `LINKED` datum (filtered, normalised, capped by `db.max.outlinks.per.page` 100 and length 4096) into the next `updatedb`, which creates unfetched records and lets scoring plugins distribute score (OPIC, `scoring-opic`). Separately `LinkDb` (`crawl/LinkDb.java`) inverts links to (target: list of source URL + anchor) for anchor-text indexing, and `scoring/webgraph/` (WebGraph, LinkRank) builds a real graph and computes PageRank-like scores offline.

**Dedup (read).** Two levels: the CrawlDb merges records by URL (after normalisation, redirects are recorded as `redir_*` so the target is crawled once); `crawl/DeduplicationJob.java` groups records with equal signature and marks all but one `duplicate`, choosing by `compareOrder` (default score, fetch time, URL length; https over http optional). `indexer/IndexerMapReduce.java` then sends deletes for duplicates, gone and redirected URLs.

**Parsing and indexing (read).** `parse/ParseSegment.java` runs the parser chosen by MIME type (`parse-html`, `parse-tika`, others), `ParseData` holds title, outlinks, metadata; `ParseText` the text. `indexer/IndexerMapReduce.java` joins CrawlDb record, fetch datum, parse data/text and inlinks for each URL, builds a `NutchDocument` through `IndexingFilter` plugins (`index-basic`, `index-anchor`, `index-more`...) and sends ADD or DELETE actions to the configured `IndexWriter`. A record with status `notmodified` can be skipped (`skip` flag, line 405).

## One URL, injection to index

1. `nutch inject crawldb urls/`: the seed line is normalised, filtered; `CrawlDatum{status=DB_UNFETCHED, fetchTime=now, interval=30 d, score=1.0}` is written (`Injector.java`).
2. `nutch generate`: the record passes `shouldFetch` (due now), the per-host cap and `topN`; a `SelectorEntry` lands in segment `segments/<ts>/crawl_generate`.
3. `nutch fetch`: `QueueFeeder` puts it into the host's `FetchItemQueue`; a `FetcherThread` gets it after the delay, asks robots, sends the request (with `If-Modified-Since` on later rounds), writes `content` and a `FETCH_SUCCESS` datum (or `RETRY`, `GONE`, `NOTMODIFIED`, `REDIR_*`).
4. `nutch parse`: the parser extracts text and outlinks; signature, outlinks (as `LINKED` data) and `ParseText` are written to the segment.
5. `nutch updatedb crawldb segment`: `CrawlDbReducer` merges the old record, the fetch datum, the signature and the links: sets `DB_FETCHED`, new interval and fetch time (schedule above); new URLs enter as `DB_UNFETCHED`.
6. `nutch invertlinks`, `dedup`, then `nutch index crawldb -linkdb linkdb segment`: `IndexerMapReduce` builds the document and the writer sends it to Solr/OpenSearch. On the next round, step 2 selects it again only when its fetch time falls due.

## Useful patterns

- One record per URL holding everything the scheduler needs (status, time, interval, signature, score, retries) and a clear split between transient fetch statuses and persistent DB statuses.
- Interval adaptation by multiplication with clamps and per-host overrides: small, testable, 100 lines (`AdaptiveFetchSchedule`); it works with or without a 304.
- Politeness as a queue per host with `nextFetchTime` and an in-flight count; robots failures (5xx) defer the host instead of ignoring or banning it.
- A per-round cap per host/domain, so one big site cannot take a whole round (dksearch's windows and "set aside a busy site" do part of this).
- `TextProfileSignature`: change detection that ignores small edits (counters, dates), cheaper than diffing.
- Redirects stored as their own status so the target is crawled once.

## Limits, and what not to copy

- Hadoop/JVM, a cluster-shaped design: each round rescans the whole CrawlDb; startup cost of every job; far too heavy for a single small node, and the file formats are Hadoop's.
- Batch rounds only: nothing is fetched while a round is being generated; the frontier is not a live queue.
- If-Modified-Since only, no ETag (in the plugin read). A stored signature compares after a full download, so it saves indexing work but not bandwidth.
- The LinkDb/WebGraph jobs are extra full passes; useful only if link analysis is wanted.
- The ADD/DELETE index stream assumes an external search server; dksearch indexes in-process.

## Possible dksearch uses

dksearch today: breadth-first windows, per-host lock, workers, robots, depth limit, optional `validators_file` (conditional requests for depth-limit pages), no persisted frontier or link graph, no adaptive schedule.

- A small `urls` table (SQLite or a flat file in the data directory) with Nutch's record shape: status, next fetch time, interval, signature, retries, ETag, Last-Modified. This is the persisted frontier; it is rebuildable from the index (the stored documents) and from seeds, so it keeps the "rebuildable" rule. It would replace `validators_file`.
- Adaptive interval with Nutch's multiply-and-clamp rule, plus `min`/`max` in TOML per source; start from a fixed default (30 days) as Nutch does; use a 304 or an equal signature as "unchanged".
- Both validators: send `If-None-Match` and `If-Modified-Since` (Nutch sends only the date) and fall back to a content hash when the server ignores them.
- A per-source per-round cap (`max_per_host`) next to the windows.
- Robots 5xx = defer the host, 4xx = allow, as in `FetcherThread`.
- Link graph: record `(from, to, anchor)` only if a feature needs it (anchor text for ranking); do not build WebGraph.

## Follow-up questions

- How large does the url table get on the owner's real sources (hundreds of thousands of rows?) and is a flat file enough, or does it need the existing database?
- Should an unchanged-but-fetched page cost zero indexing work (skip when signature equal)? What does dksearch's current skip use for "unchanged"?
- Is anchor text of inbound links worth a link table for ranking small private collections? Test on the test corpus before building.
- Per-host adaptive intervals need a "host" notion that the files connector does not have: scope the schedule to the `crawl` connector.
