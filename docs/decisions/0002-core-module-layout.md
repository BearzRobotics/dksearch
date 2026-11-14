# 0002. Core library layout and boundaries

- Status: Accepted
- Date: 2026-11-14

## Context

AGENTS.md sections 3 and 6 require the search core to be independent of HTTP, the web UI and individual connectors, and require connectors to produce normalized records rather than write into index internals. SPEC section 16 leaves the index backend, metadata database and content storage format open.

## Decision

A single Zig module, `dksearch` (`src/root.zig`), holds the transport-independent core. Its files each own one concern:

- `config.zig`: TOML loading and validation.
- `document.zig`: the shared document model and provenance fields.
- `connector.zig`: the connector interface and the `Sink` through which connectors emit documents.
- `storage.zig`: interfaces for retained content and document metadata.

Rules:

- Interfaces are runtime vtables (pointer plus function table), so implementations can be swapped without the core knowing them.
- A connector sees only a `Sink` and a `Control`. It never receives a store or an indexer.
- Neither `storage.zig` nor any other core file names a concrete database or index backend. Those choices stay open and each gets its own decision record.
- The HTTP layer, admin interface and CLI will be separate modules that import `dksearch`; the core never imports them.

## Alternatives

- Compile-time generic interfaces (duck typing): no indirection cost, but concrete types leak into every caller and runtime selection from configuration becomes awkward.
- Several packages from the start: premature for Milestone 1.

## Consequences

- Connectors and stores can be tested against small in-memory fakes.
- Vtable calls add one indirection per document, which is negligible next to I/O and indexing.
- Splitting into several modules later is straightforward because the file boundaries already follow the dependency rules.
