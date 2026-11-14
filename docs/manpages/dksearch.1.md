% DKSEARCH(1) Version 0.0.0 | Project Manual
% dksearch contributors
% 2026-11-14

NAME
dksearch - self-hosted search engine: serve a search index over HTTP and validate its configuration

SYNOPSIS
dksearch [-h | --help] [-V | --version]

dksearch serve [--config FILE]

dksearch check-config FILE

DESCRIPTION
dksearch is an independently operated, self-hostable search engine. It maintains its own full-text index and does not use an external search provider.

This version provides the public search interface: a JSON API and a server-rendered HTML page, both read-only. It serves an existing index; it cannot yet import documents. Source connectors (Project Gutenberg, Wikipedia, and others) are planned, and until they exist an index must be produced by other means. The administration interface is not implemented; the `[admin]` configuration table is validated but nothing listens on it.

CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional.
Relative paths are resolved against the current working directory.
Durations are in milliseconds. Sizes are in bytes.

COMMANDS
serve
Open the index, listen on the address from the configuration, and answer requests until stopped by SIGINT or SIGTERM.

Usage: dksearch serve [--config FILE]

Options: --config FILE. Without it, built-in defaults are used (see CONFIGURATION), which listen on loopback only.

Examples: dksearch serve --config /etc/dksearch/dksearch.toml

check-config
Load and validate FILE exactly as **serve** would, report the result, and exit without starting anything.

Usage: dksearch check-config FILE

Examples: dksearch check-config dksearch.toml

OPTIONS
Global options
-h, --help
: Print usage to standard output and exit with status 0.

-V, --version
: Print `dksearch VERSION` to standard output and exit with status 0.

Command options
--config FILE, --config=FILE
: Used by **serve**. Load FILE instead of the built-in defaults. The file replaces the defaults for every key it sets; unset keys keep their defaults. Given more than once, the last one wins.

Option interactions and precedence
There are no environment variables or other configuration sources. Configuration comes only from the file named by **--config**, or from the defaults.

OPERANDS
FILE
: **check-config** takes exactly one FILE, a path to a TOML configuration file. `-` (standard input) is not supported.

INPUT
Configuration files are TOML (1.1, with 1.0 files accepted) in UTF-8, at most 1048576 bytes. Larger files are refused before parsing.

HTTP requests are described in dksearch-api(7).

OUTPUT
Standard output
**--help**, **--version** and the `ok` line of **check-config** (`FILE: ok`). Nothing else is written to standard output.

Standard error
All diagnostics, each prefixed `dksearch: `. **serve** writes a startup line giving the address and index path, and `stopped` after a graceful stop. If the configuration has an `[admin]` table it also notes that the administration interface is not implemented. Request logging is not implemented. The format of diagnostic lines is not stable.

EXIT STATUS
Status	Meaning
0	Success, including a normal stop by SIGINT or SIGTERM.
1	The server stopped on an unexpected error after starting.
2	Invalid command-line usage.
3	Configuration error: syntax error, unknown key, wrong type, out-of-range value.
4	I/O or resource error: configuration file unreadable, data directory or index cannot be created or opened, address cannot be bound.
Termination by an unhandled signal (for example SIGKILL or SIGHUP) has the usual status of that signal.

ENVIRONMENT
No environment variables are consulted by dksearch itself.

FILES
dksearch.toml (any name, passed with **--config**)
: Configuration file. There is no default search path.

*data_dir*/index.db
: The search index (SQLite, written in WAL mode), with companion files `index.db-wal` and `index.db-shm` while open. *data_dir* is `storage.data_dir`, default `data`, created with parents if missing. The index is derived data: it can be deleted and rebuilt from retained content when that machinery exists.

CONFIGURATION
Search paths and precedence
A single file named on the command line, or the built-in defaults.

Configuration format
    [server]
    address = "127.0.0.1"
    port = 8080
    request_timeout_ms = 10000
    max_connections = 256

    [admin]
    port = 8081

    [storage]
    data_dir = "data"

