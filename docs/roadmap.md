# Roadmap

What is built is described in the manual (`docs/manpages/`) and the decision records (`docs/decisions/`). This page lists what is agreed but not built, roughly in the order planned. It records intent, not a promise of dates; items move when the maintainer decides.

Standing rules that shape every item: the core stays lexical and works with no AI involved; anything that calls an external program or service (pdftotext, ffprobe, Docling, MinerU, Ollama, whisper, other search engines) is optional, off by default and documented; one search page that works without JavaScript; the admin panel should reach feature parity with the configuration file.

## Next

- **Known limits to remove:** recrawl by schedule per page (adaptive interval, conditional requests), regular expressions on characters instead of bytes, ZIM support tested on large real files.

## Then

- **Presentation:** several snippets per result, similar documents, autocomplete (server side, no script required), did-you-mean, cursor paging.
- **Search by image everywhere:** a `find-image` command and an admin upload over the perceptual hashes the files connector already stores.
- **Management:** saved searches and opt-in statistics (no query logging by default).
- **Playing media in the browser:** an embedded player in the viewer, with HTTP range requests and streaming for original files (today an original is sent whole, up to 64 MiB), and a start time taken from the result.
- **Speech-to-text (opt-in):** transcribe spoken-word audio and video with an external program (whisper.cpp or faster-whisper), producing timestamped chunks so a result can start playback at the right moment. Off by default; slow on a CPU, so tried on a sample first.

## Later, optional

- **A public network:** discovery, reputation and abuse handling for nodes that do not know each other. Needs the signed node identity (ADR 0040) to have been used first.
- **Replication details:** removing from a copy the documents the owner removed (a deletion feed).
- **OCR for scanned PDFs** through Docling or MinerU (started by the owner, never by dksearch).

## Known limits (see the manual and the decision records)

A hostname is checked for private addresses before the first request but a DNS answer that changes in between (rebinding) is not stopped; the crawler sends conditional requests only for pages at the depth limit (ADR 0036) and does not recrawl by schedule per page; regex is bytewise; ZIM support is tested on small real files only; Wuffs (image decoding) is alpha upstream; the vector index is an exact scan held in memory (ADR 0043), fine to millions of documents, a graph index would be the step beyond.
