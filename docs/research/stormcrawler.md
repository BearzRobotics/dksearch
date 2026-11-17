# Apache StormCrawler

Status: source read; no experiments (Storm and a search backend were deliberately not built or run). Research order: 10 of 10.

- Focus: Distributed crawling and backpressure.
- Source: <https://github.com/apache/stormcrawler>, shallow clone at `/mnt/scratch/research/stormcrawler`, commit `f5cfe64f7f63` (2026-11-16).
- Claims marked (read) were checked in the files named; (known) are from prior knowledge and not checked. Nothing here is (observed).

## What it does

A set of components (spouts and bolts) for Apache Storm that make a continuous, streaming crawler (read: `README.md`, `core/`, `external/`). Unlike Nutch there are no rounds: URLs flow through a topology all the time. The **status index** (a search index or SQL table, one row per URL) is the frontier; the topology reads due URLs from it, fetches, parses, indexes, and writes the new status back. Backends are in `external/`: `opensearch`, `solr`, `sql`, `urlfrontier` (a separate gRPC frontier service), and `core` has an in-memory spout for tests (`MemorySpout`, `MemoryStatusUpdater`, `FileSpout`). Other externals: `tika`, `playwright`, `warc`, `aws` (S3 cache), `langid`, `ai` (LLM text extraction).

## Architecture as read

Paths under `core/src/main/java/org/apache/stormcrawler/` unless noted.

**Topology (read).** `external/opensearch/archetype/.../crawler.flux`: `AggregationSpout` (reads status), `URLPartitionerBolt` (adds the queue key), `FetcherBolt`, `SiteMapParserBolt`, `JSoupParserBolt`, then a shunt to `tika/ParserBolt` for non-HTML, `IndexerBolt`, and `StatusUpdaterBolt`, which every stage feeds through a `status` stream. Wiring is declarative (Flux YAML) and configuration is one YAML (`core/src/main/resources/crawler-default.yaml`, all keys listed with defaults).

**Status model (read).** `persistence/Status.java`: only five values: `DISCOVERED`, `FETCHED`, `FETCH_ERROR`, `REDIRECTION`, `ERROR`. Everything else (depth, path, signature, interval, ETag, Last-Modified, error cause) lives in a free-form `Metadata` map, with `metadata.persist` and `metadata.transfer` listing which keys are stored and which are copied to outlinks. The document id is `sha256(normalised URL)` (`AbstractStatusUpdaterBolt.getDocumentID`, line 298), and the same id is used in the content index, so status and content rows line up.

**Scheduling (read).** `persistence/Scheduler.java`; `AbstractStatusUpdaterBolt` asks it for the next fetch date whenever a status arrives. `DefaultScheduler.java`: fixed minutes per status (`FETCHED` 1440 = 1 day, `FETCH_ERROR` 120, `ERROR` 44640 = 31 days, `-1` = never), overridable per metadata key/value (`fetchInterval.isFeed=...`), or per URL by `scheduler.delay.mins` (sitemaps use it to stagger). `AdaptiveScheduler.java`: if the `MD5SignatureParseFilter` signature differs from the old one the interval becomes `(1-dec)*interval + dec*min` (dec 0.5), else `interval * (1+inc)` (inc 0.5), clamped to `min` 60 min .. `max` 14 days; a 304 counts as unchanged; the signature date and the interval are metadata fields; with `setLastModified` the crawler sets its own `Last-Modified` from the detected change, so later requests are conditional even if the server gives no date.

**Conditional requests (read).** `protocol/okhttp/HttpProtocol.java:776-785`: sends `If-Modified-Since` from the stored `last-modified` and `If-None-Match` from the stored ETag (kept under the protocol-metadata prefix), so both validators are used. A 304 is emitted as `FETCHED` with `fetch.statusCode=304`.

