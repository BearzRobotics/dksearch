# 0039: Replicating a peer's documents

Status: implemented.

## Context

Federated search (ADR 0034) asks peers at query time and copies nothing, which keeps private collections private by construction. It also means a peer that is away cannot be searched. The P2P plan listed, as an explicit later decision, copying a peer's *documents* for a collection the owner marks shareable, as a normal connector.

## Decision

- **Opt-in per source.** A source is exported only when its owner sets `share = true`. Nothing is shared by default, `share` is refused with `rights = "forbidden"`, and the administration interface has a checkbox next to the rights field.
- **Keyed and scoped.** `GET /api/v1/export` always needs an API key, even on a server that answers anonymous searches, and the key's collections must include the source (ADR 0033). A source that is not shared, is off, is forbidden or out of scope answers 404 with the same text as one that does not exist.
- **Full text moves, so the rest is conservative:** pages are bounded (200 documents, 16 MiB), a document over 4 MiB or with no retained text is not sent, and the owner's rights flag travels with each document.
- **The copy is a normal source** (`kind = "peer"`): own name, rights, schedule, boost, collections. It pulls pages with a cursor (resumable), keeps each document's stated redistribution flag, and records where it came from. The pipeline's content hashes make repeated runs cheap.
- **Same identity.** A document's `ident` (ADR 0034) is the same on the copy, so a federated search that asks the owner as well shows it once.
- **Untrusted input.** Ids must be 32 hex digits, text valid UTF-8 without NUL, sizes bounded, non-http links dropped; a peer that stops advancing its cursor cannot loop the run.

## Alternatives

- Sharing whole collections at once: collections are a view over sources; the unit of rights here is the source.
- Pushing documents to a peer: needs write access on the other side; pulling with a read key is the smaller trust.
- Removing documents the owner removed: needs a deletion feed or a full listing; the copy keeps what it has until a rebuild. A later step.

## Consequences

- The owner can see who pulled by key name only; revoking the key stops further copies, not the copies already made.
- Disk use on the replica is the shared text.
