# 0034: Peers and federated search

Status: implemented for search and retrieval; administration pages are a follow-up.

## Context

`docs/research/p2p-plan.md` (from the YaCy study) proposes starting with queries between trusted, paired nodes instead of exchanging indexes. Collections and API keys (ADR 0033) provide the sharing boundary.

## Decision

- **Peers are configured** (`[node] name`, `[[peer]]` with name, URL, key or key file, time limit). No discovery. A node name is required with peers.
- **The wire protocol is the existing API**: a peer is asked `GET /api/v1/search?q=...&limit=N` with `Authorization: Bearer <key>`. What it returns is already limited to the collections of that key. Nothing new to design or version yet; the JSON of the search API is the contract.
- **Only the query text and the page size are forwarded.** Source picks and filters are about this node's sources. `peers` is never forwarded, so peers do not ask peers (no loops, no amplification).
- **Asked in parallel, each with its own deadline** (default 1500 ms), on one shared HTTP client (the crawler's fetch with a deadline). The slowest peer sets the delay, never more than its limit. A failing peer is skipped for 5 s doubling to 5 min.
- **Untrusted answers**: body at most 512 KiB, at most 50 results, every string cut to a bound, ids must be 32 hex digits, malformed entries are skipped (an answer that is mostly malformed is refused), scores are ignored for ordering, and the link to a result's page is built from the id and the configured URL, never taken from the answer. The page escapes everything as for local results.
- **Merging by reciprocal-rank fusion** (k = 60): index scores are not comparable. The same page on several nodes is one result (identity: the address without scheme, host case, fragment and trailing slash; files have none and stay separate), shown from this node when it has it, with `also_on` naming the others.
- **Limited callers do not get peers.** A caller whose scope is limited by a key or the anonymous setting is neither offered nor given federated results, because the key this node holds for a peer is a different privilege than theirs.
- **Federated retrieval** is the same over `/api/v1/retrieve` (`peers=1`): each node returns its best passages with attribution, the asking node fuses the lists by rank, a passage of the same page and start counts once, a peer's passages link to that peer, and their pictures are not carried (those addresses need the peer's key). Peers get twice the search time limit because finding passages reads and splits documents.
- The page works without JavaScript; the merge happens on the server.

## Alternatives

- Index exchange or a DHT (YaCy): solves discovery among thousands of peers, which a handful of trusted nodes do not have, and brings poisoning and spam with it.
- Scores normalised per peer: needs knowledge of the other index. Fusion by rank is robust and simple; revisit with a test corpus (open question in the plan).
- Peers forwarding to their peers: loops and amplification for no gain at this size.

## Consequences

- A node needs a key for each peer and the peer's operator must issue it; revoking the key ends the sharing at once.
- Links to a peer's pages need browser access to that peer (no key in a browser); a proxy that adds the key is a later, explicit option.
- Still to do: federated retrieval (passages with attribution), a content-based document identity to merge the same file across nodes, admin pages with peer status and a pairing test, caching of remote answers.