Configuration keys
Key	Type	Default	Description
server.address	String	127.0.0.1	IPv4 or IPv6 address literal to listen on. Host names are not accepted.
server.port	Integer	8080	TCP port, 1-65535.
server.max_header_bytes	Integer	8192	Largest request head accepted, 1024-65536. Larger requests get status 431.
server.request_timeout_ms	Integer	10000	Time allowed to receive a complete request head, and the idle time allowed between requests on a kept-alive connection. 100-600000.
server.write_timeout_ms	Integer	10000	Time allowed to send one response. 100-600000.
server.max_connections	Integer	256	Simultaneous connections, 1-65535. Further connections are closed immediately.
server.max_requests_per_connection	Integer	100	Requests served on one connection before it is closed, 1-10000.
server.shutdown_grace_ms	Integer	5000	On SIGINT or SIGTERM, how long requests already being handled may take to finish, 0-600000.
admin.*	-	-	Accepts the same keys as `server.*` (default port 8081). Validated only; not served yet.
storage.data_dir	String	data	Directory for the index and other state. Must not be empty.

Validation, unknown keys, reload behavior, versioning, and migration rules
The whole file is validated before anything starts. Unknown keys, wrong types and out-of-range values are errors that name the file and the key, for example `dksearch.toml: server.prot: unknown key`; a misspelled setting is never silently ignored. `admin` and `server` may not share the same address and port. There is no reload: configuration is read once at start, so a restart is required to apply changes. There is no configuration versioning yet.

EXAMPLES
Basic use
    dksearch serve --config dksearch.toml
Serves search on the configured address. With no file, listens on 127.0.0.1:8080.

Check a file before deploying
    dksearch check-config dksearch.toml && echo valid
Prints `dksearch.toml: ok` and exits 0, or prints the reason and exits 3 (or 4 if the file cannot be read).

Ask the running server
    curl 'http://127.0.0.1:8080/api/v1/search?q=truth&limit=5'

Automation and failure handling
    if ! dksearch check-config dksearch.toml; then
        printf 'bad configuration\n' >&2
    fi

DIAGNOSTICS
dksearch: FILE: KEY: unknown key
: A key is not recognised, usually a misspelling. Fix the key. Exit status 3.

dksearch: FILE: KEY: must be between MIN and MAX, got N
: A numeric value is out of range. Exit status 3.

dksearch: FILE:LINE:COL: MESSAGE
: TOML syntax error at the given position. Exit status 3.

dksearch: FILE: cannot read file: REASON
: The file is missing or unreadable, or is larger than 1048576 bytes. Exit status 4.

dksearch: cannot open index PATH: REASON
: The index file is unreadable or corrupt. Delete it and rebuild. Exit status 4.

dksearch: PATH was written by an incompatible version; delete it and rebuild the index
: The index schema version differs from this program's. Exit status 4.

dksearch: cannot listen on ADDRESS:PORT: REASON
: The address is in use, not local, or needs privileges. Exit status 4.

SECURITY CONSIDERATIONS
The HTTP listener has no authentication; the search API is read-only and intended to be public if the administrator exposes it. It listens on loopback by default. To expose it, set `server.address` explicitly. Prefer a reverse proxy for TLS (not implemented here) and rate limiting.

Trust boundaries: all request data is untrusted. Request heads are size-limited and must complete within a deadline; a client sending data slowly cannot hold a connection open past it. Request bodies are refused. Query text is never interpreted as search-engine syntax: operators, column filters and punctuation are searched as ordinary text, and queries are limited to 1024 bytes and 32 terms. Result pages escape all text, link only http and https URLs, and are sent with a Content-Security-Policy that forbids scripts and external resources. Database error details are never sent to clients. These properties are covered by the project's tests; they are not an audit.

SQLite is compiled without extension loading, so no native code is loaded at run time.

The index directory should be writable only by the account running dksearch. There are no secrets in the configuration at present.

PRIVACY
dksearch sends no telemetry and contacts no external service. Queries are not logged in this version (there is no request log). Anything placed in front of it, such as a reverse proxy, has its own logging.

RESOURCE USAGE
Memory per connection is the configured `max_header_bytes` read buffer, a 4096-byte write buffer, and the arena for the current request, whose size is bounded by the response (at most 100 hits). Each connection uses one task. At most `max_connections` connections exist at once. These are design bounds, not measurements; no benchmarks have been run.

