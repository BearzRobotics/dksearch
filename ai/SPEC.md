# Search Engine — Product and Technical Specification

- Status: Initial specification
- Scope: Product direction and architectural requirements
- Implementation details not settled by this document must remain open until evaluated and recorded.

## 1. Product vision

Build a modern, usable, self-hosted search engine inspired by the independent and distributed approach of YaCy, but with a clean user experience and a more flexible content-acquisition architecture.

The engine maintains its own searchable index. It must not depend on Google, Bing, Brave Search, or another external search provider to produce ordinary search results.

The system should be useful on one machine, work without an internet connection after software and data have been provisioned, and leave room for optional federation or distributed operation later.

The product is a general-purpose information-retrieval system. Public web search is its primary application, but the same engine should be capable of indexing other collections such as books, software documentation, package metadata, manpages, and private/local documents.

## 2. Product principles

The following are accepted project requirements:

1. No mandatory external search provider.
2. Fully self-hostable, including offline operation.
3. Multiple independent ingestion methods.
4. Rebuildable search indexes.
5. TOML-based configuration.
6. No mandatory Docker dependency.
7. Modular source connectors.
8. Clean public interface, separate from administration.
9. API-first architecture.
10. Distributed operation is optional, not required.

These are architectural constraints, not a mandate to implement every optional capability in the first release.

## 3. User-facing interfaces

### 3.1 Public search interface

The public interface should be deliberately simple and fast.

The initial experience should provide:
- A search field and clear submission action.
- A results page with title, URL/domain, snippet, and relevant source metadata.
- Pagination or another predictable way to navigate result sets.
- Useful filters without overwhelming the default experience.
- Responsive behavior on desktop and mobile.

The public interface must not become a news feed, advertising surface, administration dashboard, or general-purpose portal.

Potential result filters include:
- Domain or website.
- Content type.
- Language.
- Date range.
- Ingestion source.

The exact visual design and frontend technology remain implementation decisions.

### 3.2 Administration interface

The administration interface must be separate from the public search interface. It should make system operation understandable without requiring direct database manipulation.

Planned areas:

- **Overview:** service health, document counts, index size, active and failed jobs.
- **Sources:** configure, enable, disable, inspect, and test connectors.
- **Seed bank:** manage seed URLs, curated collections, and discovery policies.
- **Ingestion:** inspect imports, schedules, queues, progress, and failures.
- **Crawling:** configure crawl limits, allowed domains, robots policy, and scheduling.
- **Indexing:** inspect index status, rebuild indexes, and manage retention.
- **Search quality:** test queries and inspect ranking explanations/signals.
- **Storage:** inspect document storage and index usage.
- **Network:** inspect optional peers or federated nodes when that feature exists.
- **Configuration:** validate and manage TOML configuration.
- **Logs and diagnostics:** inspect operational events and errors.

The initial administration interface should prioritize safe configuration, source management, job visibility, and index maintenance. Advanced distributed controls can wait.

Administrative actions must be authenticated and authorized before the interface is exposed beyond a trusted local environment.

### 3.3 API

The API is a first-class interface, not an afterthought.

It should eventually support:
- Search queries and pagination.
- Search filters and sorting.
- Document/source inspection subject to access policy.
- Source and ingestion-job administration.
- Index status and health.
- Configuration validation and controlled reloads.

The API must have documented request/response formats, versioning policy, error behavior, and authentication requirements. The exact protocol and endpoint names remain open.

## 4. Data acquisition

Crawling is one connector type, not the sole or mandatory ingestion path.

The architecture must support multiple independent acquisition methods feeding a shared ingestion pipeline.

### 4.1 Initial data sources

The initial source strategy should investigate:

| Source | Initial role | Notes |
|---|---|---|
| Wikipedia | Structured encyclopedia content | Prefer official dumps and structured exports over crawling article pages. Preserve page identity, language, revision information, and applicable license/attribution. |
| Internet Archive | Catalog metadata and selected archived content | Begin with metadata/catalog ingestion. Full-text and archived-web ingestion should be selective and respect item-level rights and access restrictions. |
| Common Crawl | Broad web corpus | Evaluate URL indexes and WARC/WAT/WET data. Start with selective retrieval or a manageable WET sample before attempting large-scale bulk processing. |
| Project Gutenberg | Books and literary works | Use its catalogs and available downloads. Preserve item metadata and applicable rights, trademark, and distribution conditions. |

These sources are initial priorities, not exclusive dependencies. No one source should be required for the search engine to start or operate.

The project must not assume that all content in a public archive is public domain or freely redistributable. Store source, license, attribution, and access information where available. Make content-retention and redistribution policy explicit.

### 4.2 Additional ingestion methods

