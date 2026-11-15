# dksearch

A self-hostable search engine written in Zig. It keeps its own full-text index, serves a small public search page and JSON API, and can import documents from local files, Project Gutenberg and Wikipedia dumps. It works offline: after you have downloaded a dataset, nothing needs the network.

Status: version 0.0.0, pre-release. It works end to end and is tested, but it has not been run at large scale, and its interfaces may still change. See `docs/manpages/dksearch.1.md` for what is and is not implemented.

## Build

Needs Zig 0.17.1 and nothing else. All dependencies are vendored (SQLite, a TOML parser, and for the Wikipedia connector bzip2 and Expat).

    zig build -Doptimize=ReleaseSafe     # binary: zig-out/bin/dksearch
    zig build test                       # all tests; they run offline
    zig build -Dwikipedia=false          # leave out the Wikipedia connector and its C libraries

## Try it

Index a directory of text and Markdown files and search it:

    cat > dksearch.toml <<'TOML'
    [[source]]
    name = "notes"
    kind = "files"
    path = "/home/me/notes"
    TOML

    dksearch import --config dksearch.toml notes
    dksearch serve --config dksearch.toml
    # then open http://127.0.0.1:8080/ or:
    curl 'http://127.0.0.1:8080/api/v1/search?q=lighthouse'

Sources are optional. With none configured, `serve` still works and serves whatever index exists, and documents can arrive through any connector that uses the same interface.

## What is in it

- **Search**: SQLite FTS5 with title and body weighting, phrase and multi-term queries, snippets, filters and stable paging. User text is never interpreted as query syntax.
- **Public interface**: a server-rendered HTML page (no JavaScript) and a versioned JSON API, both read-only.
- **Connectors** (all optional): local `.txt`/`.md` files; Project Gutenberg (catalog CSV plus book files you downloaded); Wikipedia (a `pages-articles` dump, bzip2 or plain XML). Imports resume where they stopped and skip unchanged documents.
- **Operations**: `rebuild` the index from retained content, `check` the stored data (including every text's hash), `backup` it safely while running, `remove` a source, `import --prune` documents that left a source.
- **Administration**: a separate, read-only listener with a dashboard and API (sources, import jobs, counters), behind a bearer token or a password. Credentials are kept only as hashes.
- **Privacy**: no telemetry, no request log by default; the optional access log never records queries or client details.

## Documentation

- `docs/manpages/dksearch.1.md` is the full reference: commands, configuration, files, security, limitations. `docs/manpages/dksearch-api.7.md` describes the HTTP API.
- `docs/decisions/` holds the decision records (storage, index backend, API, connectors, authentication and so on) with the reasons behind them.
- `ai/AGENTS.md` and `ai/SPEC.md` hold the project rules and specification.

## License

GPL-2.0-only, see `LICENSE`. Vendored code keeps its own licenses (SQLite: public domain; toml-zig and Expat: MIT; bzip2: BSD-style), recorded in `vendor/*/README.md`. Data you import (Project Gutenberg books, Wikipedia text) has its own terms, which you must follow.
