# Performance measurements

What was measured on 2026-11-14, how, and what it does and does not show. These are single-machine measurements on synthetic data, meant to find bottlenecks and set expectations; they are not a benchmark suite and not a promise.

## Setup

- Machine: 12 logical CPUs, Linux 7.0, data on a btrfs volume with very slow `fsync` (4 to 30 seconds per synced commit), which dominates import wall time and says nothing about CPU cost.
- Build: `zig build -Doptimize=ReleaseSafe` (safety checks on).
- Data: a synthetic English-like dump of 20,000 articles in Wikipedia's export format, bzip2 multistream with 100 pages per stream (4.4 MB compressed, 52.7 MB of XML, 43.0 MB of converted text). The vocabulary is only 28 words, so **every query matches many thousands of documents**, which is much harder for ranking than real text with rare words. Real articles were only spot-checked (ten, for conversion quality).
- Queries: a mix of single words (40%), two words (35%), three words (15%), phrases (7%) and "Place N" lookups (3%), 10 results each, over HTTP on loopback from a Python client (the client itself costs a little at high concurrency).

## Results

Import (1,500 of the articles, ReleaseSafe): 0.55 s of CPU in total (0.30 s user, 0.25 s system), about 0.37 ms per article including decompression, XML parsing, wikitext conversion, compression, indexing and records. A debug build takes about three times as long. Wall time was 48 s here, almost all of it waiting for disk syncs (one batch per bzip2 stream).

Stored sizes for the 20,000 articles (43.0 MB of text):

| File | Size | Notes |
|---|---|---|
| `index.db` | 94.5 MB | 2.2 times the text: FTS5 with word positions |
| `content.db` | 16.3 MB | text compressed to 0.27 of its size |
| `state.db` | 25.8 MB | about 1.3 KB per document in these measurements, mostly the same rights text repeated in every record; the Wikipedia rights note has since been shortened (about 0.4 KB less per record), and storing rights once per source remains a candidate |

Search, 20,000 documents, per-query latency with one client (the single-connection and pooled servers are identical here):

| p50 | p95 | p99 | max |
|---|---|---|---|
| 15 ms | 27 ms | 43 ms | 50 ms |

Search throughput against the number of concurrent clients:

| Clients | Before the connection pool | After |
|---|---|---|
| 1 | 57 queries/s | 60 queries/s |
| 4 | 58 queries/s (p50 64 ms) | 228 queries/s (p50 15 ms) |
| 16 | 57 queries/s (p50 210 ms, p99 1.1 s) | 306 queries/s (p50 51 ms, p99 104 ms) |

The server process stayed under 35 MB resident with 20,000 documents indexed.

## What this found

The first run showed throughput flat at about 57 queries/s however many clients there were: all searches shared one SQLite connection, which SQLite serialises. `serve` now searches on a pool of min(CPUs, 8) read-only connections (WAL mode allows concurrent readers), which restored scaling with unchanged per-query latency (a first version that spun while waiting for a free connection was replaced by a semaphore wait after review, which also cut the 16-client tail latency). Generating snippets was not the cost (tested: moving it out of the ranking query saved under 20%); scoring every matching document is, which is inherent to BM25 ranking over very common terms.

## A real dump: Simple English Wikipedia (2026-11-15)

The `simplewiki-latest-pages-articles-multistream.xml.bz2` dump of 2026-11-02 (390 MB compressed), imported with the `wikipedia` connector into a fresh data directory on the same machine's NVMe drive (ext4, normal `fsync`), ReleaseSafe build.

| | |
|---|---|
| Articles indexed | 286,047 (0 skipped) |
| Import wall time | 3 min 07 s (99 s user, 49 s system), one run, 22 MB resident |
| `index.db` | 599 MB |
| `content.db` | 274 MB (compressed texts) |
| `state.db` | 321 MB (about 1.1 KB per document; the rights text repeated per record, still not stored once per source) |
| `dksearch check` | 20 s, nothing corrupt |
| `dksearch backup` | 1.6 s for 495 MB (content and state) |
| `dksearch rebuild` (index from stored text) | 2 min 38 s, same index size, 20 MB resident |

Search over HTTP on loopback, 3,000 queries per row from a Python client: single common words (40%), two words (35%), three words (15%), phrases (7%) and rare words (3%), 10 results each, server 38 MB resident:

| Clients | Queries/s | p50 | p95 | p99 |
|---|---|---|---|---|
| 1 | 83 | 8 ms | 35 ms | 45 ms |
| 4 | 297 | 9 ms | 36 ms | 47 ms |
| 16 | 454 | 31 ms | 66 ms | 100 ms |

Caches were warm (the whole data set fits in the page cache). The tail comes from multi-word queries on very common words.

**A bug this found:** the first import failed with `SourceFailed` after 112,946 articles although the dump was intact (`bzip2 -t`). A bzip2 stream's last output byte had fallen exactly at the end of the read buffer, so the decoder returned zero bytes for the stream end and the connector took that for the end of the file. The 20,000-article synthetic dump never hit it (about one stream in 64,000 does). Fixed (`1a427a0`), with a test that sweeps every buffer size; the fresh import above ran in one pass after the fix. Resuming the failed run had also worked, which is how the cause was narrowed down.

