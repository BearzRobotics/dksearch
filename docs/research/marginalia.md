# Marginalia Search

Status: source read; no experiments (not built or run). Research order: 4 of 10.

- Focus: ranking, independent web discovery, and keeping a whole-web index small and fast on one machine.
- Source: <https://github.com/MarginaliaSearch/MarginaliaSearch>, shallow clone at `/mnt/scratch/research/MarginaliaSearch`, commit `33ef7a171fb0` (2026-11-16).
- Claims marked (read) were checked in the files named; (known) are from prior knowledge and not checked. Paths are under `code/`. Java, gRPC between services, MariaDB for domain metadata, ZooKeeper for the service registry.

## What it is

An independent search engine whose stated aim is to surface "the more human, non-commercial sides of the Internet" on affordable hardware (README, read). It is not a general crawler of everything: the corpus is a *curated set of domains*, each crawled shallowly. It can run as a copy of the public service or as a white-label engine for crawled or side-loaded data (README, read). The roadmap lists ZooKeeper and Docker as dependencies it wants to drop (`ROADMAP.md`, read).

## Architecture as read

**Services (read, `readme.md`).** Core: `index-service` (partitioned; each partition ("node") owns its domains), `query-service` (parses the query, fans out to all partitions), `control-service` (operates batch processes, web UI). Application gateways: `search-service` (the site), `api-service` (`/api/v2/search`, `/unranked`, `/filter/{id}`, `/site/{domain}`, `/site/{domain}/similar`, `/linking`, `/feed`: `ApiV2.java`), `explorer-service` and `dating-service`. Batch processes: crawl, convert, load, ranking, new-domain.

**Choosing what to crawl (read).** Discovery is by domain, not page. `processes/new-domain-process` (NDP) takes candidate domains from a queue (`DomainTestingQueue`, ordered by `PRIORITY`) and `DomainEvaluator` fetches the root page only: HTTP 200, `text/html`, at least 100 characters of text, no "404"/"not found" text, no meta-refresh (a parked-domain tell), at least one internal link. Accepted domains are assigned to the partition with the fewest domains. Operator curation: `DomainTypes` (BLOG, SMALL, CRAWL, TEST) are lists of domains loaded from a configured URL (`DOMAIN_SELECTION_TYPE.SOURCE`); `random-websites` keeps a review queue where users suggest domains for the "random site" feature and an operator accepts them. A domain blacklist is applied. The crawler itself never leaves a domain in one job and takes per-domain URL counts between 100 and 10 000 (`crawler.minUrlsPerDomain`, `maxUrlsPerDomain`, growth factor 1.25 per recrawl: `CrawlerMain.java`), so a million domains stay a bounded corpus.

**Crawler and politeness (read).** `CrawlerRetreiver`: probe, fetch `robots.txt` (crawler-commons `SimpleRobotRules`), honour `Crawl-delay`, else delay is twice the fetch time clamped to 1000-2500 ms plus up to 150 ms jitter (`CrawlDelayTimer`); on HTTP 429 wait 1-5 s and slow down for the rest of the job. Sitemaps and RSS feeds supplement links. Output is WARC per domain, later converted to parquet. Recrawl uses `If-Modified-Since`/`ETag`; if most pages are unchanged it only samples a few per domain (`crawling-process/readme.md`). HTML only; PDFs are skipped.

**Index (read, `index/readme.md`, `reverse/`, `forward/`).** Two reverse indexes (word to document): a *priority* index holding only word-document pairs flagged important (word in title, subject, url, domain: `WordFlags`: Title, Subjects, NamesWords, Synthetic, Site, SiteAdjacent, UrlPath, UrlDomain; one bit each, one byte per pair) and compressed, and a *full* index with term metadata and positions (`FullReverseIndexReader`, `PrioReverseIndexReader`). Both are built from a journal by writing small sorted pre-indexes that fit in RAM and merging them (merging sorted arrays needs no extra RAM), stored as skip lists/B-trees over memory-mapped files (`libraries/skiplist`, `btree`, `array`). A *forward* index is a sorted id file plus a fixed-size record file per document: packed `DocumentMetadata` (rank, quality, size, average sentence length, topology, year) and a `HtmlFeatures` bitmask. Document ids are 64-bit and encode `[rank:6 | domain:31 | ordinal:26]` (`model/id/UrlIdCodec.java`): rank sits in the top bits so sorting by id sorts by domain importance, and documents of one domain are adjacent, so a `site:` query is a range. Page text is not stored in the index: results show a static summary (the roadmap plans block-compressed document storage and live snippets).

**Ranking (read, `index/results/IndexResultRankingService.java`).** Score = domain-rank adjustment x (first-position + proximity + verbatim-match + BM25 + term-flag BM25) x exp(priority terms/5), normalised against a document "bonus" made of: average-sentence-length and short-document penalties, a quality penalty, a domain-rank bonus `(255 - rank)`, a topology bonus `0.2 ln(1+topology)`, a *connectivity* penalty (how a domain sits in the link graph relative to the curated set, from 0 for DIRECT to -25 for UNREACHABLE), a temporal bias (recent or old, optional), and a feature-flag penalty (`HtmlFeature`: ads, trackers, affiliate links, cookie banners, JS, third-party requests, GA spam, long URLs). Weights are request parameters (`RpcResultRankingParameters`), and a debug mode returns every factor per document (`DebugRankingFactors`). Domain rank comes from personalised PageRank seeded from the curated domain list (`ranking-process/PrimaryRankingsCalculator`, `PersonalizedPageRank`), recomputed offline and "baked into the document identifiers", so ranking changes need an index rebuild. Results are capped per domain (`ResultPriorityQueue`, `limitByDomain`; lifted for `site:` queries).

