# Roadmap

What is built is described in the manual (`docs/manpages/`) and the decision records (`docs/decisions/`). This page lists what is agreed but not built, roughly in the order planned. It records intent, not a promise of dates; items move when the maintainer decides.

Standing rules that shape every item: the core stays lexical and works with no AI involved; anything that calls an external program or service (pdftotext, ffprobe, Docling, MinerU, Ollama, whisper) is optional, off by default and documented; one search page that works without JavaScript; the admin panel should reach feature parity with the configuration file.

## Next

- **Audio and video, metadata (done):** tags and technical details through `ffprobe` (title, artist, album, year, genre, duration, codecs) for `mp3`, `m4a`, `ogg`, `flac`, `mp4` and similar, and subtitle or lyrics files next to the media (`.srt`, `.vtt`, `.lrc`) as searchable text.
- **Rich viewer (done):** Markdown rendered through `md-zig` and the HTML sanitizer; ZIM articles shown from the ZIM file with their images and internal links working.
- **Search results in the API (done):** file kind, size, dates, domain and the rest of what the index knows in the JSON, `filter` parameters and sort modes.
- **Office and ebook text (mostly done):** `docx`, `odt` and `epub` extraction on `xml-zig` (zip plus XML) and an HTML option for the files connector are built (`office = true`, `html = true`); the Wikipedia, feeds and crawl connectors now read XML with `xml-zig` too and the C Expat is gone.
- **Parallel external extraction:** several `pdftotext` processes at once, for libraries of tens of thousands of PDFs (a 28,000-PDF library is the test case).
- **Admin panel, feature complete (in progress):** every source option as a labelled field with help and validation (done); a Settings page for the search, server and admin settings (done); runs and schedules (done: `schedule` per source, run by the server), a list of skipped items with the reason (done: examples per job).

## Then

- **Chunks, pages and RAG retrieval (version 1 done):** `GET /api/v1/retrieve` returns the best passages (section-aware chunks with heading path, byte span, neighbours, source attribution) for a query, chunking the candidates' stored text per request (ADR 0030). Still to do: page numbers (need page breaks in the text: Docling's page-break option, or PDF pages), a persistent chunk index and dense or hybrid retrieval with embeddings, ingest of MinerU output, parent-section expansion. dksearch stays the retrieval backend; an answer endpoint remains an optional add-on.
- **Ranking controls:** configurable field weights, recency and per-source boosts, sort modes, an explain output, stop words and synonyms.
- **Semantic and hybrid search:** embeddings from a configurable provider (local Ollama first), opt-in, with lexical search staying the default; reranking.
- **Collections and access control (mostly done):** collections, anonymous scope and API keys with per-collection scopes work (ADR 0033), with an Access page in the administration interface. Still to do: editing collections from the interface (they are in the configuration file and apply at restart), rate limits per key, and federated search across paired nodes (`docs/research/p2p-plan.md`).
- **Search by image everywhere:** the files connector reading EXIF and perceptual hashes, a `find-image` command, admin upload.
- **Presentation:** result grouping, several snippets, similar documents, autocomplete (server side, no script required), did-you-mean, cursor paging.
- **Management:** saved searches, opt-in statistics (no query logging by default), caching, rate limits.
- **Kiwix library helper (done):** search the catalogue and download ZIM files after confirmation from the admin interface (ADR 0028). Still to come: adding the source automatically, a free-space check.

## Later, optional

- **Stack Exchange data dumps:** the Stack Exchange sites answer 418 to crawlers (their `robots.txt` cannot be read, so a polite crawler skips them); the official data dumps (CC BY-SA, XML: posts, comments, users per site) are the supported way. A connector would stream them with `xml-zig`, keeping questions with their accepted answers and tags. The dumps are 7z archives, so reading them also needs an LZMA-based 7z reader.

- **Reddit content, by permitted routes only (chosen: feeds now, dumps later):** the crawler obeys `robots.txt` and Reddit disallows all crawlers, so there is no crawl source for it. Chosen: subreddit `.rss` feeds through the feeds connector (works today; needs a list of subreddits and a descriptive user agent), and a connector for shared archive dumps (compressed JSON lines of posts and comments) that keeps the links found in them as a searchable field, each after checking the terms of the dump used. Also chosen: a connector for Reddit's official API with OAuth, so subreddits (and the account's own saved posts and comments) can be read with the history and rate limits Reddit grants an approved app, instead of the 25 to 100 newest posts of a feed. It will need an app the user registers with Reddit (client id and secret kept in the secrets file, never in the main config), the user agent format Reddit requires, requests kept under the granted rate limit, and respect for Reddit's data terms, including removing posts and comments that were deleted on Reddit. Also possible later: the account's own data export.

- **Speech-to-text:** transcribe spoken-word audio and video with an external program (whisper.cpp or faster-whisper), producing timestamped chunks so a result can start playback at the right moment. Off by default; slow on a CPU, so tried on a sample first.
- **Playing media in the browser:** an embedded player in the viewer, with HTTP range requests and streaming for original files (today an original is sent whole, up to 64 MiB), and a start time taken from the result.
- **Document-server integration:** viewing Office files through ONLYOFFICE, Euro-Office or Collabora running as a separate service, with short-lived signed file addresses.
- **OCR for scanned PDFs** through Docling or MinerU.

## Known limits (see the manual and the decision records)

Fuzzy matching allows up to two edits (from the vocabulary); the crawler is concurrent and breadth-first (ADR 0032) but does not send conditional requests or recrawl by schedule per page; regex is bytewise; the crawler does not detect a hostname that resolves to a private address; ZIM support is tested on small real files only; Wuffs (image decoding) is alpha upstream.
