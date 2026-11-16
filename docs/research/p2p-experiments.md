# Peer-to-peer: questions, prototype sequence and tests

Peer-to-peer is a wanted capability, researched early because it may shape document identifiers, index structures and metadata. It extends a standalone node and never replaces it: a node must stay fully useful with no peers, and private, local-only operation must always be possible. Participation and sharing are configurable.

## Architecture rule

Keep three subsystems distinct: the local search engine, the ingestion connectors, and the peer network. All ingestion feeds the shared indexing pipeline; all local and remote queries use one query model; the network adds remote index discovery and query execution without making local search depend on it.

## Facts about today's design that matter for peers

- Document ids are derived from the source name and the source's own id, so two nodes would give the same document different ids. A peer protocol needs either content-derived ids or a mapping layer.
- The index is derived data and can be rebuilt from stored text; shared data therefore could be text, metadata or postings, which is a design choice to make from the study.
- Collections and API keys are planned but not built; "share only selected collections" depends on them.

## Questions to answer (from the plan)

What do peers share: postings, metadata, embeddings, crawl tasks, cached text, original documents? Share index entries, execute remote queries, or both? Only selected collections? How are private and public indexes separated, local and remote results merged and attributed, duplicates handled, stale entries invalidated? What happens when peers disappear, and how are malicious peers and index poisoning detected? How do storage and bandwidth limits work? Can a private network run entirely on a LAN or VPN? How do disconnected nodes reconcile?

## Prototype sequence

1. Standalone node (exists): local search works with networking absent.
2. Peer discovery: two nodes on a private network.
3. Remote queries: node B searches node A's index.
4. Distributed term lookup experiments.
5. Merging local and remote results, with attribution.
6. Selective sharing: one collection shared, another private.
7. Replication of selected index data.
8. Cooperative ingestion.
9. Failure recovery: disconnect and reconnect.
10. Security tests: malformed responses, stale entries, excessive claims, resource exhaustion.

Begin with a two-node private network.

## Test cases

Standalone node; two peers on a LAN; a peer temporarily unavailable; a peer removed for good; public and private collections; duplicates across peers; stale remote metadata; limited storage and bandwidth; malformed peer responses; network partition and reconnection.

## Experiment log

(Empty. The YaCy experiments belong in [yacy.md](yacy.md); record results of dksearch prototypes here.)
