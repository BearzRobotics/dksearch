# A plan for peer-to-peer in dksearch

Status: proposal, from the YaCy study ([yacy.md](yacy.md)) and the project's own constraints. Nothing here is built. It is ordered so that every step is useful on its own and none makes a lone node depend on the network.

## What YaCy teaches, in short

1. **Remote queries and index exchange are different things.** YaCy does both, and the second is where its hard problems live (poisoned references, spam, who stores what, stale entries). Sharing the *answers* to queries needs none of that.
2. **Bootstrap is the weak point.** YaCy assumes a populated public network; a private pair needed a manual handshake after every restart. Pairing must be explicit and persistent.
3. **Identity is unsigned.** Anyone can claim any hash. A private network does not need a DHT, only authenticated peers.
4. **A network is one small declarative thing** (a unit file: name, whether DHT, limits, who may join, optionally a shared secret).
5. **Time limits and partial answers** (ask a few peers, wait at most a few seconds, merge what comes back) are the right model for a search that must stay responsive.

## Decisions this suggests

- **Start with federated queries between paired, trusted nodes; no index exchange.** Each node keeps its own index and data. This keeps private collections private by construction, needs no global document identity for correctness, and meets "a node stays useful alone".
- **Peers are configured, not discovered.** `[[peer]]` entries (name, base URL, key) in the configuration, editable in the admin panel. Discovery (a list of peers a peer knows) can come later and only as suggestions an operator accepts.
- **Authentication is the existing planned API keys with collection scopes**, one key per peer, so a peer can see exactly the collections shared with it and nothing else. Signed peer identity (public keys) can replace shared keys later without changing the rest.
- **Remote results are untrusted data.** Snippets are escaped like local ones, never rendered as HTML; sizes, counts and fields are bounded; a peer that misbehaves is skipped for a while.

## Steps

**0. Prerequisites (build first, valuable alone).**
- Collections and API keys with collection scopes (on the roadmap): the sharing boundary.
- A stable, node-independent document identity next to the current one: a hash of the canonical address (or of the content for files), stored as another column. Used only for deduplicating merged results.
- One internal query representation used by the page, the API and the peer protocol (the query language already parses into one; the JSON form needs a version number).

**1. Peer protocol over the existing API.** A peer answers `GET /api/v1/search` and `/api/v1/retrieve` with a key, restricted to the shared collections. Nothing new on the wire to design; `peer` information (node name) is added to every result. Health: `GET /api/v1/health` plus the peer's source and document counts for display.

**2. Federated search.** `scope=all` (or a checkbox group "Peers" next to Sources) fans the query out in parallel with a per-peer time limit (default 1500 ms) and a result cap, then merges with the local results by reciprocal-rank fusion (scores are not comparable across indexes: different sizes, different idf), dropping duplicates by document identity, always labelling the node a result came from, and saying which peers were slow, down or refused. Local results are never delayed by peers: they are shown or returned with whatever peers have answered by the deadline. The page keeps working without JavaScript (the merge happens on the server).

**3. Federated retrieval.** The same for `/api/v1/retrieve`: each node returns its best passages with attribution; the asking node re-ranks the union (or trusts the order by fusion) and cites `node` and `view_url` on the owning node. Images and originals are fetched from the owning node, through the asking node's proxy only if the operator turns that on.

**4. Peer management.** Admin pages: add a peer (address, key, pairing test), status (last seen, latency, errors), per-peer toggles (search, retrieve), shared collections per key. A pairing survives restarts because it is configuration.

**5. Optional later, each its own decision:** suggestions of peers from peers; selective prefetch of a peer's results for offline use; replicating a peer's *documents* (not references) for a collection the owner marks shareable, as a normal connector (a `peer` source that imports from another node's API), so a replica is simply another source with its own rights flags; a public network, which needs signed identity and reputation first.

## What not to do

- No DHT or distributed term index for private networks: it solves a problem (finding who holds a word among thousands of peers) that two to twenty trusted nodes do not have, and brings poisoning with it.
- No discovery by broadcast; no peer that is not configured by an operator.
- No sharing of anything that is not in an explicitly shared collection.

## Tests (from the plan's list)

Standalone node unaffected by the feature being off; two peers on a LAN; a peer slow (deadline), down (partial results labelled), removed; a private and a shared collection (the private one never leaves); the same document on both peers (one result, both nodes named); a malformed or oversized answer (rejected, peer penalised); a peer returning HTML in a snippet (escaped); a key with the wrong scope (403, nothing leaks); reconnect after a restart (pairing kept).

## Open questions

- Fusion versus score normalisation: reciprocal-rank fusion is robust and simple, but ignores how much better the first result is than the second; decide with the test corpus.
- Should the asking node cache remote results for a short time (latency against freshness)?
- Where does the shared key live (the existing secrets file) and how is it rotated?
