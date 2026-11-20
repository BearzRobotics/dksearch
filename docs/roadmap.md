# Roadmap

What is built is described in the manual (`docs/manpages/`) and the decision records (`docs/decisions/`). This page lists what has been built since the last update, then what is agreed but not built, roughly in the order planned. It records intent, not a promise of dates; items move when the maintainer decides. Last updated 2026-11-19.

Standing rules that shape every item: the core stays lexical and works with no AI involved; anything that calls an external program or service (pdftotext, ffprobe, Docling, MinerU, Ollama, whisper, a headless browser, other search engines) is optional, off by default and documented; one search page that works without JavaScript; the admin panel should reach feature parity with the configuration file. Nothing is tuned by eye any more: a ranking change is measured with `dksearch eval` against the golden queries and the owner's marks (ADRs 0064, 0065).

## Built since ADR 0051

**Search quality and speed**
- Pictures stay out of ordinary results (the Images button finds them), pages in languages the browser did not ask for rank lower, three results a domain by default (ADR 0061); question and filler words are not required (0062); a search of only common words is a phrase, or not ranked, and answers in milliseconds instead of seconds (0069); common words and excerpts made fast on a 414,000-document index (0056).
- The title weight chosen against the owner's marks (0065). Spelling: only words the index lacks are respelled, and "Did you mean" no longer rewrites words that are right; filenames-as-titles rank lower; more HTML entities decoded.
- Tried and measured, not adopted: other forms of a word by query (kept as the option `word_forms`, 0063) and a stemming index (mixed result, 0063).
- A results page with "Page N" and links back to earlier pages; the gallery uses the width of the window.

**The owner's tools**
- Owner login with a password and a Login button, public mode, the export file (0053, 0054); a multi-line search box.
- Good/bad marks on results, kept in `feedback.jsonl` and read by `dksearch eval`, which now measures what the page shows (0064); a box to suggest a missing site, one address or a list, crawled by a source that starts by itself after a change without disturbing a manual run (0066).
- A thumbnail cache, opt-in, with a size cap (0055); pictures of the web shown through a relay that stores nothing (0052); admin buttons: restart, ZIM importer with queue and progress, block lists with Off/Ban/Hide per list.

**Crawler**
- Per-site crawl report and polite backoff (0057); tidy addresses, trap avoidance, link priority, robots.txt sitemaps and feeds (0058); MediaWiki sites listed through their API (0059); optional rendering of script-built pages with an external program, enabled for DevDocs only (0060); dot segments and session parameters removed from addresses; the page's own language recorded.
- Sites behind a bot check (the OSDev wiki and forum, brokenthorn.com) are reported as blocked and not worked around.

**Semantic search**
- Embedding prefixes (for `nomic-embed-text`) and lazy vectors made as searches need them, so no multi-hour first pass is needed (0068). Built and tested against a fake server only.

**Engineering**
- regex-zig 0.3.0, with its own UTF-8 mode and linear-time engines (0067). Fuzz targets for the parsers of outside input, two bugs found and fixed (0070). `zig build test` also builds the program. The manual pages in dkman layout, installed by `zig build` (`-Dman=false` to skip); the Docs page reads them. The decision index is complete.

## Next

**Check what was built but never run for real**
- **Semantic search with a real model:** pull `nomic-embed-text`, embed a few hundred documents at low priority and time it, then compare `semantic=1` with plain search on the golden queries and the owner's marks; decide between the full pass and lazy mode, and whether question-shaped queries should use it by default. A reranker over the top 20 is the next step after that.
- **Live checks by the owner:** the ZIM importer and its queue, the block-list Hide/Ban switches (the `porn` list set to Hide), the crawl report page, the thumbnail cache filling, rendering of DevDocs (does it index the documents?), and the suggested-sites source after a suggestion.
- **More marks:** the golden set is small (11 queries) and partly chosen by the author. Marks on many different searches are what lets the weights (title weight, language factor, per-domain limit) be tuned and the project defaults changed (title weight is 10 in the project, 100 on the owner's instance).

**Search quality**
- Near-duplicate collapse beyond the same address or text; related searches; the score breakdown on the results page (`explain=1` exists); opt-in browser-side session context.
- Typo correction: about a second for a long word (a scan of the vocabulary), and rare near-words can outrank the word meant.
- Old documents keep what they had when stored: no page language, addresses with dot segments, entities in titles. A one-off backfill or a recrawl that does not stop at "not modified" would bring them up to date.
- Other languages: question words, word forms and the language-of-address list are English only.

**Engineering**
- More fuzz targets: the zip reader (office files, EPUB), the HTTP request head and forms, the importers (export file, ZIM), the blocklist parser; a routine for running them; the "corrupted coverage file" message that ends a Zig 0.17.1 fuzz report.
- Big files: `admin.zig`, `handler.zig`, `crawl.zig` and `index_sqlite.zig` are 3,000 to 5,000 lines each, much of it tests; split when touching them.
- The test suite takes several minutes, mostly writing to a slow disk (see "Build and test cache on a fast disk" in the manual).

## Then

- **Management:** saved searches and opt-in statistics (no query logging by default).
- **Playing media in the browser:** an embedded player in the viewer, with HTTP range requests and streaming for original files (today an original is sent whole, up to 64 MiB), and a start time taken from the result.
- **Speech-to-text (opt-in):** transcribe spoken-word audio and video with an external program (whisper.cpp or faster-whisper), producing timestamped chunks so a result can start playback at the right moment. Off by default; slow on a CPU, so tried on a sample first.
- **Public instance:** the guide for a small hosted server and the three ways to reach the home server (WireGuard, dynamic DNS, a static address) are written (`docs/deploy/`); putting `dksearch.org` online is the owner's step.
- **Import `/stuff/Pics`** when the owner asks (the safe-search PIN is set).

## Later, optional

- **A public network:** discovery, reputation and abuse handling for nodes that do not know each other. Needs the signed node identity (ADR 0040) to have been used first.
- **Serving dksearch as a hidden service** (crawling Tor and I2P sites is built, ADR 0044): an onion service (Tor) and an I2P tunnel pointing at the search or admin address; configured in the router, with dksearch refusing to expose the admin interface that way unless asked.
- **Replication details:** removing from a copy the documents the owner removed (a deletion feed).
- **OCR for scanned PDFs** through Docling or MinerU (started by the owner, never by dksearch), on the drive planned for the PDFs.

## Known limits (see the manual and the decision records)

A hostname is checked for private addresses before the first request but a DNS answer that changes in between (rebinding) is not stopped; the crawler schedules and conditionally requests only pages at the depth limit (ADRs 0036 and 0051), the others are always fetched; regex over characters has Unicode simple case folding and properties but not full folding, and look-behind needs a fixed width in bytes (regex-zig 0.3.0, ADR 0067); ZIM support is tested on small real files only; Wuffs (image decoding) is alpha upstream; the vector index is an exact scan held in memory (ADR 0043), fine to millions of documents, a graph index would be the step beyond; the results of a search for a word too common to rank are unranked, newest first (ADR 0069); semantic search, its prefixes and lazy mode have been tested only against a fake embedding server (ADR 0068); the ranking weights rest on about a dozen judged queries (ADR 0065).
