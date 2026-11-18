# 0046: Similar documents

Status: implemented.

## Decision

- **By vectors when there are any**: if the server has a vector index (ADR 0043) with the document in it, the nearest vectors are the similar documents.
- **Otherwise by distinguishing words**: the 40 most frequent words (4 to 30 characters, not numbers) of the stored text, scored by frequency times the logarithm of the share of documents that lack them (document frequencies come from the index vocabulary), those in more than a third of documents dropped, the best eight searched for joined with OR. The engine's own ranking orders the answer.
- The document itself and documents outside the caller's scope never appear. Nothing is stored or indexed for this; it is computed when the page or `GET /api/v1/similar` is asked.

## Alternatives

- MinHash or shingling: finds near-duplicates, not related documents.
- Always requiring vectors: the core stays lexical (ADR 0030).

## Consequences

- Quality depends on the document's text; short or unstored documents yield few or none.
- Costs one search and up to 40 vocabulary lookups per document page.
