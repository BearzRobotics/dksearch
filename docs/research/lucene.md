# Apache Lucene

Status: not started. Research order: 1 of 10.

- Focus: Inverted index and search fundamentals.
- Source: <https://github.com/apache/lucene>
- Version or commit examined: (to be recorded)

## What to examine

- Analyzers, Unicode normalization
- Postings, term dictionary, positions, offsets
- Segments, merging, updates and deletions
- BM25 and phrase/proximity queries
- Index versioning and corruption detection

## Experiments planned

- [ ] Index a representative collection; measure index size and query speed against dksearch's SQLite FTS5 index
- [ ] Compare exact, phrase, fuzzy and prefix queries
- [ ] Observe segment merging and deletions

## Findings

(Nothing yet. Record observations from the source and from experiments here, with file names and commit.)

## Useful patterns

## Limitations and trade-offs

## Potential dksearch applications

## Questions for dksearch

- Which structures does dksearch need beyond FTS5 (positions, offsets for snippets and page references)?
- What can be rebuilt from stored text (dksearch already keeps retained text and can `rebuild`)?
- How should the index format be versioned?

## Decisions and follow-ups

(Link an ADR in `docs/decisions/` when this leads to a decision.)
