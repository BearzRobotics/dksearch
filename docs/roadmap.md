# Roadmap

What is built is described in the manual (`docs/manpages/`) and the decision records (`docs/decisions/`). This page lists what is agreed but not built, roughly in the order planned. It records intent, not a promise of dates; items move when the maintainer decides.

Standing rules that shape every item: the core stays lexical and works with no AI involved; anything that calls an external program or service (pdftotext, ffprobe, Docling, MinerU, Ollama, whisper, other search engines) is optional, off by default and documented; one search page that works without JavaScript; the admin panel should reach feature parity with the configuration file.

## Next

- **Known limits to remove:** ZIM support tested on large real files (needs a multi-gigabyte download chosen by the owner). Built: per-page adaptive recrawl (ADR 0051), regular expressions on characters (ADR 0050).

## Then

- **Pictures from the web:** the crawler records the pictures it sees on pages (address, alt text, page) as small records and the gallery shows them through an on-demand relay that stores nothing; an opt-in thumbnail cache later.
- **Management:** saved searches and opt-in statistics (no query logging by default).
- **Playing media in the browser:** an embedded player in the viewer, with HTTP range requests and streaming for original files (today an original is sent whole, up to 64 MiB), and a start time taken from the result.
- **Speech-to-text (opt-in):** transcribe spoken-word audio and video with an external program (whisper.cpp or faster-whisper), producing timestamped chunks so a result can start playback at the right moment. Off by default; slow on a CPU, so tried on a sample first.

## Later, optional

- **A public network:** discovery, reputation and abuse handling for nodes that do not know each other. Needs the signed node identity (ADR 0040) to have been used first.
- **Serving dksearch as a hidden service** (crawling Tor and I2P sites is built, ADR 0044): an onion service (Tor) and an I2P tunnel pointing at the search or admin address; configured in the router, with dksearch refusing to expose the admin interface that way unless asked.
- **Replication details:** removing from a copy the documents the owner removed (a deletion feed).
- **OCR for scanned PDFs** through Docling or MinerU (started by the owner, never by dksearch).

## Known limits (see the manual and the decision records)

A hostname is checked for private addresses before the first request but a DNS answer that changes in between (rebinding) is not stopped; the crawler schedules and conditionally requests only pages at the depth limit (ADRs 0036 and 0051), the others are always fetched; regex over characters is ASCII-only for case folding, `\\d` and `\\s`; ZIM support is tested on small real files only; Wuffs (image decoding) is alpha upstream; the vector index is an exact scan held in memory (ADR 0043), fine to millions of documents, a graph index would be the step beyond.
