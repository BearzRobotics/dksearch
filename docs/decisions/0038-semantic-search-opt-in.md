# 0038: Semantic search, opt-in, over a model server the administrator runs

Status: implemented as a rerank of lexical candidates; a vector index over everything is a later step.

## Context

Lexical search is the default and stays so (docs/decisions: lexical default, semantic opt-in, RAG is retrieval only). People who want matching by meaning need vectors, which need an embedding model. Running a model inside dksearch would make a heavy dependency mandatory and is not the project's business; people already run Ollama or similar.

## Decision

- `[embeddings]` names a server (`url`, `model`, `api` = `ollama` or `openai`). Without it nothing here is used and no network request is made.
- `dksearch embed` makes the vectors from the retained texts (title and the first `max_chars`), in batches, skipping documents that already have one for the model, and stores them as unit-length float32 blobs in `data_dir/vectors.db`, keyed by document and model. They are derived data (the text is the source of truth) and a different model is a separate set.
- Search takes `semantic=1`: the lexical search supplies the candidates (a pool of three times the page, at least 30, at most 100); the query is embedded; the order is the reciprocal-rank fusion (k = 60) of the lexical order and the similarity order. Documents without a vector keep only their lexical share, so a half-made store degrades gracefully. The response says whether it was used and why not.
- Everything fails soft: no server configured, no vectors, an unreachable server or a page beyond the first all return the plain lexical page with the reason.
- dksearch never starts a model or downloads one.

## Alternatives

- A vector index (HNSW or a flat scan) over all documents, which would find documents the words missed: much more storage and code, and a bigger commitment to a model; left for later, the file format (one blob per document) does not stand in its way.
- Embedding the query only inside the retrieval API: passages are chunked at request time, so their vectors would have to be made then; not worth it before documents have vectors at all.
- Linking a model library: heavy, platform-specific, and a reason for the build to stop being simple.

## Consequences

- Semantic ordering needs the model server up at query time (one embedding request per query, with a time limit); if it is down the page is the lexical page.
- Vector quality is the model's; changing `model` needs `embed` again.
- The vector file grows by dimension × 4 bytes per document.
