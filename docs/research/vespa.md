# Vespa

Status: not started. Research order: 7 of 10.

- Focus: Advanced ranking and hybrid search.
- Source: <https://github.com/vespa-engine/vespa>
- Version or commit examined: (to be recorded)

## What to examine

- Ranking profiles and multi-stage ranking
- BM25, vector search, hybrid retrieval, reranking
- Ranking explanations, grouping

## Experiments planned

- [ ] BM25 only versus hybrid; title weighting; first stage versus reranked; metadata filtering

## Findings

(Nothing yet. Record observations from the source and from experiments here, with file names and commit.)

## Useful patterns

## Limitations and trade-offs

## Potential dksearch applications

## Questions for dksearch

- Should ranking be a configurable pipeline? (weights, boosts and recency are settings today)
- How are ranking profiles written in TOML?
- How are lexical and semantic results combined? (semantic stays optional)

## Decisions and follow-ups

(Link an ADR in `docs/decisions/` when this leads to a decision.)
