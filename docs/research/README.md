# Research notes

Notes on reference projects and feature candidates. They record what was investigated and what was learned; they do not describe what dksearch is meant to do (that is `ai/SPEC.md`, the manual and the ADRs in `docs/decisions/`). Nothing here is a commitment. A project listed here is a reference, not a dependency.

Constraints every conclusion is judged against: no mandatory external service; self-hostable and fully usable offline; rebuildable indexes; TOML configuration; no mandatory Docker; modular connectors; a public interface separate from administration; API first; low resource use; distributed and peer-to-peer features optional, with a node staying fully useful alone and able to stay private.

## Method

For each project: read the architecture and developer documentation; examine the source tree; name the major subsystems; trace one representative operation from start to end; note data structures, storage formats, APIs and extension points; run experiments where practical; record ideas, limits and trade-offs; then decide to adopt, adapt or reject. A feature is not adopted because another project has it: weigh complexity, resource use, offline behaviour, security and maintainability.

Each note records: project and version or commit; subsystems studied; experiments and results; useful patterns; limits; possible dksearch uses; follow-up questions. A finding that came from memory or from reading documentation, and not from the source or an experiment, is marked as such.

## Order

| # | Project | Note | Status |
|---|---|---|---|
| 1 | Apache Lucene | [lucene.md](lucene.md) | first pass (source reading); experiments pending |
| 2 | YaCy | [yacy.md](yacy.md) | not started |
| 3 | Apache Nutch | [nutch.md](nutch.md) | not started |
| 4 | Marginalia Search | [marginalia.md](marginalia.md) | not started |
| 5 | Meilisearch | [meilisearch.md](meilisearch.md) | not started |
| 6 | Typesense | [typesense.md](typesense.md) | not started |
| 7 | Vespa | [vespa.md](vespa.md) | not started |
| 8 | SearXNG | [searxng.md](searxng.md) | not started |
| 9 | Common Crawl | [common-crawl.md](common-crawl.md) | not started |
| 10 | Apache StormCrawler | [stormcrawler.md](stormcrawler.md) | not started |

YaCy is studied early because peer-to-peer needs can shape document identifiers, index structures and metadata. Cross-cutting work: [feature-comparison.md](feature-comparison.md), [p2p-experiments.md](p2p-experiments.md), [source-selection.md](source-selection.md), [test-corpus.md](test-corpus.md).

## Rules of the road

- Experiments that fetch from the network use a generic client name and no personal details, and keep data under `/mnt/scratch`.
- Downloaded sources and archives are untrusted: each in its own new directory, nothing run from inside it.
- Heavy converters and model runs are started by the owner, not by an assistant.
