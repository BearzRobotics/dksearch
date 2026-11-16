# Roadmap

What is built is described in the manual (`docs/manpages/`) and the decision records (`docs/decisions/`). This page lists what is agreed but not built, roughly in the order planned. It records intent, not a promise of dates; items move when the maintainer decides.

Standing rules that shape every item: the core stays lexical and works with no AI involved; anything that calls an external program or service (pdftotext, ffprobe, Docling, MinerU, Ollama, whisper) is optional, off by default and documented; one search page that works without JavaScript; the admin panel should reach feature parity with the configuration file.

## Next

- **Audio and video, metadata (done):** tags and technical details through `ffprobe` (title, artist, album, year, genre, duration, codecs) for `mp3`, `m4a`, `ogg`, `flac`, `mp4` and similar, and subtitle or lyrics files next to the media (`.srt`, `.vtt`, `.lrc`) as searchable text.
- **Rich viewer:** Markdown rendered through `md-zig` and the HTML sanitizer; ZIM articles shown from the ZIM file with their images and internal links working; plain text with paragraphs kept.
- **Search results in the API:** file kind, size, dates, domain and the rest of what the index knows in the JSON, plus filter parameters and sort modes.
- **Office and ebook text:** `docx`, `odt` and `epub` extraction on `xml-zig` (zip plus XML), an HTML option for the files connector, and the switch of the Wikipedia connector from Expat to `xml-zig`.
- **Parallel external extraction:** several `pdftotext` processes at once, for libraries of tens of thousands of PDFs (a 28,000-PDF library is the test case).
- **Admin panel, feature complete:** every source option as a labelled field with help and validation, server settings, runs and schedules, a list of skipped items with the reason.

## Then

- **Chunks, pages and RAG retrieval:** a section and page model, ingest of Docling and MinerU output (structure, page numbers), a retrieval API (top chunks, neighbours, parent document, attribution). dksearch is the retrieval backend, not the whole RAG system; an optional "ask" endpoint that calls a local LLM may come later as an add-on, never in the core.
- **Ranking controls:** configurable field weights, recency and per-source boosts, sort modes, an explain output, stop words and synonyms.
- **Semantic and hybrid search:** embeddings from a configurable provider (local Ollama first), opt-in, with lexical search staying the default; reranking.
- **Collections and access control:** collections, scoped and federated search, API keys with per-collection scopes.
- **Search by image everywhere:** the files connector reading EXIF and perceptual hashes, a `find-image` command, admin upload.
- **Presentation:** result grouping, several snippets, similar documents, autocomplete (server side, no script required), did-you-mean, cursor paging.
- **Management:** saved searches, opt-in statistics (no query logging by default), caching, rate limits, a Kiwix library helper that downloads ZIM files after confirmation.

## Later, optional

- **Speech-to-text:** transcribe spoken-word audio and video with an external program (whisper.cpp or faster-whisper), producing timestamped chunks so a result can start playback at the right moment. Off by default; slow on a CPU, so tried on a sample first.
- **Playing media in the browser:** an embedded player in the viewer, with HTTP range requests and streaming for original files (today an original is sent whole, up to 64 MiB), and a start time taken from the result.
- **Document-server integration:** viewing Office files through ONLYOFFICE, Euro-Office or Collabora running as a separate service, with short-lived signed file addresses.
- **OCR for scanned PDFs** through Docling or MinerU.

## Known limits (see the manual and the decision records)

Fuzzy matching is one edit; regex is bytewise; the crawler does not detect a hostname that resolves to a private address; ZIM support is tested on small real files only; Wuffs (image decoding) is alpha upstream.
