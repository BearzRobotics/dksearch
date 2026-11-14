% DKSEARCH(1) Version 0.0.0 | Project Manual
% dksearch contributors
% 2026-11-14

NAME
dksearch - self-hosted search engine: import documents, serve a search index over HTTP, and validate its configuration

SYNOPSIS
dksearch [-h | --help] [-V | --version]

dksearch serve [--config FILE]

dksearch import --config FILE (SOURCE | --all)

dksearch rebuild [--config FILE]

dksearch check [--config FILE]

dksearch backup [--config FILE] DIR

dksearch check-config FILE

DESCRIPTION
dksearch is an independently operated, self-hostable search engine. It maintains its own full-text index and does not use an external search provider.

This version provides the public search interface (a JSON API and a server-rendered HTML page, both read-only), an import command, an index rebuild command, and commands to check and back up the stored data. Documents arrive through *sources* defined in the configuration file. Sources are optional: with none configured, **serve** still works and serves whatever index exists. Each source is one instance of a *connector*; this version bundles two: `files`, which indexes plain-text and Markdown files from a local directory, and `gutenberg`, which indexes Project Gutenberg books from a catalog file and a directory of book files you have already downloaded. A connector for Wikipedia is planned. The administration interface is not implemented; the `[admin]` configuration table is validated but nothing listens on it.

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

Options: --config FILE. Without it, built-in defaults are used (see CONFIGURATION), which listen on loopback only and have no sources.

Examples: dksearch serve --config /etc/dksearch/dksearch.toml

import
Run one source, or every enabled source, and add its documents to the index. Progress is recorded durably, so a run that is interrupted or fails resumes from its last saved position the next time the same source is imported. A source that completed starts over, and documents that have not changed are recognised and skipped.

Usage: dksearch import --config FILE (SOURCE | --all)

Arguments: SOURCE, the `name` of a `[[source]]` in FILE. A source with `enabled = false` is not run, and naming one is an error. **--all** runs every enabled source in file order. Exactly one of SOURCE or **--all** is required. **--config** is required, since sources are defined there.

Examples: dksearch import --config dksearch.toml my-notes

rebuild
Delete the search index and rebuild it from the retained content and document records, without reading any source. Use it after deleting or losing `index.db`, or after a version change. Documents whose text was not retained (`retain_text = false`) cannot be rebuilt and are reported as skipped. It is safe to run again if interrupted. Searches made while it runs see a partial index, so stop **serve** first if that matters.

Usage: dksearch rebuild [--config FILE]

check
Verify the stored data without changing it, and report. It runs SQLite's integrity check on `state.db`, `content.db` and `index.db`, checks the index's full-text structures, and then reads every document record's retained text and verifies it (decompression, recorded size and SHA-256), which catches damage SQLite's own check cannot see. It reports records whose text was not retained, texts that no record refers to (harmless leftovers of interrupted imports), and whether the index matches the records. Files are opened read-only, nothing is upgraded or repaired, and a file that does not exist is reported as absent, not created, so it is safe while **serve** or **import** runs. It reads all retained text, so on a large collection it takes a while.

Usage: dksearch check [--config FILE]

Options: --config FILE. Without it the built-in defaults are used.

Examples: dksearch check --config dksearch.toml

backup
Write a consistent, verified copy of `state.db` and `content.db` (the only copies of what was imported) into the directory DIR, creating it if needed. Each copy is a snapshot taken at one instant, made with SQLite's own copy mechanism, so it is safe while **serve** or **import** runs. `state.db` is copied first and `content.db` second, so the copy of the content always contains every text the copy of the records refers to. The copies are synced to disk and checked with SQLite's integrity check before the command reports success. It never overwrites: if either destination file exists it stops before writing anything. `index.db` is not copied, because **rebuild** recreates it.

Usage: dksearch backup [--config FILE] DIR

Arguments: DIR, the destination directory. Use a new directory for each backup.

Examples: dksearch backup --config dksearch.toml /backups/dksearch-2026-11-14

check-config
Load and validate FILE exactly as **serve** and **import** would, including the options of every source (enabled or not), report the result, and exit without starting anything or touching any data.

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
: Used by **serve**, **import** and **rebuild**. Load FILE instead of the built-in defaults. The file replaces the defaults for every key it sets; unset keys keep their defaults. Given more than once, the last one wins.

Option interactions and precedence
There are no environment variables or other configuration sources. Configuration comes only from the file named by **--config**, or from the defaults.

