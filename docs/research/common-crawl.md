# Common Crawl

Status: documentation read; one real WARC byte range fetched and inspected (not yet run through dksearch). Research order: 9 of 10.

- Focus: archive ingestion.
- Source: <https://commoncrawl.org> (pages: get-started, faq, ccbot, terms-of-use, the 2018 columnar-index post) and the open data at <https://data.commoncrawl.org/>; code at <https://github.com/commoncrawl> (not read).
- Version examined: crawl `CC-MAIN-2026-43` (the newest listed on 2026-11-17; fetched 2026-10-05 to 2026-10-18 per `https://index.commoncrawl.org/collinfo.json`).
- Claims marked (read) come from a named documentation page or a file listing fetched today; (observed) from the sample below; (known) from prior knowledge, not checked.

## What it is

A non-profit that crawls the public web and publishes the result as free data. It is an archive to download and select from, not a service to query (the CDX API and the Athena tables are the only lookups). For dksearch it is a large, real, messy WARC source for the new `dump` connector (`docs/decisions/0037-dump-connector.md`, format `warc`).

## Layout as read

**Crawls (read).** Named `CC-MAIN-YYYY-WW` (year and ISO week of the start); roughly one crawl per month, each about two weeks of fetching. Everything for a crawl is under `crawl-data/<crawl>/`, with `index.html` and `segments/<id>/{warc,wat,wet,crawldiagnostics,robotstxt}/`. Access: anonymous HTTPS at `https://data.commoncrawl.org/<path>`, or S3 `s3://commoncrawl/` (us-east-1; the page asks that bulk access come from that region to avoid transfer fees); a Hugging Face mirror carries selected crawls. Each crawl has `*.paths.gz` listings (read, fetched): for `CC-MAIN-2026-43`, `warc`, `wat`, `wet` and `robotstxt` each list 100000 files, `non200responses` 2, and `cc-index-table.paths.gz` 900 Parquet parts.

**Formats (read).** WARC = the raw crawl: HTTP requests, responses and metadata records. WAT = computed JSON metadata per record (headers, links). WET = plain text extracted from the responses only. A WARC file is a series of independent gzip members, one per record, so any record can be read from its byte offset and length (known; the sample confirms the members; see below). Files are about 0.92 GB compressed (the HEAD of the first file of this crawl: `content-length: 923804210`), so one crawl is about 100000 x 0.9 GB, roughly 90 TB of WARC compressed, with WAT and WET each a fraction of that (derived, not measured). The page says archives "can be hundreds of terabytes".

**URL index (read).** Two forms. (1) The CDX(J) index served by `https://index.commoncrawl.org/<crawl>-index` (lookup by URL, prefix or domain; each line gives the WARC filename, offset and length, status, mime, languages); heavily rate limited (HTTP 503 means slow down, an IP can be blocked for 24 hours), so it suits small lookups only. (2) The columnar index, Apache Parquet at `s3://commoncrawl/cc-index/table/cc-main/warc/`, partitioned by `crawl=` and `subset=` (`warc`, `crawldiagnostics`, `robotstxt`), with columns including `url`, `url_surtkey`, `url_host_registered_domain`, `fetch_status`, `content_mime_type`, `content_languages`, `warc_filename`, `warc_record_offset`, `warc_record_length` (2018 post; later renamed "URL Index"). Meant for Athena or Spark (about $5 per TiB scanned in 2018; known: DuckDB can query it too).

**Politeness and identity (read, faq and ccbot pages).** CCBot is a Nutch-based crawler on Hadoop; user agent `CCBot/2.0 (https://commoncrawl.org/faq/)`; checks robots.txt first (up to five redirects for it, four for pages); honours `Crawl-delay`, nofollow and sitemaps; default wait of a few seconds per site; adaptive back-off on 429 and 5xx; no JavaScript, no cookies; conditional GET; accepts gzip, Brotli and zstd. Dedicated IP ranges with reverse DNS under `crawl.commoncrawl.org`, published as `index.commoncrawl.org/ccbot.json`. Block with `User-agent: CCBot` / `Disallow: /`; an opt-out registry exists. Because robots.txt was honoured at crawl time, the data under-represents sites that block it.

**Terms (read, terms-of-use page; not legal advice).** No open licence is named: access is a "limited, non-assignable ... non-exclusive" licence to use the service; all other rights reserved. The crawled content stays under its owners' rights and terms; users must respect third-party copyright; no harvesting of personal information "for use separately"; lawful use only; users indemnify Common Crawl against claims tied to use of the content for AI or machine learning. For a private offline search over a downloaded subset this is a note for the owner, not a blocker; publishing an index or snippets of third-party pages is the area to check.

## Experiment: a real WARC byte range (observed)

Fetched with `curl -r 0-6291455` and user agent `dksearch-offline-test/0.0` (no other headers or personal data) from `https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-43/segments/1791170053823.21/warc/CC-MAIN-20261005105623-20261005135623-00000.warc.gz` (first line of `warc.paths.gz`). The server answered the HEAD with 200 and the full size 923,804,210 bytes. Saved: 6,291,456 bytes (exactly the range) as `/mnt/scratch/research/commoncrawl-sample/CC-MAIN-20261005105623-20261005135623-00000.warc.gz` (the file is a truncated gzip: `zcat` reports "unexpected end of file" at the cut, as expected). Not run through dksearch; the owner will.

