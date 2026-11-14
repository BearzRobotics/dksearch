# Agent Instructions

These instructions apply to all work in this repository.

## 1. Project purpose

Build a modern, independently operated, self-hostable search engine. The system should be useful without relying on an external search provider and should support multiple independent ways of acquiring searchable content.

The public search experience must remain clean and simple. Administration must be a separate interface. The system must expose an API as a first-class interface.

## 2. Read before making changes

Before implementing a task:

1. Read `ai/SPEC.md` and the relevant sections of this file.
2. Inspect the existing implementation and tests before proposing structural changes.
3. Read relevant architecture decision records in `docs/decisions/`.
4. For command-line interfaces, service behavior, configuration formats, or other topics covered by project manpages, read `docs/manpages/template.md` and follow it.

If the specification and implementation disagree, do not silently choose one. Explain the discrepancy and propose whether the specification or implementation should change.

## 3. Engineering principles

- Prefer small, understandable components with explicit responsibilities.
- Keep the search core independent of HTTP, the web UI, and individual data-source connectors.
- Treat ingestion, indexing, querying, ranking, storage, and presentation as separable concerns.
- Do not make crawling the only or primary required ingestion mechanism.
- Do not require an external search provider for normal operation.
- Do not require Docker or another container runtime.
- Keep distributed operation optional. A single-node installation must be fully useful.
- Support offline operation after required software and datasets have been obtained.
- Make indexes rebuildable from retained source content and metadata wherever practical.
- Preserve source provenance, stable source identifiers, timestamps, and applicable licensing/attribution metadata.
- Prefer explicit configuration and predictable behavior over hidden magic.
- Avoid unnecessary dependencies. Prefer well-maintained libraries and document why a dependency is needed.
- Do not introduce a dependency on DKDE, DKBuilder, or another unrelated project.

## 4. Zig and dependencies

- Implement the core system in Zig unless a documented technical reason justifies another language for a specific component.
- Use the project's selected `toml-zig` library for TOML parsing and serialization where appropriate. (https://github.com/BearzRobotics/toml-zig)
- Verify the actual `toml-zig` API from the checked-out source and its tests. Do not invent API calls or assume compatibility with another TOML library.
- Keep third-party dependencies explicit and reproducible. Prefer vendoring dependencies when appropriate for reliable offline builds.
- Do not write a custom parser for an established format when a suitable maintained library is available, unless the project has a documented reason to do so.
- Do not commit generated indexes, downloaded corpora, secrets, or machine-specific state unless explicitly required.

## 5. Configuration

- TOML is the human-editable configuration format.
- Keep configuration separate from operational state and indexed content.
- Validate configuration before applying it.
- Report configuration errors with the file, key or table, and useful context.
- Avoid silently accepting unknown or misspelled configuration keys when doing so could cause an administrator's intended setting to be ignored.
- Define safe behavior for configuration reloads. A failed reload must not leave the service in a partially applied state.
- Document defaults and supported values.

## 6. Architecture and interfaces

- Keep the public search frontend separate from the administration frontend.
- Treat the HTTP/API layer as an adapter over application services, not as the owner of search or indexing logic.
- Define stable internal interfaces for source connectors and document ingestion.
- Connectors must not write directly into search-index internals. They produce normalized records for the shared ingestion pipeline.
- Keep source-specific metadata where useful, while also mapping common fields into the shared document model.
- Make optional capabilities, especially federation and distributed indexing, removable without breaking single-node operation.

## 7. Data integrity and security

- Treat imported documents, feed entries, metadata, and remote responses as untrusted input.
- Apply request timeouts, size limits, concurrency limits, and redirect policies to network ingestion.
- Respect robots.txt and applicable source terms for crawling. Do not assume that public availability grants redistribution rights.
- Preserve licensing, attribution, and source information when provided.
- Do not execute downloaded content.
- Protect administrative operations with authentication and authorization before exposing the administration interface beyond loopback or a trusted network.
- Do not expose secrets in logs, API responses, diagnostics, or example configuration.
- Use safe defaults for network listeners and filesystem permissions.
- Avoid SSRF vulnerabilities in URL-fetching and connector features; validate destinations and re-check redirects.

## 8. Testing and quality

- Add tests for new behavior and regression tests for bug fixes.
- Test malformed configuration, missing fields, invalid URLs, duplicate documents, interrupted imports, and index rebuilds where relevant.
- Keep tests deterministic; do not make the normal test suite depend on live internet access.
- Provide small fixtures for parsers and connectors instead of downloading large datasets during tests.
- Test offline operation as a first-class scenario.
- Run formatting, tests, and relevant static checks before declaring work complete.
- State what was tested and what was not tested.

## 9. Documentation

- Keep `ai/SPEC.md` aligned with the intended product and architecture.
- Record significant architectural choices in `docs/decisions/` as decision records explaining context, decision, alternatives, and consequences. Do not use decision records as a second specification.
- Put manpages under `docs/manpages/`.
- **Before creating or editing any manpage, read `docs/manpages/template.md` and use that template.** Do not invent a competing manpage structure.
- Document user-visible configuration keys, commands, services, API behavior, and operational procedures.
- Prefer concise explanations and practical examples.

## 10. Scope discipline

- Do not add features merely because they are common in other search engines.
- Do not turn the public search homepage into an administration dashboard or content portal.
- Do not make AI/LLM services, cloud services, telemetry, or external search APIs mandatory.
- Do not make federation, distributed crawling, or distributed indexing prerequisites.
- When a task would materially change the architecture or product commitments in `ai/SPEC.md`, update the specification and add or update a decision record as appropriate.
- If requirements are ambiguous, identify the smallest consequential uncertainty and ask before making an irreversible design choice.