--all
: Used by **import**. Run every enabled source.

OPERANDS
SOURCE
: **import** takes one SOURCE, the name of a configured source, unless **--all** is given.

FILE
: **check-config** takes exactly one FILE, a path to a TOML configuration file. `-` (standard input) is not supported.

INPUT
Configuration files are TOML (1.1, with 1.0 files accepted) in UTF-8, at most 1048576 bytes. Larger files are refused before parsing.

HTTP requests are described in dksearch-api(7).

OUTPUT
Standard output
**--help**, **--version** and the `ok` line of **check-config** (`FILE: ok`). Nothing else is written to standard output.

Standard error
All diagnostics, each prefixed `dksearch: `. **import** and **rebuild** write their one-line result to standard output. **serve** writes a startup line giving the address and index path, and `stopped` after a graceful stop. If the configuration has an `[admin]` table it also notes that the administration interface is not implemented. Request logging is not implemented. The format of diagnostic lines is not stable.

EXIT STATUS
Status	Meaning
0	Success, including a normal stop of **serve** by SIGINT or SIGTERM, and an **import** in which every run source completed.
1	The server stopped on an unexpected error after starting, an **import** run did not complete (it failed, or was cancelled by a signal), or **check** found damage. The run's state and any resume position are recorded.
2	Invalid command-line usage, including naming a source that does not exist or is disabled.
3	Configuration error: syntax error, unknown key, wrong type, out-of-range value.
4	I/O or resource error: configuration file unreadable, data directory or index cannot be created or opened, address cannot be bound, a backup could not be written or verified or would overwrite an existing file.
Termination by an unhandled signal (for example SIGKILL or SIGHUP) has the usual status of that signal.

ENVIRONMENT
No environment variables are consulted by dksearch itself.

FILES
dksearch.toml (any name, passed with **--config**)
: Configuration file. There is no default search path.

*data_dir*/index.db
: The search index (SQLite, written in WAL mode), with companion files `index.db-wal` and `index.db-shm` while open. *data_dir* is `storage.data_dir`, default `data`, created with parents if missing. The index is derived data: delete it freely and run **rebuild**.

*data_dir*/state.db
: Document metadata and provenance, and the record of import runs with their resume positions. This is source-of-truth data: it cannot be rebuilt from anything else. Created by **import**. When a newer version of dksearch upgrades its layout, the old file is first copied to `state.db.pre-vN`.

*data_dir*/content.db
: The retained text of imported documents, compressed, with a checksum for each. Also source-of-truth data. Created by **import**. Upgraded the same way as `state.db`.

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
source	Array of tables	none	Optional. Each `[[source]]` defines one connector instance; see Sources below.

Sources
Each `[[source]]` table has these keys. Any other key is an option of the connector named by `kind` and is validated by it, so a misspelled option is an error.

Key	Type	Default	Description
name	String	required	Unique name, 1-64 characters of `a-z`, `0-9`, `_` and `-`, starting with a letter or digit. Resume positions are kept per name, and it becomes the `connector` of each document, so renaming a source makes it start afresh and its old documents stay under the old name.
kind	String	required	Connector type. This version knows `files` and `gutenberg`.
enabled	Boolean	true	A disabled source stays in the file but is never run.
retain_text	Boolean	true	Keep each document's text so the index can be rebuilt without reading the source again. Set false for a source whose terms forbid keeping its text; its documents are then skipped by **rebuild**.

Kind `files` indexes `.txt` and `.md` files (extension case-insensitive) under a directory, including subdirectories:

Key	Type	Default	Description
path	String	required	The directory to index, absolute or relative to the working directory.
max_file_bytes	Integer	4194304	Largest file accepted, 1-67108864. Larger files are skipped, never truncated.
language	String	none	Language tag stored on every document, such as `en` or `pt-BR`.

Files are read in sorted path order. Symbolic links are never followed. Hidden files and directories (names starting with `.`) are skipped. Files that are not valid UTF-8, contain a NUL byte, or are empty are skipped. The title is the first Markdown `# heading` in a `.md` file, otherwise the file name without its extension. The document id is derived from the source name and the path relative to `path`.

Example:

    [[source]]
    name = "my-notes"
    kind = "files"
    path = "/home/me/notes"
    language = "en"

Kind `gutenberg` indexes books from Project Gutenberg. It never uses the network: download the catalog (`pg_catalog.csv`, which Project Gutenberg publishes for this purpose) and the books yourself, for example from a mirror, and point the source at them.