PERFORMANCE
Search time is that of SQLite FTS5 over the index. Statements are prepared per query and each connection is handled by its own task; neither has been optimised or measured. Results are limited to a window of 10000 (offset plus limit) to bound deep-pagination cost.

CONCURRENCY AND ATOMICITY
Requests are served concurrently. The index is opened by one process; do not run two servers on the same `data_dir`. The index file is written in WAL mode with synchronous=NORMAL: after a power loss the last few commits may be lost, but the file remains consistent. Because the index is derived data, this is accepted in exchange for write speed.

SIGNALS
Signal	Behavior
SIGINT	Graceful stop, as for SIGTERM.
SIGTERM	Graceful stop: stop accepting connections, close idle (keep-alive) connections at once, let requests already being handled finish for up to `server.shutdown_grace_ms`, then exit with status 0. Anything still running after the grace period is cut off. A second signal does not hasten this.
SIGHUP	Not handled; terminates the process (default action). There is no reload.
SIGKILL, power loss	The index file stays consistent, but the last few commits may be lost (see above).

NETWORK
Listens on one TCP address (IPv4 or IPv6) for HTTP/1.1 with keep-alive. No TLS. No outbound connections. Works fully offline. Timeouts and limits are as listed under CONFIGURATION. Clients that exceed them are disconnected without a response, except oversized or malformed request heads, which receive 431 or 400.

COMPATIBILITY
Platforms
Developed and tested on Linux x86_64 with Zig 0.17.1. Other platforms are untested.

Standards
HTTP/1.1 message syntax as implemented by the Zig standard library; JSON per RFC 8259. Compliance is not claimed beyond that.

Stability guarantees
The `/api/v1/` API is intended to be stable within version 1 (see dksearch-api(7)). The command-line syntax, configuration keys and diagnostics text are experimental at version 0.

LIMITATIONS
Cannot import documents; serves an existing index only. No administration interface. No TLS. No reload or request log. Only the `unicode61` tokenizer is used, so languages without word separators (such as Chinese or Japanese) are not segmented well. Index size and query time at large scale have not been measured.

BUGS
No issue tracker is published yet. When one exists it will be listed under AVAILABILITY. Include the dksearch version, the configuration file, the full diagnostic output and the request that failed.

TROUBLESHOOTING
Program fails to start
Run `dksearch check-config FILE`. Check that the port is free (`ss -ltn`), that `data_dir` is writable, and that no other dksearch uses the same `data_dir`.

Unexpected output
Searches return nothing: the index may be empty, since this version cannot import documents. Check `GET /api/v1/health`, then `GET /api/v1/search?q=...`.

Slow operation
Check that `data_dir` is on a local filesystem. WAL mode does not work reliably on network filesystems, and a filesystem with slow fsync slows index writes.

NOTES
The index is a SQLite database containing two tables, `docs` and an FTS5 table `fts`. Its layout is internal and may change between versions; a version mismatch is detected and reported.

CAVEATS
Deleting `index.db` deletes the searchable data. It can only be rebuilt from retained content, which this version does not yet persist.

HISTORY
Version 0.0.0 is the first, pre-release version.

DEPRECATION
Nothing is deprecated.

SEE ALSO
dksearch-api(7), toml-syntax(5)

Project documents: `ai/SPEC.md`, `docs/decisions/`. SQLite FTS5: https://www.sqlite.org/fts5.html. TOML: https://toml.io/

AUTHOR
dksearch contributors.

COPYRIGHT
Copyright 2026 dksearch contributors. SPDX-License-Identifier: GPL-2.0-only

LICENSE
GNU General Public License, version 2 only. The complete text is in the file `LICENSE` in the source distribution. Vendored components keep their own licenses, which are compatible with it: SQLite is in the public domain (`vendor/sqlite/README.md`); toml-zig is MIT (`vendor/toml-zig/LICENSE`).

AVAILABILITY
Source code, releases and issue tracker: not yet published.

VERSION
This manual describes dksearch version 0.0.0. It is updated together with the program.
