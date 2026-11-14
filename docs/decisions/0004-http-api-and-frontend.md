# 0004. HTTP server, API format and public frontend

- Status: Accepted (2026-11-14, by the maintainer), as proposed
- Date: 2026-11-14

## Context

Milestone 2 needs a basic search API and a minimal public search page. SPEC section 16 leaves open: item 4 (frontend technology and asset delivery) and item 5 (API protocol, versioning, authentication). AGENTS.md requires that the HTTP layer be an adapter over application services, that the public and administration interfaces be separate, that the API be first-class, that dependencies be few and vendored, and that network ingestion and listeners have timeouts, size and concurrency limits and safe defaults.

The core already provides `Searcher.search(arena, Query) -> Page`, so the HTTP layer needs to do only: parse the request, call the searcher, render the result.

## 1. HTTP server

### A. `std.http.Server` with our own accept loop (proposed)

- No new dependency; ships with Zig 0.17.1.
- The standard library server only parses and writes HTTP messages. It does not manage threads, connection limits, idle timeouts or keep-alive policy; the caller does. We would write those ourselves: a bounded worker pool, per-connection read/idle timeouts, header and body size limits, and a connection cap. The project needs those controls anyway (AGENTS.md section 7).
- Community sources describe the std server as aimed at supporting the HTTP client rather than at production throughput. That is acceptable for a self-hosted search engine whose cost is dominated by queries, and the HTTP layer is a thin adapter that can be replaced.

### B. A third-party Zig HTTP library (http.zig, dusty, zio, ...)

- More features (routing, pooling, timeouts) and likely better throughput.
- A new vendored dependency to audit. A web search could not confirm that http.zig supports Zig 0.17.1 (sources mention 0.16 at most), so compatibility would have to be tested first.

### C. External reverse proxy as the only HTTP/TLS layer

- Not a replacement: the engine still needs an HTTP listener. TLS termination and rate limiting by a reverse proxy remain a supported deployment, documented rather than built in.

## 2. API protocol and versioning

JSON over HTTP, versioned by URL prefix `/api/v1/`. Resource-style GET endpoints, no query language of its own beyond what `Query` already defines.

Initial endpoints (public, read-only, unauthenticated):

- `GET /api/v1/search?q=...&language=&content_type=&connector=&limit=&offset=` returns `{ "hits": [{ "id", "connector", "url", "title", "snippet", "score" }], "has_more": bool }`. Parameter limits are those in `search.zig`.
- `GET /api/v1/health` returns `{ "status": "ok" }`; it exposes nothing else.

Rules:

- Errors: HTTP status plus `{ "error": { "code": "empty_query", "message": "..." } }`. `EmptyQuery` and `InvalidQuery` map to 400; engine failures to 500 with a generic message (details go to logs, not responses). Unknown routes 404, wrong method 405.
- Compatibility: within `v1`, adding response fields or optional parameters is allowed; removing or changing meaning requires `v2`. Clients must ignore unknown fields. A superseded version stays available for a documented period.
- Snippets are returned with the control-character match markers from `search.zig`; the API documents them, and the HTML frontend escapes before substituting markup.
- Ids are hex strings of the 16-byte document id.
- Documented in a manpage and in `docs/` as the API is built, following `docs/manpages/template.md`.

Alternatives considered: GraphQL or JSON-RPC (more machinery than a handful of read endpoints need); an Elasticsearch- or OpenSearch-compatible API (would commit the project to another system's semantics).

## 3. Authentication

- The public search API needs none; it is read-only and the listener defaults to loopback until the administrator opts in to exposing it.
- Administration lives on the separate admin listener (already loopback by default in `config.zig`) and is built in Milestone 4. Its authentication model (proposed: bearer token whose hash is kept in a permission-restricted secrets file, never in the main TOML) will get its own decision record. Nothing administrative is added to the public listener.
- Abuse control for a public deployment (rate limiting) is a documented reverse-proxy concern at first; the server enforces only hard resource limits.

## 4. Public frontend

Server-rendered HTML from the same process, with no JavaScript required: a search box, a results page with title, URL, snippet, source, simple filters, and Previous/Next pagination, plus one small embedded stylesheet. It calls the application service directly, not its own HTTP API, so the HTML layer and the JSON API are two adapters over the same `Searcher`.

- Assets are compiled in with `@embedFile`: no separate asset directory to deploy, nothing to fetch at runtime, works offline.
- Responses carry a restrictive `Content-Security-Policy` (no inline script, no external resources) and `X-Content-Type-Options: nosniff`. All dynamic text is HTML-escaped; result URLs are only linked if their scheme is `http` or `https`.
- The admin interface is a separate listener and separate module; the public page links to nothing administrative.

Alternative considered: Zine (https://zine-ssg.io/), a Zig static site generator. Results depend on the query and cannot be pre-built, so Zine could only serve the static pages, and the results page would then need client-side JavaScript. It is also described as alpha, and Zig 0.17.1 support is unconfirmed. Rejected by the maintainer; static pages are written by hand and embedded. Revisit only if static content (e.g. a documentation site) grows substantially.

Alternative considered: a JavaScript single-page app consuming the API. It adds a toolchain and an asset pipeline, is worse offline and for accessibility, and the SPEC asks for a deliberately simple page.

## 5. Module layout

`src/http/` (a separate module importing `dksearch`; the core never imports it) holds the server loop and limits, the JSON API handlers and the HTML handlers as separate files, with the server wiring in a new `dksearch` executable. The executable's commands (at least `serve` and a configuration check) will need a manpage under `docs/manpages/` before they are considered done.

New configuration (validated like the rest, unknown keys rejected): per-listener limits for header bytes, request timeout, idle timeout, maximum connections and worker count, each with a documented safe default.

## Consequences if accepted

- No new third-party dependency for Milestone 2.
- We own connection handling, so timeouts, limits and slow-client behaviour must be tested explicitly (slowloris-style stalls, oversized headers, many connections, malformed requests).
- Swapping in a different HTTP library later touches only `src/http/`.
- The JSON API and HTML page can not drift apart in behaviour because both call the same service.