Key	Type	Default	Description
catalog	String	required	Path of the catalog CSV file.
books	String	required	Directory holding the book text files.
language	String	none	Only import books in this language, such as `en`. A book listed in several languages matches any of them.
max_file_bytes	Integer	16777216	Largest book accepted, 1-67108864. Larger books are refused, never truncated.

Only catalog rows of type `Text` are used. A book with catalog number N is looked for as `pgN.txt`, `N-0.txt`, `N.txt`, `N.txt.utf8` or `pgN.txt.utf8`, directly in `books` or in a subdirectory `N/` of it. A catalog row with no local file is skipped, which is normal when only part of the collection was downloaded. A book that is not valid UTF-8, contains a NUL byte, is too large or has no text after trimming is refused and counted as rejected; it is not converted. The Project Gutenberg license header and footer (the text outside the `*** START OF` and `*** END OF` lines) is not indexed; a file without those lines is indexed whole. The title, authors, language, subjects and bookshelves come from the catalog. Each document records the catalog number, a link to `https://www.gutenberg.org/ebooks/N`, the source dataset "Project Gutenberg", and rights: the license "Project Gutenberg License", its URL, an attribution line, and redistribution `restricted`. The id is derived from the source name and the catalog number. A saved position is the number of catalog rows handled, so resuming needs the same catalog file; a malformed catalog fails the job instead of being skipped.

Example:

    [[source]]
    name = "gutenberg-en"
    kind = "gutenberg"
    catalog = "/data/gutenberg/pg_catalog.csv"
    books = "/data/gutenberg/books"
    language = "en"

Validation, unknown keys, reload behavior, versioning, and migration rules
The whole file is validated before anything starts, including every source's options. Unknown keys, wrong types and out-of-range values are errors that name the file and the key, for example `dksearch.toml: server.prot: unknown key`; a misspelled setting is never silently ignored. `admin` and `server` may not share the same address and port. There is no reload: configuration is read once at start, so a restart is required to apply changes. There is no configuration versioning yet.

EXAMPLES
Basic use
    dksearch import --config dksearch.toml my-notes
    dksearch serve --config dksearch.toml
Indexes the files of the source `my-notes`, then serves search on the configured address. With no file, **serve** listens on 127.0.0.1:8080 and the index is empty.

Import again later
    dksearch import --config dksearch.toml --all
Only new and changed files are written; the output line reports how many were added, updated and unchanged.

Rebuild after losing the index
    rm data/index.db* && dksearch rebuild --config dksearch.toml

Check a file before deploying
    dksearch check-config dksearch.toml && echo valid
Prints `dksearch.toml: ok (N sources)` and exits 0, or prints the reason and exits 3 (or 4 if the file cannot be read).

Check the stored data, and back it up
    dksearch check --config dksearch.toml
    dksearch backup --config dksearch.toml /backups/dksearch-$(date +%F)
**check** prints one line per database and the verification totals, then `ok` and exit status 0, or a `problem:` line and exit status 1 when it finds damage. To restore, stop dksearch, copy `state.db` and `content.db` from the backup into `data_dir` (removing any `state.db-wal`, `state.db-shm`, `content.db-wal` and `content.db-shm` left there), and run `dksearch rebuild` to recreate the index.

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

dksearch: FILE: source[NAME].OPTION: unknown option for kind "files"
: A source has a misspelled or unsupported option. Exit status 3.

dksearch: FILE: source[NAME].kind: unknown connector kind "KIND"
: This build has no such connector. Exit status 3.

dksearch: NAME: stopped by the ingestion pipeline (storage full or shutting down)
: The import could not continue because storage refused a write. The run is recorded as failed and resumes from its last position. Exit status 1.

dksearch: PATH was written by a newer version of dksearch; refusing to open it
: `state.db` or `content.db` has a layout from a newer release. Use that release, or restore a backup. Exit status 4.

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

The `gutenberg` connector treats the catalog and the book files as untrusted input: it bounds field and file sizes, refuses malformed catalogs and invalid text, derives file names only from validated numeric catalog ids, never follows symbolic links, and executes nothing. Project Gutenberg's license and trademark terms apply to the books you import; read them at https://www.gutenberg.org/policy/license.html before redistributing text or running a public service with it.