What it holds (inspected with `zcat | grep` only; text treated as untrusted data):
- 19,286,864 bytes decompressed; WARC/1.0 records with CRLF line ends. One `warcinfo` first (isPartOf `CC-MAIN-2026-43`, software `Apache Nutch 1.22 (modified)`, robots checked via crawler-commons, format "WARC File Format 1.1").
- Then triples of 228 `request`, 228 `response`, 227 `metadata` (the last triple is cut). No `revisit` and no `conversion` records. The `warc` subset has only fetches; non-200 results are in the `crawldiagnostics` files.
- Responses: 225 `HTTP/1.1 200 OK` and 3 `HTTP/1.1 200` (no reason phrase: a reader must not require one). Payload type (`WARC-Identified-Payload-Type`): 164 text/html, 56 application/xhtml+xml, 5 application/pdf, 1 text/plain. Some header names are lower case (`content-type`).
- Charsets in the HTTP header: utf-8 in most (one `utf-8;` with a stray semicolon), a few windows-1251 (and one `win-1251`), one shift_jis; the `metadata` record adds `charset-detected: GBK` for a page whose header differs. dksearch's "UTF-8 text only" rule will skip these, counted as `encoding`; the PDFs fall under `wrong_type`.
- No `Content-Encoding` or `Transfer-Encoding` lines were seen in the stored responses (the crawler stored them decoded; `Accept-Encoding: zstd, br, gzip` appears in the *request* record).
- Metadata records carry `fetchTimeMs`, `charset-detected`, and `languages-cld2` JSON (219 of 227): language codes with a confidence, directly usable as a `language` field.
- Request records show the crawler's own headers, including `If-Modified-Since` on a recrawl: this crawl is partly conditional.
- Host mix by top-level domain: com 323, ru 48, net 36, de 30, org 21 (of the URLs, counting the request and response lines): multilingual, mostly commercial pages; expect thin, spammy and non-English content.

## Useful patterns

- Gzip member per record plus an index of (file, offset, length): random access to one page with a single Range request. The same idea fits dksearch's own stored pages and a "fetch this original" link.
- Separating raw (WARC), derived (WAT) and text (WET) files, so a consumer chooses the cost it can pay.
- A listing file per crawl and partition: simple, scriptable bulk fetch.
- Language detection stored per record (`languages-cld2`), so a language filter needs no re-detection.

## Limitations and trade-offs

- Scale: about 90 TB of WARC per crawl; a full crawl is out of reach for a single node, and most of it is boilerplate and spam. Only subsets are practical.
- The bucket is in us-east-1, anonymous HTTPS works but egress bandwidth is the user's; the CDX API is rate limited.
- Quality is uneven: no deduplication across crawls, many languages, charset mismatches, truncated pages (Common Crawl truncates large responses; known).
- Not a live source: a snapshot of two weeks, no updates; fine for a test corpus and a general-knowledge collection, wrong for freshness.
- Terms (above): personal-data and AI-use clauses; third-party rights remain.

## Potential dksearch uses

1. **Test corpus (`test-corpus.md`).** The 6 MB sample is a ready fixture for the WARC reader: it has CRLF, status lines with no phrase, mixed charsets, PDFs, XHTML, a truncated last member and per-record metadata. A tiny trimmed copy (few records, valid gzip) could live in the repository; the large file stays under `/mnt/scratch`.
2. **Subset by domain through the index.** Query the Parquet URL Index (Athena, Spark or DuckDB, outside dksearch) for `url_host_registered_domain IN (...)`, `content_languages = 'eng'`, `fetch_status = 200`, `subset = 'warc'`; or ask the CDX API for one domain. Each row gives `warc_filename, offset, length`; download only those ranges (`curl -r offset-(offset+length-1)`) and concatenate the members into a local `.warc.gz`: gzip members concatenate, so the existing `dump` reader needs no change. A small helper script (not core) could do this; cost for 10,000 pages is tens of MB instead of terabytes.
3. **Per-record fields.** Use `WARC-Target-URI` as the URL, `WARC-Date` as the crawl time, `languages-cld2` for language, and `WARC-Record-ID` as the stable source id (the question below).
4. **WET as a lighter source.** Same layout with text only: no HTML extraction cost, at the price of Common Crawl's extraction quality.
5. Not worth building: a CDX or Athena client inside dksearch (a mandatory external service, against the constraints); keep subset selection as documentation.

## Questions for dksearch

- Source id for `dump` documents: `WARC-Record-ID` (unique, stable) or the URL (merges re-fetches across crawls)? Does the reader store URL and crawl date as fields (the original question in the template)?
- Does the reader read `metadata` records for language and detected charset, and handle `windows-1251` and `shift_jis` by converting instead of skipping (an opt-in)?
- Should the reader stop cleanly at a truncated final member and report it (here: expected)?
- Revisit records exist in other crawls (known; none in this sample): are they skipped, or resolved to the earlier record?
- How large is a useful general-purpose subset (for example `eng`, one registered domain list) and how does import speed compare with `docs/performance.md`?
- Next steps: run the owner's WARC import on the sample and record counts by refusal reason here; try one domain subset through the columnar index with DuckDB.
