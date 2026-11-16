# 0030: Retrieval API for RAG (chunks of candidate documents, ranked on the fly)

Status: implemented (version 1). Persistent chunks and semantic retrieval are follow-ups.

## Context

dksearch is a retrieval backend for RAG clients: the client sends a question and gets the best passages with enough attribution to cite them. Its documents are often large (books, Docling Markdown of 1 to 50 MB), so returning whole documents or one snippet per document is not enough. The retrieval must be optional, work with no model and no network, and not require a rebuild of existing indexes.

## Decision

- `GET /api/v1/retrieve?q=...` finds candidate documents exactly as a search does (`q` with the whole query language, `source`, `filter`, `connector`; up to `candidates`, default 30, at most 100), reads their stored texts from the content store, splits them into chunks and ranks the chunks with BM25 over the query's words (a heading match counts double). It returns the best `k` chunks (default 8, at most 50), each with its document id, view URL, source, title, address, heading path, position and count of chunks, byte span in the stored text, page (when known), score and text, and with `context=N` the N chunks before and after.
- Chunking (`src/retrieve.zig`) is section-aware and paragraph-based: chunks of about `chunk_chars` (default 1200) never span a heading unless the section is tiny, an over-long paragraph is split at line, sentence or space ends, neighbours overlap by whole paragraphs up to `overlap` bytes (default 150). Inline data-URI images are dropped. A page number is given when the text has page breaks (a form feed or `<!-- page break -->`).
- Chunks are computed per request, not stored. The index and the stored texts are unchanged, so every source works at once, nothing needs rebuilding, and there is no second copy of the text. The cost is reading the candidates' texts (bounded: 8 MiB per document, 64 MiB per request).
- The files connector now removes inline data-URI images from Markdown before indexing, and applies the size limit to what is left, because converters embed images as base64 that would otherwise dominate the index (a 49 MB Docling file is mostly one such blob).
- Retrieval only: no generation endpoint (see the scope decisions). Dense or hybrid retrieval will be added as an option when embeddings exist; it will need stored chunks, at which point the chunker is reused.

## Alternatives

- A persistent chunk table and a second full-text index: better recall inside very large documents and no per-request chunking, but doubles the index, needs a rebuild path and a per-source switch. Deferred until embeddings need stored chunks anyway.
- Passage ranking inside SQLite only (FTS5 over chunks): same storage cost, same deferral.
- Candidate selection by document-level BM25 can miss a book whose relevant section is a small part of a very large text. The `candidates` parameter and a narrower query (or `source`, `filter`) are the remedies in v1; the persistent index is the real fix.

## Consequences

- Latency grows with candidate count and text size (milliseconds for ordinary documents, more for several multi-megabyte books).
- Page citations need page breaks in the text. Docling's Markdown has none by default; its page-break option, or indexing the PDF alongside, would supply them (to be tried, by the owner, since conversions are theirs to run).
- Documents from sources with `retain_text = false` have no stored text and are counted in `without_text`, never returned.