The connector architecture should allow future support for:
- RSS and Atom feeds.
- XML sitemaps.
- User-submitted URLs and seed collections.
- Direct website crawling.
- Public dataset imports.
- Local files and directories.
- Package and software-documentation repositories.
- Other archives and APIs.
- Optional peer-to-peer or federated contributions.

### 4.3 Seed bank

The seed bank is a discovery and source-management subsystem. It is not the search index.

It stores curated starting points and their policies, such as:
- URL or domain.
- Name and description.
- Category or collection.
- Connector type.
- Enabled state.
- Discovery behavior.
- Crawl depth and domain restrictions where applicable.
- Priority and scheduling hints.

Seed collections should be exportable and shareable. Importing a seed collection must not automatically grant it permission to bypass robots policies, access restrictions, or administrator-defined network limits.

## 5. Shared ingestion pipeline

All connectors must feed a common ingestion pipeline.

Conceptual flow:

1. Acquire source material.
2. Parse source-specific format.
3. Normalize document metadata and content.
4. Validate and apply source policy.
5. Compute stable identifiers and content hashes.
6. Detect duplicates or revisions.
7. Store retained source content and metadata as configured.
8. Send searchable fields to the indexer.
9. Record import outcome and provenance.

Connectors must not depend on private internals of the search index.

A connector should expose enough metadata to support scheduling, progress reporting, error reporting, cancellation, and resumable imports where practical.

## 6. Document model and provenance

The system needs a shared document representation that can accommodate web pages, books, archive records, documentation pages, and other text-bearing resources.

At minimum, evaluate fields for:

- Stable internal document identifier.
- Source connector and source-specific identifier.
- Canonical/original URL where applicable.
- Title.
- Main text or a reference to stored content.
- Description or summary when available.
- Language.
- Content type.
- Author or creator when available.
- Original publication and modification dates when available.
- Acquisition and indexing timestamps.
- Content hash.
- Source dataset and dataset version.
- License, rights, and attribution metadata when available.
- Revision/version identifier where applicable.
- Links or references to related documents.

Do not assume every field exists for every source. Preserve source-specific metadata without forcing every connector into an inaccurate common schema.

Keep original content storage separate from the derived search index. The index must be rebuildable from retained content and metadata to the extent permitted by source access and retention conditions.

## 7. Indexing and search

The system requires full-text indexing and retrieval independent of external search providers.

The first implementation should prioritize:
- Tokenization and normalization.
- Language-aware handling, with a clear initial language scope.
- Inverted-index-based retrieval or an evaluated equivalent.
- Phrase and multi-term queries.
- Basic field weighting, including title and body.
- Snippet generation.
- Filtering by source, domain, language, and content type where data exists.
- Pagination with predictable ordering.
- Index update and deletion behavior.
- Rebuild and integrity-check operations.

BM25 is a candidate baseline ranking algorithm. Ranking should be modular so that field boosts, freshness, link-derived signals, source-specific signals, and later ranking methods can be evaluated independently.

Ranking must be explainable enough for an administrator to inspect why a result received its score. Do not make machine-learning or LLM ranking a mandatory dependency.

The initial index backend is intentionally undecided. Evaluate options against Zig integration, operational simplicity, index size, query performance, incremental updates, rebuildability, and offline installation. Record the decision in `docs/decisions/`.

## 8. Crawling

The crawler is an optional ingestion connector.

It should support:
- Seed URL and domain configuration.
- URL normalization and duplicate suppression.
- Link extraction and discovery.
- Sitemap support.
- Per-host concurrency and request pacing.
- Configurable depth and page limits.
- Request timeouts and response-size limits.
- Content-type filtering.
- Robots.txt policy.
- Redirect limits and destination validation.
- Retry/backoff and failure reporting.
- Resumable queues where practical.

Crawling must not monopolize resources or prevent dataset imports and other connectors from operating.

## 9. Configuration and operational state

TOML is the human-editable configuration format.

The project will use the `toml-zig` library from the maintainer's GitHub repository. The exact repository URL, revision/pinning strategy, and API integration must be confirmed against the actual repository before implementation. Do not invent its API.

Configuration should cover, as appropriate:
- Server listeners and ports.
- Storage locations.
- Index behavior.
- Ranking defaults.
- Connector definitions and schedules.
- Crawler limits and policies.
- Authentication and administration settings.
- Optional network/federation settings.

Separate static configuration from operational state. Operational state such as queues, job history, document records, and index metadata belongs in suitable runtime storage rather than being rewritten into TOML.

Configuration must be validated before application. Support a documented and safe reload strategy; failed reloads must not leave partially applied settings.

