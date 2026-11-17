# 0033: Collections and API keys

Status: implemented (command line, configuration and enforcement); administration pages are a follow-up.

## Context

Sources were a flat list with an incidental filter. The roadmap asked for saved source groups, a way to give a program or a peer access to only some of the data, and a boundary for sharing between nodes (`docs/research/p2p-plan.md`). The public API had no authentication at all.

## Decision

- **Collections** are named groups of sources in the configuration (`[[collection]]`: name, optional description, member sources). They are one idea serving three purposes: a saved source group on the search page, a `collection:` filter in the query language, and the unit of access control. A collection may not be named like a source.
- **A scope** is the set of sources a request may see. It is set by the server for each request, from the API key presented or from the anonymous setting, and never from the request itself. It is applied inside the index query (`d.connector IN (...)` on every search, including the chunk index and searches by conditions alone) and checked again where a document is addressed by id (viewer, original file, pictures, ZIM articles), which answer 404 for what is outside it, so existence is not revealed.
- **Anonymous access:** `[access] anonymous_collections` names what visitors may see; absent means everything (unchanged behaviour); an empty list means nothing, so the API needs a key.
- **API keys:** random 32-byte tokens with the prefix `dkk_`, stored only as SHA-256 hashes (with a name, the collections and the creation time) in `data_dir/api-keys.toml`, mode 0600, written through a temporary file and a rename. A file others can read is refused and then no key works (fail closed). A key lists collections or `*`. Presented as `Authorization: Bearer`, compared in constant time. A key that is not valid gets 401, never the anonymous scope. The file is looked at again when its size or time changes (at most once a second), so keys can be made and removed while serving.
- **Management:** `dksearch api-key add|list|remove`. The key is printed once.

## Alternatives

- Per-document or per-field permissions: much more machinery than the need; a source is already the unit of rights and acquisition here.
- Keys inside the configuration file: the file is meant to be readable, versioned and shared; hashes of secrets belong with the other secrets.
- Signed tokens (JWT): no state to look up, but no revocation without a deny list and a library to trust; hashes in a file are enough for this scale.
- Treating an invalid key as anonymous: simpler, but hides a mistake and lets a revoked key keep working for public data without notice.

## Consequences

- Anything that returns document content must take the scope into account; new endpoints must do so (a test per endpoint is in `handler.zig`).
- The same scope will bound what a paired node may ask of another (P2P plan, step 1).
- Rate limits: a key may carry a per-minute limit (fixed windows, counted in memory, so a restart resets them); over it, 429 with `Retry-After`. Collections are edited on the Access page (validated edit of the configuration file, applied after a restart).