**Query language (read, `QueryParser.java`, `QueryFactory.java`).** Plain terms, `"phrase"` (mandatory phrase constraint plus an n-gram preference), `-term`, `?term` (priority, not required), `(term)` (advice: required but not ranked), `site:`, `site:*.`, `format:`, `file:`, `tld:`, `ip:`, `as:`, `asn:`, `generator:`, `year>/</=`, `size`, `rank`, `q` (quality), `lang:`, `near:`, `set:`, `qs=` (strategy). Limits: 1000 characters, fewer than 12 tokens. Query terms are stemmed/expanded (`QueryExpansion`). Search profiles (`SearchProfile`: popular, smallweb, blogosphere, vintage, tilde, academia, plain-text, food, forum, wiki, docs) are named *filters* (stored XML specs: domains, terms, ranking weights), selectable and combinable with an ad-hoc spec (`QueryGRPCService.getFilter`).

**Site exploration (read).** `/api/v2/site/{domain}` returns info, feed, similar domains and linking domains; the `explorer-service` finds similar sites by treating each domain's link neighbours as a sparse vector and using cosine similarity (`explorer-service/readme.md`); `functions/link-graph` keeps the graph in memory, updated atomically from files.

## One query, end to end (read, except where marked)

1. Web page or `/api/v2/search` (timeout clamped to 50-250 ms, results capped at 100, `ApiSearchOperator`) calls `QueryClient`.
2. `QueryGRPCService.query`: refuse with RESOURCE_EXHAUSTED if too many queries are in flight (shedding), else resolve the filter (stored + ad hoc, merged) and call `QueryFactory.createQuery`: tokenise, build required/excluded/priority terms, phrase constraints, domain ids for `site:`, limits, then expand variants.
3. `IndexClient.executeQueries`: a semaphore bounds concurrent queries; the query goes to every partition in parallel with a bail-out instant of twice the per-request timeout, clamped to the caller's deadline.
4. `IndexGrpcService.query` per partition: `SearchContext`, then `IndexQueryExecution` (acquire a slot within half the budget, else reject) runs a pipeline of *lookup* (skip-list walks, rarest term first, priority index before full, `CombinedIndexReader.createQueries`), *deduplicate*, *preparation* (read term flags and positions in batches, io_uring if available) and *ranking* stages on thread pools, all against one time budget; unfinished work is dropped when the budget ends.
5. Ranking as above; `ResultPriorityQueue` keeps the best N with the per-domain cap; document details come from a database reader.
6. Query service merges the partitions' results, drops blocked URLs, and returns them with paging; the gateway renders HTML or JSON. (Step 6 merge details not read.)

## Useful patterns

- Curate the *domain* set, keep each crawl shallow and capped; most of the "small and fast" comes from corpus selection, not clever compression.
- A cheap admission test on the root page before indexing a site (reachable, real HTML, real text, internal links, not parked).
- Two-tier postings: a tiny index of "important" occurrences answers most queries; the full one is the fallback.
- Fixed-size per-document metadata plus a bitmask of page features, used as ranking penalties (ads, trackers, affiliate links) instead of a binary spam filter.
- Per-domain cap and a time budget carried through every stage; load shedding instead of queueing.
- Ranking explanation as a first-class debug output; named filters/profiles as reusable query scopes.

## Limits and what not to copy

- Scale machinery that dksearch does not need: partitioned nodes, gRPC mesh, ZooKeeper, MariaDB, Docker-centred install, 256+ thread crawler. Heavy on memory and I/O by design.
- Ranking is tuned to one editorial view (small, text-first, ad-free web); penalties and the English-only connectivity view (`"en".equalsIgnoreCase` check in `IndexGrpcService`) are not neutral defaults for personal or enterprise collections.
- Rank baked into ids means re-ranking = rebuild. dksearch wants rebuildable indexes, but should keep ranking signals out of identifiers.
- No snippet from stored text yet; HTML only; dependence on a crawl pipeline (WARC, parquet) and a trained-model data download (`run/setup.sh`).

## Possible dksearch uses

- A per-site *quality/feature record* at crawl time (tracker, ad, affiliate, cookie-banner and short-page flags, link counts) stored as columns and applied as an optional, explainable ranking penalty, `explain=1` listing each factor.
- A site-admission check in the crawler connector for `[[source]]` entries that discover new hosts (root page sanity, internal links, not parked), reporting why a site was refused.
- Result cap per host in the existing ranking, configurable per scope; lifted for `site:`-style queries.
- Named, saved scopes (profiles) that bundle sources, hosts, boosts and demotes; fits the open "saved source groups" gap in `source-selection.md`.
- "Similar sites" and "who links here" views from the link graph the crawler already sees.
- Query budget propagated through stages, plus load shedding on the public interface.

## Questions for dksearch

- Is a priority tier (title, headings, url hits) worth its disk and build cost for dksearch's corpus sizes, or does the existing index already answer fast enough? Measure on the test corpus first.
- Domain diversity: cap per host by default, or only when one host dominates the first page?
- Should crawl politeness copy the "twice the fetch time, 1-2.5 s, 429 slows the whole job" rule, or keep a configured per-host delay? Compare with the current crawler.
- Personalised PageRank from a seed list is a form of "trusted seeds": could an operator's chosen sources seed a link-based boost, offline and rebuildable?
- Experiment still to do (not run here): index a few hundred pages with and without a feature penalty and compare orderings.