**Frontier query and buffer (read).** The spout (`persistence/AbstractQueryingSpout.java`; `external/opensearch/.../AggregationSpout.java`) queries the status index for `nextFetchDate <= now`, grouped into buckets by the partition key (host, domain or IP, `partition.url.mode`), a few URLs per bucket (`maxURLsPerBucket`), buckets sorted by earliest due date; results fill a `URLBuffer` (`persistence/urlbuffer/`: `SimpleURLBuffer`, `PriorityURLBuffer`, `SchedulingURLBuffer`), a map of queue key to list with an `inBuffer` set that refuses a URL already waiting (`AbstractURLBuffer.add`, line 47). Re-querying is throttled while the buffer is full, and a URL handed out sits in `beingProcessed` (`InProcessMap`, TTL `spout.ttl.purgatory`, 30 s) so the next query does not return it again before its status is written.

**Politeness and backpressure (read).** `fetcher/FetchItemQueues.java` / `FetchItemQueue`: per-queue `nextFetchTime`, `crawlDelay` (`fetcher.server.delay` 1 s), threads per queue (`fetcher.threads.per.queue`, with regex overrides `fetcher.maxThreads.<pattern>`), `fetcher.max.queue.size`, `fetcher.timeout.queue`. A queue's delay can be raised by robots Crawl-delay (`fetcher.max.crawl.delay` 30 s; `CrawlDelayPolicy`) and **backed off exponentially with jitter** after a rejected or timed-out fetch (`backOffFetchItem`, line 173). The real backpressure is Storm's: `topology.max.spout.pending` bounds URLs in flight, a tuple that is not acked within `topology.message.timeout.secs` is replayed (the spout's `fail` re-queues), so slow parsing slows the spout instead of growing memory without bound. `fetcher.thread.timeout` is a hard per-URL deadline with a bounded pool of helper threads for abandoned calls.

**Robots (read).** `fetcher/RobotRulesLookup.java`, `protocol/HttpRobotRulesParser.java`: crawler-commons rules in a Caffeine cache keyed by normalised host; switches for 403 (`http.robots.403.allow` true), 5xx (`http.robots.5xx.allow` false), cross-origin robots redirects. A denied URL goes to status `ERROR` with `error.cause=robots.txt`; robots.txt sitemaps are sent as outlinks. `JSoupParserBolt` also honours `<meta robots>`/`X-Robots-Tag` (`util/RobotsTags.java`: noindex, nofollow).

**Parse, dedup, index (read).** `bolt/JSoupParserBolt.java`: detects MIME type, parses with jsoup, extracts text via `TextExtractor` (`JSoupTextExtractor`, or an LLM one in `external/ai`), collects outlinks, then runs `ParseFilter`s (xpath, JSON-LD, language id, signature). Each outlink is emitted to the status stream as `DISCOVERED`; `AbstractStatusUpdaterBolt` first looks it up in an in-memory Caffeine cache (`status.updater.use.cache`) and drops known URLs, and the backend write with a fixed id (sha256 of URL) makes a repeated insert a no-op ("create" only if absent). **No link graph is stored:** outlinks become new status rows and are forgotten (no inlinks, no anchors). Content dedup is only the signature used for scheduling; no near-duplicate job.

## One URL, injection to index

1. Seed: `injection.flux` / `FileSpout` emits `(url, metadata)` as `DISCOVERED` to the status updater, which writes a row `id = sha256(url)`, `nextFetchDate = now`.
2. `AggregationSpout` query returns it (due, bucket = host) into the `URLBuffer`, marks it in process, emits it.
3. `URLPartitionerBolt` sets the queue key; `FetcherBolt` places it in the host's `FetchItemQueue`; a fetcher thread takes it when `nextFetchTime` allows, checks robots (`RobotRulesLookup.lookup`, line 201), sends the request (conditional if validators are stored) and emits content + metadata.
4. `JSoupParserBolt` extracts text, signature and outlinks; outlinks go to the status stream as `DISCOVERED`; the document goes to `IndexerBolt` (`bolt/IndexerBolt.java`), which writes `index(docID)` in bulk and acks only after the bulk reply (`WaitAckCache`).
5. The index ack reaches `StatusUpdaterBolt`: status `FETCHED`, `nextFetchDate` from the scheduler (adaptive: from the signature comparison). The spout will return it again when that date passes.
6. Failure path: a fetch error becomes `FETCH_ERROR` (retried after 120 min; after `max.fetch.errors` becomes `ERROR`; `AbstractStatusUpdaterBolt` lines 222-231); a tuple lost in a crashed worker times out and the spout re-queries it, so a crash costs at most the in-flight set.

## Useful patterns

- The frontier is a table with `nextFetchDate`, and **scheduling is a pure function** `(status, metadata) -> date` (`Scheduler.schedule`), pluggable by one class name: easy to test, no job framework.
- Five coarse statuses plus a metadata map: small, schema-light, extensible.
- Both validators sent; own `Last-Modified` synthesised from detected change.
- Exponential per-host back-off with jitter after failures; hard per-URL deadline.
- "Being processed" TTL map so a frontier query cannot hand out the same URL twice; at-least-once processing through ack/replay, idempotent writes through a content-derived id.
- Memory-only spout/updater for tests: the topology works without a backend (for tests only).

## Limits, and what not to copy

- Needs Storm (Zookeeper, Nimbus, supervisors) plus a status/content backend (OpenSearch, Solr, SQL or a URLFrontier server) for real use: a mandatory external service, against the project's rule. Local mode exists but is for development.
- Flux/YAML and the Java bolt graph, Maven archetypes: no equivalent to a single TOML file and one binary.
- No link graph, no near-duplicate detection, no PageRank; changes seen only by MD5 of the content, which flags any edit as "changed".
- Status index queries (aggregation by bucket, sort) rely on a search engine's features; a naive SQL port needs the right index on `(next_fetch, bucket)`.
- At-least-once with replay means duplicates are possible; the design relies on idempotent ids.

## Possible dksearch uses

dksearch today: breadth-first windows, per-host lock, workers, robots, depth limit, optional `validators_file`, no persisted frontier, link graph or adaptive schedule.

- Persist the frontier as a table `(id = hash(url), url, status, next_fetch, metadata)` in the existing store, with the five-status model: replaces `validators_file`, allows resuming a stopped crawl and recrawling only what is due. Read due URLs in per-host buckets with a small per-bucket limit, as the spout does: that is a better "window" than a fixed seed window, and still breadth-first.
- Copy `Scheduler` as a small Zig interface with a default (fixed per status) and an adaptive (`min`, `max`, `inc`, `dec`) policy selected in TOML per source.
- Store ETag and Last-Modified per URL; send both; treat equal content hash as unchanged.
- Per-host back-off after a failure (doubling with jitter, capped by robots Crawl-delay and a max) in place of a fixed wait; a hard per-URL deadline so one hung socket cannot hold a worker.
- An in-process "being fetched" set with a TTL and an idempotent write, so an interrupted or crashed crawl can simply be started again (and `fail` = leave the row due).
- Keep the crawler synchronous and in one process: take the status model and scheduler, not Storm.

## Follow-up questions

- Which operations should run asynchronously? Fetch and parse can stay in one worker; indexing could be batched with an ack-on-commit as in `IndexerBolt`, which matters for the slow `fsync` on this machine's data disk.
- Can one job system serve local and distributed use? StormCrawler shows the split that works: a frontier store with due-time queries plus stateless workers; for dksearch a single process with the table is the local case, and a second node could read a shared table later (not before the peer plan allows it).
- Is `max.fetch.errors` plus a long ERROR interval (31 days) a good default for dead pages in dksearch? Compare with the "crawl errors" reports already kept per job.
- What bucket size and window interplay gives breadth-first without starving deep sites? Re-run the crawl comparison with a due-time frontier.
