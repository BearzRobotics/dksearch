# Apache Lucene

Status: first pass done (source reading of the codec and merge code; no experiments yet). Research order: 1 of 10.

- Focus: inverted index and search fundamentals.
- Source: <https://github.com/apache/lucene>, shallow clone at `/mnt/scratch/research/lucene`.
- Version examined: commit `9965d34e3c77` (2026-11-16, the 10.x line: codec `Lucene104`, segments format `VERSION_10_6`).
- Claims below marked (read) were checked in the files named; (known) come from prior knowledge and are not yet verified against the source or an experiment.

## What was examined

All paths are under `lucene/core/src/java/org/apache/lucene/`.

- `codecs/lucene104/Lucene104PostingsFormat.java`, `PForUtil.java`, `ForUtil.java`: how postings are written.
- `codecs/lucene103/blocktree/`: the term dictionary.
- `codecs/lucene90/Lucene90StoredFieldsFormat.java`, `Lucene90LiveDocsFormat.java`: stored fields and deletions.
- `codecs/CodecUtil.java`, `index/SegmentInfos.java`: file headers, footers and index versions.
- `index/TieredMergePolicy.java`: how segments are merged.
- `search/similarities/BM25Similarity.java`: scoring.
- `codecs/lucene99/Lucene99HnswVectorsFormat.java`: the vector index (for later, semantic search).

## Findings

**Postings (read).** Per term, document ids and frequencies are stored in packed blocks of a fixed number of integers (the format's comment says 256), each block at one bit width (frame of reference, with a special case for blocks of one repeated value); a term's leftover postings (fewer than a block) are variable-length integers. Skip data is interleaved with the blocks on two levels (after every block, and after every 32 blocks), so a query for `a AND b` can jump over blocks. Positions live in a separate `.pos` file and payloads and offsets in `.pay`, so a query that needs only positions does not read offsets. The files of one segment: `.tim` (term dictionary), `.tip` (term index), `.doc` (documents, frequencies, skips), `.pos`, `.pay`.

**Term dictionary (read, partly).** A block tree: terms sorted, grouped in blocks with a small in-memory index (`.tip`) pointing at blocks of `.tim`; per-term statistics (document frequency) and file pointers sit in the block. (known) The index is a finite-state transducer over term prefixes.

**Segments and deletions (read, partly).** An index is a set of immutable segments; new documents make new segments; deleting marks a bit in a per-segment live-documents bit set (dense or sparse implementations exist) and the space returns when segments merge. `TieredMergePolicy` defaults: segments per tier 8, largest merged segment 5 GiB, floor segment size 16 MiB, merge a segment when more than 20 % of it is deleted.

**Stored fields (read).** Stored in compressed blocks with two modes, `BEST_SPEED` (the default) and `BEST_COMPRESSION` (LZ4 with a preset dictionary against Deflate with a preset dictionary, from the file names `LZ4WithPresetDictCompressionMode` and `DeflateWithPresetDictCompressionMode`).

**Scoring (read).** `BM25Similarity` defaults `k1 = 1.2`, `b = 0.75`. dksearch's SQLite FTS5 `bm25()` uses the same constants (known), so the scoring formulas agree; what differs is that Lucene applies field weights outside the similarity (boosts) while FTS5 weighs term counts per column before the saturation step (found while building `explain=1`: the title-only and text-only scores do not add up to the combined one).

**Corruption detection and versions (read).** Every index file has a header and a footer carrying a checksum (`CodecUtil`), checked when a file is opened or on demand (`checkIntegrity`). The segments file carries a format version (`VERSION_74` to `VERSION_10_6` here); an index written long ago is refused with `IndexFormatTooOldException` rather than guessed at, and (known) Lucene only reads indexes written by the previous major version and expects reindexing beyond that.

**Vectors (read, names only).** HNSW graphs (`Lucene99HnswVectorsFormat`, parameters max connections and beam width) with optional scalar quantization (`Lucene104ScalarQuantizedVectorsFormat`).

## Useful patterns

- Immutable segments plus background merging make writes cheap and crash-safe: nothing is modified in place, a commit is a new segments file.
- A format version in the file, with a clear refusal on versions that are too old or too new, instead of silent misreading.
- Per-file checksums so corruption is found by checking, not by wrong answers.
- Positions kept apart from document lists, so common queries stay on the small file.

## Limitations and trade-offs for dksearch

- Lucene is a Java library with a large, version-bound codec surface; reproducing the format is out of scope. dksearch's index is SQLite FTS5, which already gives postings with positions, prefix and phrase queries, bm25 and transactional updates. Its measured size is about twice the text (see `docs/performance.md`).
- FTS5 has no per-term skip structure we control and no fuzzy matching of its own; dksearch expands typos by generating variants (edit distance 1). Lucene's FST-based fuzzy automata allow edit distance 2 cheaply. This is the main capability gap seen so far.

## Potential applications

1. **Edit distance 2 for fuzzy search** by a precomputed term list (a sorted vocabulary file or table) queried with a Levenshtein automaton, instead of generating variants. Candidate; needs a vocabulary table.
2. **Checksums for dksearch's own files.** `dksearch check` verifies SQLite integrity and text hashes; a per-backup checksum manifest would add Lucene's "detect before trusting" for restore. Small.
3. **Index version policy.** dksearch has schema migrations and a tokenizer-mismatch check; stating the rule "a newer file is refused, an older one is migrated or rebuilt" in one place would match Lucene's discipline (ADR candidate).
4. **Positions for citations.** Phrase search already needs positions; page and section references for retrieval are done outside the index (see ADR 0030). A stored-chunk index would be a second FTS table, not a new format.

## Experiments planned (not done)

- [ ] Build the same collection (Simple English Wikipedia) in Lucene and compare index size and query latency with `docs/performance.md`.
- [ ] Compare exact, phrase, fuzzy (distance 1 and 2) and prefix queries on the same queries file.
- [ ] Observe segment merging and deletions while updating a subset.

## Questions

- Is edit distance 2 worth a vocabulary table (disk and update cost against better typo recovery)?
- Should the index file carry its own version and checksum header separate from SQLite's?
