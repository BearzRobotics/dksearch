# 0040: Signed node identity

Status: implemented (identity, signed requests, key binding, pinned peers). A public network is not part of this.

## Context

Peers (ADR 0034) were recognised by a shared API key: whoever had the key was the peer, and whoever answered at the address was the other node. The step towards anything larger than a handful of hand-configured nodes needs identity that is not a shared secret, and that must not depend on discovery, reputation or a public directory, which are separate and harder decisions.

## Decision

- **A key pair per node**, Ed25519, made explicitly (`dksearch node-key`) and kept in `data_dir/node-identity.toml` (mode 0600, refused if others can read it). The node id is the public key as `dkn_` and 43 base64url characters. Nothing is generated behind the operator's back.
- **Signed requests**: `dk-node`, `dk-time`, `dk-nonce`, `dk-sig`. The signed text starts with a version and domain label (`dksearch-v1 request`) and covers method, request target, the host addressed, the time and a nonce. A receiver checks the signature, a five-minute time window and that the nonce has not been seen (a bounded in-memory table), so a signed request cannot be replayed to another node, path, method or host, or twice.
- **Key binding**: an API key may carry `node = "dkn_..."`. It then needs a valid signature by that node on the very request. A leaked key alone is useless; the shared secret becomes a capability that only the named node can use. Keys without a binding work as before.
- **Pinned peers**: a `[[peer]]` (or a `peer` source) may carry `node = "dkn_..."`. The request carries a nonce; the answer must carry `dk-node` and `dk-sig` over the nonce, the status and a hash of the body, by that node. Otherwise the answer is not used (`untrusted`; a replica run fails). An impostor or a man in the middle at the same address cannot feed results. A node with an identity signs the answers to any caller that sends a nonce.
- **Trust stays manual**: peers, keys, bindings and pins are configured by the operators. The identity makes the configuration safer; it does not find or vouch for anyone.

## Alternatives

- Mutual TLS with client certificates: strong, but certificate authorities, expiry and reverse-proxy interplay are heavy for a few nodes, and it ties identity to the transport; signed headers work through any proxy that keeps Host.
- JWT or signed tokens: bearer tokens again, with the same leak problem.
- Generating the identity automatically at first start: surprising; the operator should decide when the node gets a public identity.
- A public directory, discovery or reputation: not before this has been used; poisoning and abuse need their own design.

## Consequences

- Clocks must agree within five minutes between nodes that use bound keys.
- The `Host` header the receiver sees must be the one the sender used: a proxy that rewrites Host breaks bound keys (and is documented).
- The replay table is memory only: after a restart a request signed in the last five minutes can be replayed once, within its window.
- Losing the identity file means a new node id: peers must be told, and keys bound to the old one re-issued.