The English Wikipedia is about 20 times the size of this dump in text. The numbers scale roughly linearly in what was measured here (import time, `index.db` about 2 times the text), which would put it at an hour or so for import and tens of GB of index; that is still a guess, and the free space on this machine's drive (95 GB) was too small to try.

## Full English Wikipedia (2026-11)

One import of the full English dump on the same machine (data on a separate disk with room for it):

| Measure | Value |
|---|---|
| Import wall time | 5 h 47 min 48 s |
| Data directory after the import | 64.8 GB (all three files together) |
| `dksearch check` | 7,937 s (2 h 12 min), nothing corrupt |
| `dksearch backup` (content and state) | 1,544 s (26 min) |

This is a little over the "hour or so, tens of GB" guessed from the Simple English dump, so that guess was too optimistic about time (the import is bound by the bzip2 decoder and by SQLite writes, which grow with the index) and about right about size. The `rebuild` time was not recorded.

## Books pilot: 571 PDFs and some media (2026-11-16)

A folder of economics and banking books (`files` source with `pdf_text`, `pdf_workers = 4`, `media`, `office`, `html`; 12 GB on disk including 41 mp4, 34 flv and a few audio files):

| Measure | Value |
|---|---|
| Files seen / imported / skipped | 622 / 526 / 96 (88 had no extractable text, mostly scans) |
| Import wall time | 9 min 34 s (142 s user, 20 s system), 4 PDF workers, 76 MB resident |
| `index.db` | 356 MB |
| `content.db` | 88 MB |

The skipped scans are what OCR (on the roadmap) is for. Three PDFs were over this run's 64 MiB limit and were refused.

## Crawl, and typo tolerance (2026-11-16)

Crawl, six minutes, 785 seeds on 450 hosts, depth 3, following links to other sites, 500 ms between requests to a site (a busy desktop and an ordinary home connection; the numbers are for comparison, not for planning):

| Crawler | Real pages | Sites |
|---|---|---|
| dksearch, one request at a time (before) | 35 | about 10 |
| dksearch, 16 workers, depth-first | 2,441 | 119 |
| dksearch, 16 workers, breadth-first (window 200) | 3,085 | 389 |
| YaCy 1.942, defaults, global mode | 855 | 541 |

Typo-tolerant search on the 297,447-document playground index (index.db 844 MB): 30 to 70 ms for a word with a close match, about 500 ms when nothing is close (the vocabulary scan is time-limited). Retrieval (`/api/v1/retrieve`) over 13 large books: 0.3 s with one document-level pass, 1 to 2 s after passages, pages and the PDF page lookup were added.

## Extrapolation from the synthetic data (a guess, not a measurement)

English Wikipedia's article text is on the order of 20 GB. Scaling the numbers above linearly gives roughly an hour of CPU for an import, an index of about twice the text size (tens of GB), compressed content of a few GB, and a `state.db` that would be several GB with the current per-record rights text. Real text has a larger vocabulary and longer articles, so treat every one of these as a rough order of magnitude and measure with a real dump before planning hardware.

## Not measured

The effect of the `porter` tokenizer; cold-cache latency; and the admin interface under load.

## Searches of only common words (2026-11-19)

Measured with `crap` (a fork of poop: wall time of `curl -s -o /dev/null http://127.0.0.1:18103/search?q=...`, several runs each) against the live playground server, 414,000 documents, 12 logical CPUs, the index on NVMe. Across 35 ordinary searches the median was 47 ms; the slow ones were queries made only of words too common to rank.

| Search | Before | After |
|---|---|---|
| `the` | 5.21 s (the query time limit) | 9.5 ms |
| `a` | 5.0 s | not timed after the change (the same path as `the`) |
| `to be or not to be` | 2.03 s | 0.37 s |
| `linux kernel scheduler` (control) | 49 ms | 47 ms |

What it was: ranking millions of matches, and then the per-domain step reading up to 100,000 rows before its window (a `perf record -e cpu-clock:u` profile showed SQLite's row processing, not ranking, after the first fix: "the" fell from 5.2 s to 1.1 s with the phrase and unranked paths and to 9.5 ms once the window was skipped). See docs/decisions/0069-common-word-searches.md.

## Searches that match many documents (2026-11-19)

The same method (`crap`, `curl` against the live server, 414,000 documents). The time of such a search was the factors computed for every match, not the ranking; ADR 0072. Taking the best 2,000 candidates by text score first:

| Search | Matches | Before | After |
|---|---|---|---|
| `language` | 22,000 | 607 ms | 120 ms |
| `linux` | 11,000 | 268 ms | 91 ms |
| `lanague` (corrected to `language`) | 22,000 | 1.02 s | 461 ms |
| `kernel scheduler` (control) | few | 40 ms | 39 ms |

A first attempt (`rowid IN (...)`) made `language` take 5 s on this index while passing every unit test; the unit tests use a few hundred documents. Check a change of query shape on the large index before it is deployed.

