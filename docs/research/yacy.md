# YaCy

Status: not started. Research order: 2 of 10.

- Focus: P2P indexing, discovery and distributed queries.
- Source: <https://github.com/yacy/yacy_search_server>
- Version or commit examined: (to be recorded)

## What to examine

- Reverse word index and DHT distribution
- Peer discovery, bootstrap, identity
- Remote queries versus index exchange
- Private versus public networks, trust and reputation
- Crawl scheduling, robots.txt, per-host limits, recrawling

## Experiments planned

- [ ] Two nodes: A indexes a collection B lacks; search from B; disconnect A; reconnect
- [ ] Measure traffic, latency, resources
- [ ] Verify private content is not shared

## Findings

(Nothing yet. Record observations from the source and from experiments here, with file names and commit.)

## Useful patterns

## Limitations and trade-offs

## Potential dksearch applications

## Questions for dksearch

- Share index entries, execute remote queries, or both?
- How are private and public collections separated?
- How are malicious peers and index poisoning handled?
- Do document ids need to be globally comparable? (dksearch ids derive from source name and source id today)

## Decisions and follow-ups

(Link an ADR in `docs/decisions/` when this leads to a decision.)
