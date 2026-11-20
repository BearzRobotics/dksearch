# 0068: Embedding prefixes, and vectors made as searches need them

Status: accepted, not yet run against a real model

## Context

Semantic search (ADR 0038) reorders the lexical candidates by the similarity of document vectors to the query's. Two things stood between it and a model such as `nomic-embed-text` (137M parameters, CPU only on the owner's machine):

1. Such a model is trained with task prefixes (`search_query:`, `search_document:`) and is less accurate without them; dksearch sent none.
2. Vectors for 414,000 documents are made by one pass (`dksearch embed`) that, on a CPU, takes hours (an estimate, not a measurement), and until it has run nothing is reordered.

## Decision

- `[embeddings] query_prefix` and `document_prefix` are put before the query and before each document's text. The key under which a vector is kept in `vectors.db` is the model plus a fingerprint of the two prefixes (`embed.keyFor`), so vectors made with different prefixes are never compared; with no prefixes the key is the model, as before and existing vectors stay valid.
- `[embeddings] lazy = true`: when a search asks for meaning, the candidates among the lexical results that have no vector (at most `lazy_max`, in rank order, one request, `lazy_timeout_ms`) are embedded and kept (`embed.fillMissing`). Off by default; with it, the server opens `vectors.db` for writing. A model that is slow or down makes none and changes nothing.

## Consequences

Semantic search is useful from the first search without the long pass; the pass (`dksearch embed`, a job in the administration interface) stays for those who want everything embedded. The first search that shows a document pays for its vector (about a request per search at first, then fewer). The tests use a fake embedding server only; how much time and accuracy this gives with a real model is not measured, and the recommended first step when one is available is to embed a few hundred documents, time it, and compare `semantic=1` with plain search on the golden queries and the owner's marks (ADR 0064).
