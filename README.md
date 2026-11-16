# dksearch

A self-hostable search engine written in Zig. It keeps its own full-text index, serves a small public search page and JSON API, and can import documents from local files, Project Gutenberg and Wikipedia dumps. It works offline: after you have downloaded a dataset, nothing needs the network.

Status: version 0.0.0, pre-release. It works end to end and is tested (over 220 offline tests plus runs with the real binary), but it has only been measured on a 20,000-document index (`docs/performance.md`) and its interfaces may still change. See `docs/manpages/dksearch.1.md` for what is and is not implemented.

## Build

Needs Zig 0.17.1 and nothing else. All dependencies are vendored (SQLite, a TOML parser, the Mozilla CA certificates, and an XML parser, and, for Wikipedia, bzip2). The web crawler uses Zig's own HTTP and TLS client.

    zig build -Doptimize=ReleaseSafe     # binary: zig-out/bin/dksearch
    zig build test                       # all tests; they run offline
    zig build -Dwikipedia=false -Dfeeds=false -Dcrawler=false   # leave out those connectors and what they need

## Help

`dksearch --help` lists the commands; `dksearch help COMMAND` explains one; `dksearch help start`, `dksearch help config` and `dksearch help admin` cover a first run, the configuration file and the steps to set up the administration interface.

## Try it

Index a directory of text and Markdown files and search it:

    dksearch init        # writes dksearch.toml (commented; never overwrites)
    # edit it: add a source, e.g.
    #   [[source]]
    #   name = "notes"
    #   kind = "files"
    #   path = "/home/me/notes"

    dksearch import --config dksearch.toml notes
    dksearch serve --config dksearch.toml
    # then open http://127.0.0.1:8080/ or:
    curl 'http://127.0.0.1:8080/api/v1/search?q=lighthouse'

The generated file also holds the administration interface, commented out with the three steps to turn it on (remove the `#`, run `dksearch admin-password`, restart `serve`); `dksearch help admin` has the details.

Sources are optional. With none configured, `serve` still works and serves whatever index exists, and documents can arrive through any connector that uses the same interface.

## What is in it

- **Search**: SQLite FTS5 with title and body weighting, phrase and multi-term queries, snippets, filters and stable paging; optional English stemming (`[index] tokenizer = "porter"`). User text is never interpreted as query syntax. Searches run on a pool of read-only connections, so concurrent queries scale across CPU cores.
- **Public interface**: a server-rendered HTML page (no JavaScript) and a versioned JSON API, both read-only.
- **Connectors** (all optional, all read local files and never use the network): local `.txt`/`.md` files; Project Gutenberg (catalog CSV plus book files you downloaded); Wikipedia (a `pages-articles` dump, bzip2 or plain XML); RSS and Atom feed files. Imports resume where they stopped and skip unchanged documents.
- **Operations**: `rebuild` the index from retained content, `check` the stored data (including every text's hash), `backup` it safely while running, `remove` a source, `import --prune` documents that left a source.
- **Administration**: a separate listener with a dashboard, an import-jobs page, counters, a query-testing page that shows ranking scores, and a JSON API, behind a bearer token or a password (credentials are kept only as hashes). Read-only unless you set `admin.actions = true`, which lets it start and cancel imports.
- **Privacy**: no telemetry, no request log by default; the optional access log never records queries or client details.
- **Portability**: builds for Linux (including a static musl binary), macOS and FreeBSD on x86_64 and ARM; only Linux x86_64 has been run. Windows is not supported.

## Documentation

- `docs/manpages/dksearch.1.md` is the full reference: commands, configuration, files, security, limitations. `docs/manpages/dksearch-api.7.md` describes the HTTP API.
- `docs/deploy/` has the systemd units, example configuration, reverse-proxy and backup guide.
- `docs/decisions/` (start with its README) holds the decision records (storage, index backend, API, connectors, authentication and so on) with the reasons behind them.
- `ai/AGENTS.md` and `ai/SPEC.md` hold the project rules and specification.

## License

GPL-2.0-only, see `LICENSE`. Vendored code keeps its own licenses (SQLite: public domain; toml-zig and xml-zig: MIT; bzip2: BSD-style), recorded in `vendor/*/README.md`. Data you import (Project Gutenberg books, Wikipedia text) has its own terms, which you must follow.