The service must not require Docker. Provide a conventional installation and service-management path appropriate to supported operating systems. Exact packaging and service-manager targets remain open.

## 10. Storage and rebuildability

Distinguish at least:
- Original or normalized retained content.
- Document metadata and provenance.
- Search index files.
- Operational state and job queues.
- Configuration and secrets.

The search index should be treated as derived data and be rebuildable. Rebuilding must not require reacquiring every source if retained content is available.

Define backup and restore behavior for configuration, operational state, retained content, and indexes. An installation should be able to rebuild an index after loss or format change, subject to the retained source material.

## 11. Security, privacy, and responsible ingestion

- Treat remote documents, feeds, archives, and metadata as untrusted input.
- Validate URLs and redirects to mitigate SSRF.
- Apply timeouts, resource limits, and concurrency controls.
- Do not execute imported content.
- Protect administrative endpoints and sensitive operations.
- Do not expose secrets in logs or API responses.
- Avoid mandatory telemetry or external analytics.
- Respect robots.txt and source-specific terms for crawling.
- Track licensing, attribution, and access restrictions.
- Provide administrators with controls over retention and deletion.
- Make network listeners and authentication defaults safe.

## 12. Offline and single-node operation

Offline operation is a core requirement, not a special mode.

Once software and selected datasets have been obtained, an installation must be able to:
- Start without contacting an external search provider.
- Search its existing index.
- Rebuild the index from retained local content.
- Import local datasets and files.
- Operate the public frontend, admin interface, and API locally.

Connectors that require the internet should report that limitation clearly and must not prevent the rest of the system from operating.

A single-node installation must not require peers, a coordinator, or a distributed control plane.

## 13. Optional distributed operation

Distributed crawling, index sharing, and federation are future optional capabilities.

They must not be prerequisites for:
- Installation.
- Indexing.
- Searching.
- Administration.
- Offline operation.

Before implementing distributed features, define trust, identity, content provenance, deduplication, abuse resistance, synchronization, and conflict behavior. Do not assume that a peer's content or metadata is trustworthy.

## 14. Documentation requirements

- Agent guidance belongs in `ai/AGENTS.md`.
- This specification belongs in `ai/SPEC.md`.
- Significant architectural decisions belong in `docs/decisions/` as decision records explaining the reason for a choice and its consequences.
- Manpages belong in `docs/manpages/`.
- Every manpage must follow `docs/manpages/template.md`. Read that template before authoring a manpage.
- Document installation, configuration, commands, services, API behavior, source connectors, backup, restore, and troubleshooting as those features are implemented.

Decision records should explain why a decision was made; they should not duplicate this specification.

## 15. Initial development milestones

The milestones below establish a sensible order, not a rigid release schedule.

### Milestone 1 — Foundations
- Repository and build structure.
- Core types and error conventions.
- TOML configuration loading and validation using the selected `toml-zig`.
- Shared document model.
- Connector interface.
- Storage boundary definitions.

### Milestone 2 — First usable local search
- Choose and integrate an index backend.
- Implement indexing and querying.
- Add a small deterministic fixture corpus.
- Implement a basic search API.
- Implement the minimal public search frontend.

### Milestone 3 — First dataset connectors
- Project Gutenberg catalog/content importer.
- Wikipedia dump importer.
- Import job tracking and resumability.
- Provenance and licensing metadata.

### Milestone 4 — Administration
- Authentication and safe admin listener defaults.
- Source management.
- Import job visibility and controls.
- Index status and rebuild controls.
- Configuration validation and application.

### Milestone 5 — Broader corpus
- Internet Archive metadata connector.
- Common Crawl selective ingestion.
- Evaluate larger Common Crawl ingestion only after measuring resource requirements.

### Milestone 6 — Ongoing discovery
- RSS/Atom.
- Sitemaps.
- Seed bank management.
- Optional web crawler.

### Milestone 7 — Search quality and operations
- Ranking evaluation and query diagnostics.
- Language and content-type improvements.
- Backup, restore, retention, and operational documentation.

### Later
- Optional federation and distributed operation.
- Additional connectors and specialized indexes.

## 16. Open design decisions

Do not silently settle these in implementation. Evaluate options and record decisions where they materially affect architecture:

1. Search-index backend and its Zig integration strategy.
2. Metadata/operational database.
3. Original-content storage format and retention model.
4. Frontend technology and asset delivery.
5. API protocol, versioning, and authentication model.
6. Initial supported languages and tokenization strategy.
7. Installation targets and service integration.
8. Connector packaging and plugin boundary: compile-time modules, runtime plugins, or built-in connectors.
9. Index partitioning and multi-collection behavior.
10. Future federation trust and synchronization model.

The first implementation should favor a small, working, single-node system over premature distributed architecture.