The `files` connector treats the directory tree as untrusted input. It never follows symbolic links, skips hidden entries, reads only regular files with the expected extensions, enforces a size limit, rejects invalid text, and executes nothing. It indexes only what its account can read, and the text of every indexed file becomes searchable and is shown in results, so point it only at directories whose contents may be searched by everyone who can reach the server. Result URLs for these files are `file://` URLs, which the HTML page shows as plain text, not links.

PRIVACY
dksearch sends no telemetry and contacts no external service. Queries are not logged in this version (there is no request log). **import** records, in `state.db`, the name, time, counts and last position of each run; it does not record file contents beyond what is indexed. Anything placed in front of it, such as a reverse proxy, has its own logging.

RESOURCE USAGE
**import** processes one document at a time and holds one batch open (at most 1000 documents, or fewer when the connector saves positions more often) in database transactions before committing it. The `files` connector keeps the sorted list of file paths in memory and reads one file at a time. **serve** memory per connection is the configured `max_header_bytes` read buffer, a 4096-byte write buffer, and the arena for the current request, whose size is bounded by the response (at most 100 hits). Each connection uses one task. At most `max_connections` connections exist at once. These are design bounds, not measurements; no benchmarks have been run.

PERFORMANCE
Search time is that of SQLite FTS5 over the index. Statements are prepared per query and each connection is handled by its own task; neither has been optimised or measured. Results are limited to a window of 10000 (offset plus limit) to bound deep-pagination cost.

CONCURRENCY AND ATOMICITY
Requests are served concurrently. Do not run two servers, or two imports, on the same `data_dir`. **check** and **backup** may run at any time. Running **serve** while **import** writes is supported: readers are not blocked, and new documents appear when each batch commits.

Imports write in batches: content first, then the index, then the document records, and only then the saved position. After a crash, everything up to the last committed batch is intact and the run resumes from its position; the interrupted batch is lost as a unit and repeated, and the pipeline's duplicate detection makes that repetition harmless. The index file is written in WAL mode with synchronous=NORMAL: after a power loss the last few commits may be lost, but the file remains consistent. Because the index is derived data, this is accepted in exchange for write speed.

SIGNALS
Signal	Behavior
SIGINT	Graceful stop, as for SIGTERM. During **import**: stop after the current file, commit the batch in progress, record the run as cancelled with its position, and exit with status 1.
SIGTERM	During **import**, as SIGINT. During **serve**, a graceful stop: stop accepting connections, close idle (keep-alive) connections at once, let requests already being handled finish for up to `server.shutdown_grace_ms`, then exit with status 0. Anything still running after the grace period is cut off. A second signal does not hasten this.
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
Two connectors are bundled (`files` and `gutenberg`); Wikipedia is planned. The `gutenberg` connector reads only the CSV catalog, not the RDF catalog, and does not unpack archives or read HTML or EPUB books. No way yet to remove a source's documents, or to import documents that no longer exist as files (re-importing never deletes). Backups are manual (no scheduling or retention) and the copies are not encrypted. No administration interface. No TLS. No reload or request log. Only the `unicode61` tokenizer is used, so languages without word separators (such as Chinese or Japanese) are not segmented well. Index size and query time at large scale have not been measured.

BUGS
No issue tracker is published yet. When one exists it will be listed under AVAILABILITY. Include the dksearch version, the configuration file, the full diagnostic output and the request that failed.

TROUBLESHOOTING
Program fails to start
Run `dksearch check-config FILE`. Check that the port is free (`ss -ltn`), that `data_dir` is writable, and that no other dksearch uses the same `data_dir`.

Unexpected output
Searches return nothing: the index may be empty. Run **import** for a configured source, or check that the source's `path` holds `.txt` or `.md` files that are not hidden. Check `GET /api/v1/health`, then `GET /api/v1/search?q=...`.

Slow operation
Check that `data_dir` is on a local filesystem. WAL mode does not work reliably on network filesystems, and a filesystem with slow fsync slows index writes.

NOTES
The three databases are SQLite files. The index holds a `docs` table and an FTS5 table `fts`. Layouts are internal and may change between versions; a version mismatch is detected and reported.

CAVEATS
Deleting `index.db` is safe: **rebuild** restores it. Deleting `state.db` or `content.db` is not: they are the only copy of what was imported, and an index cannot be rebuilt without them. Back them up with **backup**, and check them now and then with **check**; do not copy the files with `cp` while **import** runs, because the write-ahead log (`-wal`) files must be copied with them to be consistent. Re-importing never deletes documents whose source files were removed.

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
