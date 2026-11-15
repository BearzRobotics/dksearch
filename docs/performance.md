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

## Extrapolation from the synthetic data (a guess, not a measurement)

English Wikipedia's article text is on the order of 20 GB. Scaling the numbers above linearly gives roughly an hour of CPU for an import, an index of about twice the text size (tens of GB), compressed content of a few GB, and a `state.db` that would be several GB with the current per-record rights text. Real text has a larger vocabulary and longer articles, so treat every one of these as a rough order of magnitude and measure with a real dump before planning hardware.

## Not measured

The full English Wikipedia (millions of articles, tens of GB); the effect of the `porter` tokenizer; cold-cache latency; and the admin interface under load.
