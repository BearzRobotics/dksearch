# NAME

dksearch - self-hosted search engine: import documents, serve a search index over HTTP, and validate its configuration

# SYNOPSIS

    dksearch [-h | --help] [-V | --version]

    dksearch serve [--config FILE]

    dksearch import --config FILE (SOURCE | --all) [--prune]

    dksearch remove --config FILE SOURCE [--yes]

    dksearch rebuild [--config FILE]

    dksearch repair [--config FILE] [--dry-run]

    dksearch check [--config FILE]

    dksearch admin-token [--config FILE]

    dksearch admin-password [--config FILE]

    dksearch api-key add NAME (--all | --collection NAME ...) [--rate PER_MINUTE] [--node ID] [--config FILE]

    dksearch models list | pull NAME --yes | remove NAME --yes [--config FILE]

    dksearch node-key [--config FILE]

    dksearch api-key list [--config FILE]

    dksearch api-key remove NAME_OR_ID [--config FILE]

    dksearch backup [--config FILE] DIR

    dksearch check-config FILE

# DESCRIPTION

dksearch is an independently operated, self-hostable search engine. It maintains its own full-text index and does not use an external search provider.

This version provides the public search interface (a JSON API and a server-rendered HTML page, both read-only), an import command, an index rebuild command, and commands to check and back up the stored data. Documents arrive through *sources* defined in the configuration file. Sources are optional: with none configured, **serve** still works and serves whatever index exists. Each source is one instance of a *connector*; this version bundles seven: `files`, which indexes plain-text and Markdown files from a local directory; `gutenberg`, which indexes Project Gutenberg books from a catalog file and a directory of book files you have already downloaded; `wikipedia`, which indexes the articles of a Wikipedia dump file you have already downloaded; `zim`, which indexes the articles of a Kiwix ZIM file you have already downloaded; `feeds`, which indexes the entries of RSS and Atom feed files you have already downloaded; `crawl`, which fetches a list of web pages you name, over HTTP or HTTPS; and `archive`, which indexes the metadata of Internet Archive items matching a search. `crawl` and `archive` are the only connectors that use the network. The `wikipedia`, `feeds`, `crawl` and `archive` connectors are built by default and can be left out with `zig build -Dwikipedia=false`, `-Dfeeds=false` and `-Dcrawler=false` (the last one removes both network connectors). A separate administration interface (a dashboard with sources, storage and a live progress bar for a running import, import jobs and why items were skipped, counters, a query-testing page that shows ranking scores, and optionally starting and cancelling imports, and with `actions` on, running a check, a backup or the removal of a source from the Maintenance page) is served on its own address when the configuration has an `[admin]` table and credentials exist; see **admin-token**, **admin-password** and SECURITY CONSIDERATIONS.

# CONVENTIONS

Bold represents literal commands, options, and keywords.

Italic or uppercase placeholders represent values supplied by the user.

[item] means optional.

Relative paths are resolved against the current working directory.

Durations are in milliseconds. Sizes are in bytes.

# COMMANDS

serve

Open the index, listen on the address from the configuration, and answer requests until stopped by SIGINT or SIGTERM.

Usage: dksearch serve [--config FILE]

Options: --config FILE. Without it, built-in defaults are used (see CONFIGURATION), which listen on loopback only and have no sources.

Examples: dksearch serve --config /etc/dksearch/dksearch.toml

import

Run one source, or every enabled source, and add its documents to the index. Progress is recorded durably, so a run that is interrupted or fails resumes from its last saved position the next time the same source is imported. A source that completed starts over, and documents that have not changed are recognised and skipped.

Usage: dksearch import --config FILE (SOURCE | --all) [--prune]

Arguments: SOURCE, the `name` of a `[[source]]` in FILE. A source with `enabled = false` is not run, and naming one is an error. **--all** runs every enabled source in file order. Exactly one of SOURCE or **--all** is required. **--config** is required, since sources are defined there.

Options: **--prune** also removes the source's documents whose items are no longer in the source, after a run that completed. The `files` connector treats a file that no longer exists (or is no longer a regular file) as gone; the `gutenberg` connector treats a book with no remaining local file as gone. If the source itself cannot be read (the directory is missing or unmounted), nothing is removed. Without **--prune**, re-importing never deletes anything.

Examples: dksearch import --config dksearch.toml my-notes

Connectors that can say why they skipped something (currently `crawl`) add a line such as `web: skipped because: robots=3, http_status=2`. The reasons are `robots` (disallowed by robots.txt, or robots.txt unreadable), `network` (could not connect, or timed out), `certificate` (a TLS certificate that did not verify), `http_status` (an answer other than success), `wrong_type` (not HTML or text), `too_large`, `encoding`, `no_text` (empty, or marked `noindex`), `redirect` (refused or looping) and `limit` (page or site limit, or an unusable URL) and `banned` (the site's domain is on the ban list: it is not contacted at all). They are also kept with each job and shown in the administration interface.

remove

Remove every document of the source named SOURCE from the index, the retained text and the document records, and forget the source's import history, so a later import of that name starts afresh. SOURCE need not be in the configuration file, which is the usual case after deleting a source from it. Without **--yes** nothing is changed: it reports how many documents the source has. Removal works in batches that are committed one at a time, and is safe to interrupt (SIGINT) or repeat: what was not removed yet is removed by the next run. The documents can be restored by importing the source again.

Usage: dksearch remove --config FILE SOURCE [--yes]

Arguments: SOURCE, the name the documents were imported under. **--config** is required because it names the data directory. **--yes** performs the removal.

Examples: dksearch remove --config dksearch.toml old-notes --yes

rebuild

Delete the search index and rebuild it from the retained content and document records, without reading any source. Use it after deleting or losing `index.db`, after a version change, or after changing `index.tokenizer` (rebuild is the one command that recreates the index with a new tokenizer). Documents whose text was not retained (`retain_text = false`) cannot be rebuilt and are reported as skipped. It is safe to run again if interrupted. Searches made while it runs see a partial index, so stop **serve** first if that matters.

Usage: dksearch rebuild [--config FILE]

repair

Bring the stored documents of the crawl sources up to date with what the crawler does now, without fetching anything. A document keeps what it had when it was stored: a title with `&bull;` in it, an address with `./` or a tracking parameter in it (the crawler now tidies these, so the same page is fetched again under the tidy address and the index has it twice), no language. **repair** decodes HTML entities in titles; for a document whose address is not tidy, removes it if the page is already stored under the tidy address and else moves it there (a new document id, the same text and record); and gives a page with no language one from the first part of its address (`/ja/`, `/zh-CN/`) or from the script of its text (Chinese, Japanese, Korean, Cyrillic, Arabic, Hebrew, Greek, Thai, Devanagari; Latin text is left alone). The work is done in batches, so it can be stopped and run again. A document whose text is not retained is left as it is.

Usage: dksearch repair [--config FILE] [--dry-run]

Arguments: **--dry-run** only counts what would be done, changes nothing and does not need `serve` to be stopped; without it the writers' lock is needed, as for **rebuild**.

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

help

Show help at the terminal: `dksearch --help` lists the commands and topics, `dksearch help COMMAND` (or `dksearch COMMAND --help`) explains one command, and the topics `dksearch help start`, `dksearch help config` and `dksearch help admin` give a first run, the shape of the configuration file and the steps to set up the administration interface.

Usage: dksearch help [COMMAND | start | config | admin]

eval

Measure the ranking. JUDGMENTS is a text file with one JSON object per line, naming a query and the documents relevant to it, by URL or by document id: `{"query": "lighthouse keeper", "relevant": ["https://example.org/keeper"]}`, or with grades from 1 up, `{"query": "tides", "relevant": {"https://example.org/tides": 3, "https://example.org/moon": 1}}`. Blank lines and lines starting with `#` are skipped. Each query is run against the index as **serve** would run it, and the command prints, per query and as means, precision and recall in the first K hits, the reciprocal rank of the first relevant hit, and nDCG (with gain 2^grade-1), then lists judged documents that were outside the first K with their rank (searched to 100). A query the search cannot run (no searchable terms) is reported as failed and scores zero. Nothing is written. Use it to compare settings, such as the tokenizer, on judgments you trust; a handful of queries shows direction, not proof.

Usage: dksearch eval [--config FILE] [-k N] [--language CODES] [--json] JUDGMENTS

Arguments: JUDGMENTS, the file described above. **-k** is the cutoff, 1-100, default 10. **--language** is the language the reader prefers (as the browser's Accept-Language: `en`, `en,fr`; `none` for no preference), default `en`. **--json** prints one JSON object instead of the table. The search is asked as the results page asks it: pictures are left out, a page in the index twice counts once, and `[search] per_domain` applies, so the numbers say what a person would see.

Examples: dksearch eval --config dksearch.toml judgments.jsonl

restore

Recreate `state.db` and `content.db` in `data_dir` from a backup directory DIR made by **backup**, then rebuild the search index from them. The backup is checked first (SQLite integrity and every text against its record) and nothing is written if it is damaged. It never overwrites: if `state.db`, `content.db` or `index.db` already exists in `data_dir` it stops before writing anything, so move the old files away or point `data_dir` at an empty directory. Each file is written under a temporary name and renamed into place only once complete and verified, `content.db` first and `state.db` last, so a `state.db` in `data_dir` always belongs to a complete restore; an interrupted restore can simply be run again. It takes the same write lock as **import** and **rebuild**. Stop **serve** first if it uses the same `data_dir`. Restoring and then rebuilding 286,047 Simple English Wikipedia articles took 2 minutes 20 seconds, and the restored index returned identical results.

Usage: dksearch restore [--config FILE] [--no-index] DIR

Arguments: DIR, a directory written by **backup**. **--no-index** skips the rebuild (run **rebuild** yourself before serving).

Examples: dksearch restore --config dksearch.toml /backups/dksearch-2026-11-14

admin-token

Create a new bearer token for the administration interface. It prints the token (`dks_` and 43 characters) to standard output, once, and stores only its SHA-256 hash in the secrets file (`admin.secrets_file`, mode 0600, replaced atomically). Any earlier token stops working at once, and sessions made with it end. Scripts send it as `Authorization: Bearer TOKEN`. The administration interface does not start until at least one credential exists.

Usage: dksearch admin-token [--config FILE]

admin-password

Set the administration password, the fallback for people using a browser. The password is read without echo and asked twice on a terminal, or as one line from standard input (so `dksearch admin-password < file` works); it is never taken from an argument or the environment. Only an Argon2id hash is stored. Changing it signs everyone out. On the sign-in page a person can enter either the password or the token.

Usage: dksearch admin-password [--config FILE]

api-key

Make, list or remove API keys. A key lets a program (or another dksearch) use the search API and see only the collections it was made for (see **COLLECTIONS AND API KEYS** under CONFIGURATION). **add** prints the key (`dkk_` and 43 characters) to standard output, once, and stores only its SHA-256 hash in `data_dir/api-keys.toml` (mode 0600); the key can be limited to named collections (`--collection`, repeatable, each must be defined in the configuration) or made for every source (`--all`). **list** shows each key's number (the first eight hex digits of its hash), name and collections, never the key. **remove** takes the name or the number. Keys are looked at again when the file changes, so a key made or removed with the server running works or stops within a second.

**--node** binds the key to a node (see NODE IDENTITY): it then works only with a signature of that node. **--rate** limits the key to that many requests per minute (fixed one-minute windows; over it the key gets 429 `rate_limited` with `Retry-After` until the minute ends); 0 or leaving it out means no limit. **list** shows the limit.

Usage: dksearch api-key add NAME (--all | --collection NAME ...) [--rate PER_MINUTE] [--node ID] | list | remove NAME_OR_ID [--config FILE]

Examples: dksearch api-key add laptop --collection books --collection docs

check-config

Load and validate FILE exactly as **serve** and **import** would, including the options of every source (enabled or not), report the result, and exit without starting anything or touching any data.

Usage: dksearch check-config FILE

Examples: dksearch check-config dksearch.toml

# OPTIONS


## Global options

-h, --help
: Print usage to standard output and exit with status 0.

-V, --version
: Print `dksearch VERSION` to standard output and exit with status 0.


## Command options

--config FILE, --config=FILE
: Used by **serve**, **import** and **rebuild**. Load FILE instead of the built-in defaults. The file replaces the defaults for every key it sets; unset keys keep their defaults. Given more than once, the last one wins.

Option interactions and precedence

There are no environment variables or other configuration sources. Configuration comes only from the file named by **--config**, or from the defaults.

--all
: Used by **import**. Run every enabled source.

# OPERANDS

SOURCE
: **import** takes one SOURCE, the name of a configured source, unless **--all** is given.

FILE
: **check-config** takes exactly one FILE, a path to a TOML configuration file. `-` (standard input) is not supported.

# INPUT

Configuration files are TOML (1.1, with 1.0 files accepted) in UTF-8, at most 1048576 bytes. Larger files are refused before parsing.

HTTP requests are described in dksearch-api(7).

# OUTPUT

Standard output

**--help**, **--version** and the `ok` line of **check-config** (`FILE: ok`). Nothing else is written to standard output.

Standard error

All diagnostics, each prefixed `dksearch: `. **import** and **rebuild** write their one-line result to standard output. **serve** writes a startup line giving the address and index path, and `stopped` after a graceful stop. If the configuration has an `[admin]` table it also reports that the administration interface is serving, or why it was not started (no credentials, unreadable secrets file, address in use). Request logging is off unless `access_log` is set; see PRIVACY. The format of diagnostic lines is not stable.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success, including a normal stop of **serve** by SIGINT or SIGTERM, and an **import** in which every run source completed. |
| 1 | The server stopped on an unexpected error after starting, an **import** run did not complete (it failed, or was cancelled by a signal), or **check** found damage. The run's state and any resume position are recorded. |
| 2 | Invalid command-line usage, including naming a source that does not exist or is disabled. |
| 3 | Configuration error: syntax error, unknown key, wrong type, out-of-range value. |
| 4 | I/O or resource error: another **import**, **rebuild** or **remove** is running on the same data directory, configuration file unreadable, data directory or index cannot be created or opened, address cannot be bound, a backup could not be written or verified or would overwrite an existing file. |

Termination by an unhandled signal (for example SIGKILL or SIGHUP) has the usual status of that signal.

# ENVIRONMENT

No environment variables are consulted by dksearch itself.

# FILES

dksearch.toml (any name, passed with **--config**)
: Configuration file. There is no default search path.

*data_dir*/index.db
: The search index (SQLite, written in WAL mode), with companion files `index.db-wal` and `index.db-shm` while open. *data_dir* is `storage.data_dir`, default `data`, created with parents if missing. The index is derived data: delete it freely and run **rebuild**.

*data_dir*/api-keys.toml
: The hashes of the API keys, with their names and collections. Mode 0600; a file that others can read is refused (no key works until it is fixed). Created by **api-key add**.

*data_dir*/admin-secrets.toml
: The administration credential hashes (default location; see `admin.secrets_file`). Mode 0600. Created by **admin-token** or **admin-password**. Back it up with your other secrets; losing it just means creating new credentials.

*data_dir*/state.db
: Document metadata and provenance, and the record of import runs with their resume positions. This is source-of-truth data: it cannot be rebuilt from anything else. Created by **import**. When a newer version of dksearch upgrades its layout, the old file is first copied to `state.db.pre-vN`.

*data_dir*/content.db
: The retained text of imported documents, compressed, with a checksum for each. Also source-of-truth data. Created by **import**. Upgraded the same way as `state.db`.

# CONFIGURATION

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
| Key | Type | Default | Description |
|---|---|---|---|
| server.address | String | 127.0.0.1 | IPv4 or IPv6 address literal to listen on. Host names are not accepted. |
| server.port | Integer | 8080 | TCP port, 1-65535. |
| server.max_header_bytes | Integer | 8192 | Largest request head accepted, 1024-65536. Larger requests get status 431. |
| server.request_timeout_ms | Integer | 10000 | Time allowed to receive a complete request head, and the idle time allowed between requests on a kept-alive connection. 100-600000. |
| server.write_timeout_ms | Integer | 10000 | Time allowed to send one response. 100-600000. |
| server.max_connections | Integer | 256 | Simultaneous connections, 1-65535. Further connections are closed immediately. |
| server.max_requests_per_connection | Integer | 100 | Requests served on one connection before it is closed, 1-10000. |
| server.shutdown_grace_ms | Integer | 5000 | On SIGINT or SIGTERM, how long requests already being handled may take to finish, 0-600000. |
| server.access_log | String | none | `stderr` or a file path (appended to): write one line per request to the public listener's access log. Off when absent. See PRIVACY for exactly what a line holds. |
| admin.* | - | - | The administration listener accepts the same keys as `server.*` (default port 8081, loopback) and the keys below. It must not share an address and port with `server`. |
| admin.secrets_file | String | `data_dir`/admin-secrets.toml | File holding the credential hashes. Must not be readable by group or others. |
| admin.session_idle_minutes | Integer | 30 | A sign-in session ends after this much inactivity, 1-1440. |
| admin.session_max_hours | Integer | 8 | A sign-in session ends this long after it began, however active, 1-168. |
| admin.actions | Boolean | false | Let the administration interface start and cancel imports of configured sources, run the maintenance operations check, backup and remove-source (never rebuild or restore, which replace files the server is using), and add, edit, enable, disable and delete sources by rewriting the `[[source]]` tables of the configuration file (the server must have been started with `--config`; the file is validated as a whole first, the previous version is kept as `FILE.bak`, and the change takes effect at once without a restart). Off: the interface is strictly read-only. |
| admin.backup_dir | String | none | A folder you control where the administration interface may write backups (a new `dksearch-DATE` subfolder per backup, holding `state.db` and `content.db`). Unset: backups from the interface are off (the `backup` command works regardless). The interface never writes anywhere else, and there is no way to give it another path. |
| admin.zim_dir | String | none | A folder you control where the administration interface may download ZIM files from the Kiwix library (ZIM files page: search, confirm, download; verified against the library's SHA-256 before it gets its name; interrupted downloads continue). Unset: downloads are off. Needs `admin.actions`. Add the file afterwards as a source of kind `zim`. Before a download the page shows the free space in the folder, and a file that does not fit (its size, less what is already fetched, plus 256 MiB to spare) is refused with the numbers. When the file is verified and the server has a configuration file it can edit, the file is added as a `zim` source named after it (`wikipedia_en_all_maxi_2026-01.zim` becomes `wikipedia-en-all-maxi`, numbered if taken) and applies at once; importing it is still a separate step you start. |


The **ZIM files** page of the administration interface browses the Kiwix library like the Kiwix desktop application: filters for language (with names and counts) and category, pictures (any, with pictures, text only), videos and sort order (newest, title, smallest, largest; within the page shown), then a confirmation that shows the free space before the download. Nothing is asked of the library until Show is pressed. Links to library.kiwix.org, the plain download listing and the form for adding a file already in the folder are always shown, and are all that is shown when the library cannot be reached.
| admin.cookie_secure | Boolean | false | Add `Secure` to the session cookie. Set it when a reverse proxy serves the interface over HTTPS. |
|---|---|---|---|
| search.fuzzy | String | auto | Typo tolerance without anyone asking for it: `auto` repeats a search that finds fewer than three results with every word of four or more letters also matching words one typo away (and tells the person, with a link to search exactly as typed); `always` does that for every search; `off` leaves it to `word~` in the query. See SEARCH SYNTAX. |
| search.query_syntax | String | advanced | `advanced`: the query language (AND, OR, NOT, parentheses, `-word`, `prefix*`, `word~`, `"a b"~5`). `simple`: every word is plain text and only quotes make a phrase, as in earlier versions. |
| search.recency_boost | Integer | 0 | Newer documents rank up to this many percent higher, 0-1000 (0 = off). A document's date is when it was modified or published, otherwise when it was indexed. The boost shrinks smoothly with age: it halves for every `search.recency_half_life_days`. |
| search.recency_half_life_days | Integer | 365 | Age in days at which the newer-first boost has halved, 1-36500. |
| search.stop_words_file | String | none | A file of stop words: one word per line (or several separated by spaces or commas; lines starting with `#` are comments). These words are left out of searches (`the history of Rome` searches `history` and `Rome`) unless the search would be left with nothing; words inside quotes are never dropped. It is applied when a search is read, not to the index, so changing the file needs only a restart, not a rebuild. Letter case is ignored for ASCII letters. |
| search.synonyms_file | String | none | A file of synonym groups: one group per line, members separated by commas (`car, auto, motor car`). A plain word of a search then also matches the other members of its groups (a member of several words matches as a phrase). Applied when a search is read, so no rebuild is needed. A line with fewer than two members, or a quote in a member, stops the server at start with the line number. |
| search.default_collection | String | (none) | A collection the search page searches when the visitor has ticked no source; the page says so and links to *Search all sources* (`sources=all`, kept when paging). Ignored for a visitor who cannot see all of it. The API is not affected (it searches every source the caller may see unless `source` is given). Must name a defined collection. Read at start. |
| search.peer_cache_seconds | Integer | 30 | How long (seconds) a peer's good answer is reused when the same question (query, kind, page size) is asked again, so repeating a search or coming back to it does not ask the peers again. Only answers that worked are kept (at most 200); a peer's own changes show after this time. 0 turns it off. Read at start. |
| search.retrieve_cache_mb | Integer | 128 | Memory (MiB) for the passages of recently retrieved documents (and the page maps of PDF copies), kept between `/api/v1/retrieve` requests so asking about the same documents again does not read and split them again. An entry is replaced when its document changes. 0 turns the cache off. Read at start. |
| search.chunk_index_min_kb | Integer | 64 | Documents with at least this much text (in KiB) also get their passages (chunks of about 1200 characters, cut at paragraphs and headings) indexed, so `/api/v1/retrieve` can find a passage inside a very large document such as a book. 0 turns it off. Applies to documents imported or rebuilt after it is set (`dksearch rebuild` fills the passage index for existing documents). The passage index holds only the words, not a second copy of the text. |
| search.query_timeout_ms | Integer | 5000 | Longest a search may run, 0-60000 milliseconds (0 = no limit, which is not recommended). Very common words over a very large index take seconds to rank, because every matching document is scored; a search that runs past this is stopped and answers HTTP 503 `search_timeout` ("try more specific words") instead of tying up a connection until the connection's own deadline (`server.write_timeout_ms`) cuts it off. Keep it below that deadline. |
| search.regex | Boolean | true | Offer the regular-expression filter on the public search page and API, and on the administration query-testing page. It needs `content.db` (it reads the stored texts), so it is off until something has been imported; restart after the first import. See the notes below. |
| search.regex_max_pattern | Integer | 200 | Longest regular expression, in bytes, 1-2000. |
| search.regex_max_candidates | Integer | 200 | Most candidate documents whose text is checked per query, 1-10000. |
| search.regex_budget_ms | Integer | 500 | Wall-clock budget for one regex query, 10-60000 milliseconds. When it runs out the results so far are returned and marked as possibly incomplete. |
| search.regex_max_steps | Integer | 100000 | Matching steps allowed per document, 1000-10000000. A pattern that exhausts them on several documents is refused as too complex. Only patterns that need the backtracking engine (back-references, look-around, atomic groups, possessive quantifiers) can: the others run in linear time, so `(a+)+$` is no longer a problem. |
| search.regex_concurrency | Integer | 2 | Regex queries that may run at once, 1-64; others wait a moment and then get "busy" (HTTP 429). |
| index.tokenizer | String | `unicode61` | How text is split and normalised: `unicode61` (case and diacritics folded) or `porter` (the same, plus English stemming, so "running" matches "run"). The index keeps the tokenizer it was built with; after changing this setting **serve** and **import** refuse the old index until **rebuild** recreates it. |
| storage.data_dir | String | data | Directory for the index and other state. Must not be empty. |
| source | Array of tables | none | Optional. Each `[[source]]` defines one connector instance; see Sources below. |


Sources

The administration interface has a Settings page for the `[search]`, `[server]` and `[admin]` settings that are safe to change from it (typo tolerance, query syntax, time limit, regex limits, addresses and limits of the public server, session lengths, backup folder). A save is checked as a whole before it is written, keeps the old file as `.bak`, and applies after a restart. Sources have a labelled field for every option on their own pages.

Each `[[source]]` table has these keys. Any other key is an option of the connector named by `kind` and is validated by it, so a misspelled option is an error.

| Key | Type | Default | Description |
|---|---|---|---|
| name | String | required | Unique name, 1-64 characters of `a-z`, `0-9`, `_` and `-`, starting with a letter or digit. Resume positions are kept per name, and it becomes the `connector` of each document, so renaming a source makes it start afresh and its old documents stay under the old name. |
| kind | String | required | Connector type. This version knows `files`, `gutenberg`, `zim`, `wikipedia`, `feeds`, `crawl` and `archive` (the last four only in builds that include them). |
| enabled | Boolean | true | A disabled source stays in the file but is never run. |
| retain_text | Boolean | true | Keep each document's text so the index can be rebuilt without reading the source again. Set false for a source whose terms forbid keeping its text; its documents are then skipped by **rebuild**. |
| rights | String | connector default | Override the redistribution flag (`unknown`, `allowed`, `restricted`, `forbidden`) of every document from this source. Defaults are conservative guesses, not legal advice; the decision is yours. Only documents that are added or changed afterwards pick it up; unchanged ones keep the flag they were stored with. |
| boost | Integer | 100 | How much this source's results count in the ranking, in percent, 1-1000. 100 changes nothing; 150 ranks its results half as high again, 50 halves them. It multiplies the relevance score, so it reorders results by relevance (and the relevance part of other orders) but does not add or hide anything. Settable from the source's page in the administration interface. |
| schedule | String | none | Import this source again by itself while `serve` runs (needs `admin.actions = true`): `hourly`, `daily`, `weekly`, or a number with `m`, `h` or `d` (`30m`, `6h`, `2d`; from 10 minutes to a year). It is counted from when the source's last import started; a source that never ran is due at once, and one that failed is tried again after one interval. Only one import runs at a time, so when several are due the one longest overdue goes first and the others wait. Imports started this way resume like any other and are listed on the Jobs page. Without it, import by hand or with a timer (`docs/deploy/README.md`). |


Kind `files` indexes `.txt` and `.md` files (and `.pdf` files with `pdf_text`; extensions are case-insensitive) under a directory, including subdirectories:

| Key | Type | Default | Description |
|---|---|---|---|
| path | String | required | The directory to index, absolute or relative to the working directory. |
| max_file_bytes | Integer | 4194304 | Largest file accepted, 1-67108864. Larger files are skipped, never truncated. |
| language | String | none | Language tag stored on every document, such as `en` or `pt-BR`. |
| pdf_text | Boolean | false | Also index `.pdf` files, by running the external program **pdftotext** (package `poppler-utils`; on Ubuntu `sudo apt install poppler-utils`). See below. |
| media | Boolean | false | Also index audio and video files by their tags, through the external program **ffprobe** (package `ffmpeg`; on Ubuntu `sudo apt install ffmpeg`). See below. |
| office | Boolean | true | Also index Word (`.docx`), Excel (`.xlsx`), PowerPoint (`.pptx`), OpenDocument text, spreadsheet and presentation (`.odt`, `.ods`, `.odp`) and `.epub` files by their text and their own properties. No outside program is needed. See below. |
| code | Boolean | false | Also index source code and configuration files as text (`.zig`, `.c`, `.h`, `.cpp`, `.rs`, `.go`, `.py`, `.js`, `.ts`, `.java`, `.sh`, `.sql`, `.toml`, `.yaml`, `.json`, `Makefile`, `Dockerfile` and many more). The file name is the title; each file gets the tags `code` and its language (`tag:python`) and a `code_language` field. Directories named `node_modules`, `vendor`, `build`, `dist`, `target`, `zig-out` and `__pycache__` are not entered; hidden files and folders never are. The size limit and the UTF-8 check apply as for text files. |
| html | Boolean | false | Also index `.html` and `.htm` files as web pages. See below. |
| pdf_workers | Integer | 4 | How many **pdftotext** programs run at once, 1-32, a few files ahead of the one being indexed. Raise it for a large library (a few below the number of CPU cores); each worker can hold up to `max_file_bytes` of text. The results are the same for any value. |
| max_pdf_bytes | Integer | 536870912 | Largest PDF file accepted, 1-8589934592 (8 GiB); larger ones are skipped. The file is read by **pdftotext** itself, so this is not memory held by dksearch, only a bound on what one file may cost. |
| pdf_timeout_seconds | Integer | 120 | How long **pdftotext** may take on one PDF, 1-3600. A file that takes longer is refused. Raise it for very large books. |
| serve_originals | Boolean | false | Let the document viewer offer the original file of each document from this source, so the browser can open it. See below. |


PDFs with `pdf_text = true`: each PDF is read by `pdftotext -layout` and the text is indexed with the page breaks kept as blank lines. A PDF with no text layer (a scan) is skipped and counted as `no_text`; damaged or encrypted ones are refused. The program runs with a `pdf_timeout_seconds` limit per file and its output is limited by `max_file_bytes`; several run at once (`pdf_workers`); a PDF itself may be up to `max_pdf_bytes` (512 MiB by default). If **pdftotext** is not installed the source fails with a message saying so. This only reads the text layer: it keeps no page numbers or structure, and it does no OCR. Tools such as MinerU or Docling convert PDFs far better (tables, formulas, scans); their Markdown output can be indexed as ordinary `.md` files with this same connector.

Office documents and ebooks with `office = true`: a `.docx`, `.odt` or `.epub` file is a zip of XML and HTML parts, read in memory (nothing is written to disk) with limits against zip bombs (a part over `max_file_bytes` of text is refused as a whole; a part that shrank by more than 1000 times is refused). Only text is taken: paragraphs, headings, tabs, line breaks, list items, table cells (tab separated) and, for Word, footnotes and endnotes; tracked deletions, field codes, images, styles and macros are not. The title, author, language and date come from the document's own properties (Word `docProps/core.xml`, OpenDocument `meta.xml`, the EPUB package file), the title falling back to the first line of text; an EPUB's chapters are read in the book's reading order. The documents have the file kind `document` (`type:document`). Old binary `.doc` files and encrypted documents are not zips and are refused; scans have no text and are skipped as `no_text`.

Document properties are read too, from Office `docProps` (core, application and custom properties, which is where SharePoint-style columns land), OpenDocument `meta.xml`, and, for PDFs, the document information that `pdfinfo` (poppler-utils, installed with `pdftotext`) prints: the title and author become the document's, each keyword a tag (`tag:budget`), and the subject, category, description, last-modified-by, application (the program that made the file), company, manager, and each custom property become fields (`subject`, `category`, `description`, `last_modified_by`, `application`, `company`, `manager`, and the property's own name lower-cased with `_` for spaces) shown with the document. The subject, category, description and keywords are also added to the end of the searchable text as short lines, so a search finds a file by them even when its body never says them. A spreadsheet's text is its sheet names, then each row on a line with the cells separated by tabs (numbers as stored; dates appear as the numbers Excel keeps); a presentation's is each slide's text in order, then the speaker notes. At most 32 tags and fields are kept per document.

HTML files with `html = true`: the page's text, with scripts, styles and markup dropped, and its `<title>` as the document title. Files must be valid UTF-8 (a page in another encoding is refused), at most `max_file_bytes`.

Audio and video with `media = true`: files ending in `mp3`, `m4a`, `m4b`, `aac`, `ogg`, `oga`, `opus`, `flac`, `wav`, `wma`, `mp4`, `m4v`, `mkv`, `webm`, `mov` or `avi` become documents whose text is what **ffprobe** reports: title (else the file name), artist, album artist, album, composer, genre, date, track, comment, and the kind and duration, plus a lyrics tag if the file has one. The same values are kept as fields, so `meta.artist:davis`, `meta.genre:jazz`, `type:audio` or `type:video` narrow a search, and `size:` is the size of the media file. A subtitle or lyrics file next to a media file (`talk.srt`, `talk.en.srt`, `talk.vtt`, `song.lrc`; up to three, each up to 2 MiB) is not a document of its own: its words, without timestamps, styling or cue numbers, are added to the media file's text, so a search finds what is said or sung. A file **ffprobe** cannot read is refused. Each probe has a 30 second limit. Nothing here transcribes speech; that is on the roadmap as an optional step. The files are listed in the viewer but not played: serving them for playback is also on the roadmap.

Original files with `serve_originals = true`: the viewer page of a document gets an "Open the original file" button (address `/doc/ID/file` on the search server). A file is read only from inside the source's `path` (symbolic links are resolved first, so a link cannot lead out of it), and only up to 64 MiB. PDFs and common images (PNG, JPEG, GIF, WebP, BMP) open in the browser; text, Markdown and HTML files are sent as plain text, never as a page; anything else, including SVG, is a download. Turn this on only for folders whose files anyone who can reach the search page may read. The setting is read when the server starts.

Markdown files that carry pictures inline (`![](data:image/png;base64,...)`, as converters such as Docling write them) are indexed without the pictures, which are replaced by short references (`![](dkimg:N)`). With `serve_originals = true` the viewer shows those pictures (PNG, JPEG, GIF and WebP only) at `/doc/ID/image/N`, read from the original file, and `/api/v1/retrieve` lists the pictures that belong to each passage. Without it the pictures are simply not shown. The size limit (`max_file_bytes`) applies to a Markdown file after the pictures are removed (the file itself may be up to 64 MiB).

Files are read in sorted path order. Symbolic links are never followed. Hidden files and directories (names starting with `.`) are skipped. Files that are not valid UTF-8, contain a NUL byte, or are empty are skipped. The title is the first Markdown `# heading` in a `.md` file, otherwise the file name without its extension. The document id is derived from the source name and the path relative to `path`.

Example:

    [[source]]
    name = "my-notes"
    kind = "files"
    path = "/home/me/notes"
    language = "en"

Kind `gutenberg` indexes books from Project Gutenberg. It never uses the network: download the catalog (`pg_catalog.csv`, which Project Gutenberg publishes for this purpose) and the books yourself, for example from a mirror, and point the source at them.

| Key | Type | Default | Description |
|---|---|---|---|
| catalog | String | required | Path of the catalog CSV file. |
| books | String | required | Directory holding the book text files. |
| language | String | none | Only import books in this language, such as `en`. A book listed in several languages matches any of them. |
| max_file_bytes | Integer | 16777216 | Largest book accepted, 1-67108864. Larger books are refused, never truncated. |


Only catalog rows of type `Text` are used. A book with catalog number N is looked for as `pgN.txt`, `N-0.txt`, `N.txt`, `N.txt.utf8` or `pgN.txt.utf8`, directly in `books` or in a subdirectory `N/` of it. A catalog row with no local file is skipped, which is normal when only part of the collection was downloaded. A book that is not valid UTF-8, contains a NUL byte, is too large or has no text after trimming is refused and counted as rejected; it is not converted. The Project Gutenberg license header and footer (the text outside the `*** START OF` and `*** END OF` lines) is not indexed; a file without those lines is indexed whole. The title, authors, language, subjects and bookshelves come from the catalog. Each document records the catalog number, a link to `https://www.gutenberg.org/ebooks/N`, the source dataset "Project Gutenberg", and rights: the license "Project Gutenberg License", its URL, an attribution line, and redistribution `restricted`. The id is derived from the source name and the catalog number. A saved position is the number of catalog rows handled, so resuming needs the same catalog file; a malformed catalog fails the job instead of being skipped.

Example:

    [[source]]
    name = "gutenberg-en"
    kind = "gutenberg"
    catalog = "/data/gutenberg/pg_catalog.csv"
    books = "/data/gutenberg/books"
    language = "en"

Kind `wikipedia` indexes the articles of a Wikipedia (MediaWiki) XML dump such as `enwiki-YYYYMMDD-pages-articles-multistream.xml.bz2`. It never uses the network: download the dump yourself, from https://dumps.wikimedia.org/ or a mirror, and read the terms there.

| Key | Type | Default | Description |
|---|---|---|---|
| dump | String | required | Path of the dump: a `.bz2` file (multistream or single stream) or a plain `.xml` file. |
| language | String | `en` | Language tag stored on each document. |
| url_base | String | `https://LANGUAGE.wikipedia.org/wiki/` | Prefix of article URLs; must start with http:// or https:// and end in `/`. |
| dataset_version | String | none | A label for the dump, such as its date, stored on each document. |
| max_article_bytes | Integer | 8388608 | Largest article text accepted, 1-67108864. Larger articles are refused, never truncated. |


Only articles are indexed: pages in the main namespace (0) that are not redirects and have text. Other namespaces (talk, user, template, category, file pages) and redirects are skipped. The wikitext is converted to plain text by a deliberately modest converter, so it is good for searching, not a faithful rendering: templates (including infoboxes), tables, references, comments, galleries and math are dropped; links keep their label; bold, italic, list and heading marks are removed; and everything from a "References", "External links", "See also", "Notes", "Further reading" or similar level-2 heading to the end is dropped. The id is derived from the source name and the page id; the revision is the revision id, so a newer dump updates changed articles and skips unchanged ones. Each document records the dataset "Wikipedia", the dump label, the article URL, the revision timestamp as modified date, and rights: the license `CC-BY-SA-4.0` with its URL, an attribution line pointing to the article's page history, and a note about the older GFDL license. Wikipedia's text is free to reuse only under those license conditions, which include attribution and share-alike; the search results show the source so that attribution is possible. Images and other media are not imported.

The position is saved after every bzip2 stream (Wikipedia's multistream dumps hold about 100 pages per stream) or, for a plain XML file, every 100 pages, so an interrupted import of a very large dump resumes close to where it stopped. A single-stream `.bz2` file cannot be entered in the middle and starts over each time, skipping unchanged pages. A truncated or damaged dump fails the job; what was committed before the damage stays.

Example:

    [[source]]
    name = "wikipedia-en"
    kind = "wikipedia"
    dump = "/data/wikipedia/enwiki-20260101-pages-articles-multistream.xml.bz2"
    dataset_version = "20260101"

Kind `zim` indexes the articles of a ZIM file, the offline-content format of the Kiwix project (Wikipedia, Wiktionary, Stack Exchange, project documentation and many other sites packaged as one file; downloads at download.kiwix.org). It never uses the network: download the file yourself and point the source at it. The reader is written for dksearch on Zig's own xz and zstd decoders, not on libzim, and treats the file as untrusted input.

| Key | Type | Default | Description |
|---|---|---|---|
| path | String | required | The `.zim` file (format version 5 or 6). |
| language | String | none | Language tag stored on each document. |
| url_base | String | none | Where the articles can be read, starting with http:// or https:// and ending in "/", for example the address of a kiwix-serve (`http://localhost:8080/content/wikipedia_en_all_maxi/`). Each result then links to that address plus the article's path. Without it each article gets an address of the form `zim://SOURCE/PATH`, and the search server shows the article itself from the ZIM file (see `serve_articles`). |
| serve_articles | Boolean | true | Show this file's articles, pictures and plain-text pages from the file itself at `/zim/SOURCE/PATH`, so results open in the browser. Article HTML is made safe first (no scripts, styles, frames or forms), links inside the file and its pictures keep working through the same address, links to other sites stay, and stylesheets and scripts of the file are never served. Set false to stop serving the file. The setting is read when the server starts. |
| max_article_bytes | Integer | 4194304 | Largest article text indexed, 1-67108864; larger ones are skipped. |
| max_cluster_bytes | Integer | 134217728 | Largest decompressed cluster accepted, 1-1073741824. |


Entries of the content namespace (`C`, or `A` in older files) of type HTML or plain text become documents; redirects, images, scripts, stylesheets and metadata do not. HTML is converted to text like feed entries. The entry's own title is used, else the page's `<title>`, else its path. The library's `Title` metadata is recorded as the dataset. The directory is read once to find the articles (a few seconds per million entries and about 12 bytes of memory per article), then the file is processed cluster by cluster so each compressed block is decompressed once. An interrupted run resumes at the next cluster. Rights are `unknown`: Kiwix files package content that keeps its original licence (often CC BY-SA); check the file's metadata. Progress is shown as the share of clusters handled.

Example:

    [[source]]
    name = "wiki-offline"
    kind = "zim"
    path = "/data/wikipedia_en_all_maxi_2026-01.zim"

Kind `feeds` indexes RSS 2.0, RSS 1.0 (RDF) and Atom 1.0 files. It never uses the network: fetch the feeds yourself (a scheduled `curl` into a directory works, see `docs/deploy/README.md`) and point the source at them.

| Key | Type | Default | Description |
|---|---|---|---|
| path | String | required | A feed file, or a directory of feed files (`.xml`, `.rss`, `.atom`, `.rdf`, in subdirectories too; hidden entries and symbolic links are skipped). |
| language | String | the feed's own | Language tag for every entry, overriding the language a feed declares. |
| max_file_bytes | Integer | 16777216 | Largest feed file accepted, 1-67108864. Larger files are refused. |


Each entry becomes a document. Its text is the full content if the feed has one, else the summary, else the title, converted from HTML to plain text (tags removed, paragraphs kept as lines, scripts and styles dropped, entities decoded). The document id is the entry's `guid` or Atom `id`, or its link; an id that is not URL-like (for example `42`) is prefixed with the feed's link so that different feeds cannot collide. Fetching the same feed into the same file again updates entries whose text changed and skips the rest. Each document records the feed title as its source and attribution, the entry's link, author, categories and dates, and rights `unknown`: a feed does not say what you may do with its entries, so the content is treated as belonging to its publisher. A file that cannot be parsed, or an entry with no id and no link or no text, is counted as skipped, and the run continues. Only the XML encodings UTF-8, UTF-16, ISO-8859-1 and US-ASCII are understood: a feed declaring another encoding (such as windows-1252) is skipped as unparseable; convert it first. Dates before 1970 are ignored.

Example:

    [[source]]
    name = "news"
    kind = "feeds"
    path = "/srv/feeds"

Kind `dump` indexes archives and data dumps that you already have on disk. It never uses the network and runs nothing. `format` chooses what is read, and `path` is one file or a folder searched (with its subfolders; hidden entries and symbolic links skipped) for files of that format:

- `zip`: the `.txt`, `.md`, `.html` and `.htm` files inside `.zip` archives; each is a document named `ARCHIVE!ENTRY`. Parts are read in memory with the same limits against zip bombs as Office files.
- `warc`: `.warc` and `.warc.gz` web archives (Common Crawl, Archive Team, `wget --warc-file`, Heritrix, ...). Each archived HTTP response with status 200 and HTML or plain text becomes a document at its address (chunked transfer and gzip content encoding are undone; other encodings, other media types and non-UTF-8 pages are skipped with the reason shown). The file is read as a stream; gzip files with one member per record are read to the end.
- `stackexchange`: a Stack Exchange data dump's `Posts.xml` (unpack the `.7z` first; any folder containing a `Posts.xml` is found). Every question and every answer is a document: a question by its title and body with its tags (`tag:lamps`), an answer as "Answer: QUESTION TITLE" with its body and `accepted` set when it was the accepted one, plus `score` and the author's display name. Links are `SITE/q/ID` and `SITE/a/ID`, where the site is `site_url` or, if the folder is named like the site (`cooking.stackexchange.com/Posts.xml`), that name. The text is CC BY-SA and says so.
- `export`: files made by `dksearch export` (`.dksearch.jsonl`, or `.dksearch.jsonl.zst`): each line is one document with its full text, address, title, language and type. Pages are named by their address, so importing a newer export updates the same pages; addresses of local files (`file://`) are dropped, so nothing copied can pose as a web page.
- `reddit`: submissions and comments as JSON lines (`.jsonl`, `.ndjson`, `.json`, or `.zst` compressed, as in the Pushshift and Academic Torrents dumps). A submission is its title and text (its address when it is a link), a comment its text; posts and comments removed or deleted are skipped, adult posts unless `include_nsfw` is true, and `subreddits` (comma separated) and `min_score` narrow what is kept. Each gets `tag:` its subreddit and a `score` field. Dumps made with `zstd --long` need `zstd_window_mb` (up to 2048) of memory for the decompression window.

The resume position is the last finished file: a restart repeats the file it was in (unchanged documents are skipped, so that costs time, not duplicates). Options: `path`, `format` (required), `language`, `max_file_bytes` (largest text of one document, default 4 MiB), `site_url`, `subreddits`, `min_score`, `include_nsfw`, `zstd_window_mb`.

Kind `crawl` fetches the web pages listed in a file and indexes each as one document. It is the only connector that uses the network, and it does nothing unless a source of this kind is configured and imported. It is built to be polite: it reads `robots.txt` (RFC 9309) before any page of a host and never requests a page the file disallows; it keeps at least `delay_ms` between requests to one host, one request at a time (a larger `Crawl-delay` in `robots.txt`, up to 60 seconds, is honored); it sends exactly the user agent you configure; it follows redirects only within the same site (a leading `www.` is ignored), checking `robots.txt` again for each step, at most 5; and every request has a deadline and a size cap. Addresses found on pages are tidied before they are followed: the fragment, a default port, repeated slashes, session parameters (`jsessionid`, `PHPSESSID`) and tracking parameters (`utm_*`, `fbclid`, `gclid`, ...) are removed and the remaining query parameters are put in order, so one page has one address. Addresses that lead nowhere new are not followed (and are counted in the report as traps): a path that repeats itself, one more than twelve segments deep, one longer than 2000 characters, search-result and comment-reply links, a wiki's edit, history and `Special:` pages. Within a seed, the pages near the top of the site (short paths, no query) are fetched first, so that when `max_pages` runs out it is the deep tail that is left. SUGGESTING A SITE. When the owner is signed in, a search page also has *A site missing from these results?* under the results (also when there are none): a text area for one address or a list, a line each (Ctrl+Enter sends; at most 50 at a time), each added to `suggested-sites.txt` in the data directory (one address a line, only plain `http://` and `https://` addresses with a domain name) and kept as a good answer for that search in `feedback.jsonl`. The file is a crawl seeds file: give a crawl source `seeds_file = "DATA_DIR/suggested-sites.txt"` (with `max_depth = 2` or so and a `schedule`) and the sites are indexed on its next run (or press *Run now* for it in the administration interface); with `watch_seeds = true` on that source the next run starts by itself two minutes after the last addition. Until the site is found by that search, `dksearch eval` lists it as not in the first 100.

FEEDBACK. When the owner is signed in (the Login button), every result on the search page has a small *good* and *bad* button. A mark is sent to the server and added to `feedback.jsonl` in the data directory, one line for each: `{"query": "how to program in c", "url": "https://...", "grade": 1, "time": 1763600000}`; the same button again takes the mark back. Visitors see no buttons and cannot write: the server refuses (403) a mark that does not come from the owner. Nothing is sent anywhere else. `dksearch eval` reads the file as it is, alone or together with a file of your own (`cat golden.jsonl feedback.jsonl > all.jsonl`): the last mark for a query and address wins, and a result marked bad is counted as unwanted when it comes up in the top k (the *Bad@k* column). A judgments file may also say `"irrelevant": ["https://..."]` beside or instead of `"relevant"`.

WORD FORMS (experimental, off by default). With `[search] word_forms = true` a plain word of five or more letters is also searched as the forms of it that the index has: "program" also finds "programming" and "programmers". It is done in the query, so the index does not change. On the test queries it made the ranking worse (see docs/decisions/0063-word-forms.md), because a page that repeats one word in many forms outranks a page that matches all the words, so it is off; it is kept for those who want it. A quoted phrase, a word with `-`, a word with a `field:` and words of fewer than five letters stay as typed.

QUESTIONS. Question and filler words (`how`, `what`, `why`, `when`, `where`, `which`, `who`, `is`, `are`, `do`, `can`, `to`, `in`, `of`, `a`, `the` and a few more) are not required in a search that has other words: "how to program in c" is a search for `program` and `c`, since a page about the thing rarely says "how". The results page says which words were left out. A quoted phrase, a `title:` word and a word with `-` are never left out, and a search of nothing but such words is searched as typed.

SEARCH RESULTS. An ordinary search is about pages: pictures (indexed with `index_images`) are left out of it and are found with the Images button, or by asking for them (`kind:image`, `mime:image/*`, `ext:png`). Pages in a language other than those the browser asks for (its `Accept-Language`) rank lower, by a factor of 0.3; they are not hidden, so a page nobody translated stays. A page's language is the `lang` of its `<html>` element (or the source's `language` option), and for pages stored without one the first part of the address says it (`/ja/`, `/zh-CN/`; codes that are also ordinary words, such as `it`, `no` and `id`, are not taken for languages). `[search] per_domain` (default 3) is the most results one site has in a search, so one site does not fill the page; a search that names a site (`domain:example.org`) shows all of it.

RENDERING. Some sites send an empty page and build the text with JavaScript. For such a site (and only for the sites you list in `render_hosts`) the crawler can hand the page to a headless browser instead of fetching it itself. This is a hack with real costs, so it is off unless both `render_command` and `render_hosts` are set, and it is bounded: a time limit per page (the program is killed when it runs out), a cap on the size of the output, and a cap on the pages rendered in a run. `robots.txt`, the delay between requests and the backoff apply before a page is rendered, as for any page. It is not a way round a block: a page that is a bot check or an access block ("Just a moment...", "Verify you are human", ...) is skipped and counted as blocked, and a site that blocks crawlers stays blocked. A browser runs the scripts of the page and loads what they ask for, including from your own network, so list only sites you trust and prefer a browser in a container or a sandbox; do not give it `--no-sandbox` unless it already runs in one. Example for a source:

    render_command = "/usr/bin/chromium"
    render_args = "--headless=new --disable-gpu --virtual-time-budget=8000 --dump-dom"
    render_hosts = "docs.example.org"

A site that answers 429 or 503 is slowed down for: its `Retry-After` is obeyed (up to two minutes), a further wait is added to every request to it (doubled at each refusal, halved after a run of good answers, at most a minute), the page is asked again up to twice more, and a site that asks to be left alone for longer than two minutes is not asked again for the rest of the run. A `robots.txt` that cannot be fetched (network error, server error, oversized, or redirected to another site) disallows that host for the run; an answer of 4xx means it has no rules. From each URL listed it follows links to other pages of the same site, down to `max_depth`, and a line of the form `sitemap URL` in the seeds file makes it fetch the pages that sitemap lists. By default it never leaves the site of the URL it started from (see `follow_external`), and a page that says `<meta name="robots" content="noindex">` is not stored (`nofollow` stops its links being followed, as does `rel="nofollow"` on a single link).

| Key | Type | Default | Description |
|---|---|---|---|
| user_agent | String | required | The `User-Agent` header, 1-200 printable ASCII characters starting with a product name, for example `mysearch/1.0 (+https://example.org/about)`. There is no default: choose a name and a way for site owners to reach you. The product token (up to the first `/`, space or `(`) is what `robots.txt` groups are matched against. |
| seeds_file | String | required | A text file with one entry per line: an absolute `http://` or `https://` URL, or `sitemap URL` for a sitemap or sitemap index (XML, plain or gzip-compressed (`sitemap.xml.gz`, at most 10 MiB once decompressed); a sitemap can only name pages of its own site, and its pages are fetched without following their links). Blank lines and `#` comments are skipped; lines that are not usable URLs (no host, other schemes, credentials in the URL) are ignored. Several seeds may share a site. At most 10000 URLs are read. Re-read at every run. |
| seeds_sections | String | (all) | For a seeds file ending in `.toml` with sections: the section names to use, comma-separated. |
| seeds_skip | String | (none) | For a TOML seeds file: the section names to leave out, comma-separated (for example `Adult`). |
| delay_ms | Integer | 1000 | Minimum milliseconds between two requests to the same host, 100-3600000. |
| workers | Integer | 8 | How many seeds are crawled at once, 1-64. Each runs in its own task with its own connection; they share the table of sites, the set of addresses already seen and the page budget. A site is only ever asked by one worker at a time and requests to it stay at least `delay_ms` apart (more if its `robots.txt` asks), so more workers speed up a crawl that spans many sites without hitting any single site harder. The resume position is the last seed before which every seed is finished, so an interrupted crawl repeats at most the seeds that were in progress. |
| window | Integer | 100 | How many seeds are crawled together, 0-10000 (0: all of them). Inside a window the crawl is breadth-first: every seed's first page is fetched, then every page one link away, then two, and so on, so a window reaches many sites early instead of one site deeply. When a window is finished its seeds are finished and the resume position moves past them; an interrupted crawl repeats at most its current window (pages that did not change are skipped by the pipeline). A smaller window resumes closer to where it stopped; a larger one spreads a limited page budget over more seeds. |
| validators_file | String | (none) | A file where the crawler keeps the `ETag` and `Last-Modified` the servers gave for the pages at the depth limit (the last level, which follow no links; with `max_depth = 0` every page). The next run asks for those pages conditionally (`If-None-Match`, `If-Modified-Since`) and a server that answers 304 (not modified) costs no download and nothing is stored again. Pages with links to follow are always fetched in full, since a 304 has no links in it. The file is tab-separated text (`URL`, `ETag`, `Last-Modified`), replaced atomically at the end of a run; a missing or damaged file just means everything is fetched in full. Pages this run did not reach keep their earlier validators. |
| recrawl_adaptive | Boolean | false | With `validators_file`: recrawl each page at the depth limit on its own schedule (see above). |
| recrawl_min_hours | Integer | 6 | The shortest interval of a page that keeps changing, 1-720. |
| recrawl_max_days | Integer | 60 | The longest interval of a page that never changes, 1-365. |
| max_depth | Integer | 3 | How many links deep to follow from each listed URL, 0-10. 0 fetches only the listed URLs. Links to other sites, to obvious non-page files (images, archives, PDFs, scripts) and `mailto:` and similar are never followed. A page is fetched at most once per run. |
| max_pages | Integer | 1000 | Most pages requested in one run (`robots.txt` not counted), 1-1000000. When it is reached the run ends normally; raise it to crawl more. The same pages are reached first next time, so this bounds a run, it does not resume a large crawl. |
| follow_external | Boolean | false | Also follow links, and redirects, to other sites, within `max_depth` and `max_pages`. Each new site gets its own `robots.txt` check and its own delay. Links to private or local addresses (localhost, names with no dot or ending in `.local`, `.internal` or `.lan`, IPv6 literals, and IPv4 addresses in private, loopback, link-local and reserved ranges) are still refused unless `allow_private_addresses` is true; this stops a public page from steering the crawler at your own network. A name that resolves to a private address is detected too: every address a host's name resolves to is checked (IPv4 and IPv6, including IPv4 mapped into IPv6), once per host, before the first request to it, for sites reached by links or redirects (not for seeds you list yourself, or links within a seed's own site). The request itself resolves the name again, so a name whose answers change between the check and the request (DNS rebinding) is not stopped: for a crawler on a network with sensitive services, also firewall it. |
| allow_private_addresses | Boolean | false | Let `follow_external` reach private and local addresses too. Seeds you list yourself are always fetched. |
| max_hosts | Integer | 100 | Most different sites (scheme, host and port) one run contacts, 1-100000; pages of further sites are skipped. |
| max_page_bytes | Integer | 2097152 | Largest response body accepted (after decompression), 1-33554432. Larger pages are skipped. |
| timeout_seconds | Integer | 30 | Deadline for one request (connect, send and receive), 1-300. |
| ca_bundle | String | builtin | Which certificates HTTPS servers are verified against: `builtin` (the Mozilla root store embedded in the program, `vendor/cacert/README.md`), `system` (the operating system's store), or the path of a PEM file. A server whose certificate does not verify is skipped; there is no way to turn verification off. |
| render_command | String | none | The absolute path of a program that renders a page: it is run as `render_command render_args... URL` (no shell), runs the page's scripts and prints the resulting HTML on its standard output, as `chromium --headless --dump-dom` does. Used only for the sites in `render_hosts`. See RENDERING below. |
| render_args | String | none | Arguments given to `render_command` before the address, separated by spaces (no quoting), for example `--headless=new --disable-gpu --virtual-time-budget=8000 --dump-dom`. |
| render_hosts | String | none | The sites whose pages are read through `render_command`, comma separated (`www.` is ignored). Needs `render_command`. |
| render_timeout_seconds | Integer | 30 | Time the program is given for one page, 5-300; it is killed after that and the page is skipped. |
| render_max_pages | Integer | 500 | Most pages rendered in one run, 1-100000; the rest of the site's pages are fetched plainly. |
| mediawiki | Boolean | false | For a listed site whose first page says it is a MediaWiki (its generator tag), take the articles from the wiki's own API (the list of all pages in the main namespace, redirects left out, 500 at a time) instead of relying on the links of the front page. The API is found from the page's edit link, or at `/api.php` and `/w/api.php`; the calls obey `robots.txt`, the delay and the backoff like any page, and a wiki that does not allow its API to crawlers is left to its links. Pages become pages at the depth limit. |
| mediawiki_max_pages | Integer | 5000 | Most articles taken from one wiki's list, 1-100000. |
| watch_seeds | Boolean | false | Import this source again when its seeds file has changed since the last import began and has been left alone for two minutes (so a batch of additions starts one import). It is started like a scheduled import: only when nothing else is running, so it never disturbs a manual import; one that began after the change counts as having read it. Meant for `suggested-sites.txt`. |
| robots_sitemaps | Boolean | false | For each listed site, also take the pages of the sitemaps its `robots.txt` names (`Sitemap:` lines; the sitemap may only name its own site; at most 5000 pages per site). They join the crawl as pages at the depth limit: fetched, their links not followed. Good for documentation sites and wikis, whose front page links to a small part of the site. |
| use_feeds | Boolean | false | For each listed site, read the feed (RSS or Atom) that its first page names (not a comments feed; on the same site) and take its newest entries (at most 100) as pages at the depth limit: new pages are found without waiting for a deep crawl to reach them. |
| report_file | String | (validators_file + `.report.tsv`) | Where the report of each run is written: a tab-separated file with a line per site (pages fetched, stored, unchanged, skipped by reason, refusals, the last error status) and a verdict in words (`ok`, `blocked by the site (403)`, `robots.txt disallows it`, `rate limited`, `unreachable`, ...). The Crawl report page of the administration interface shows it. Written when a run ends or is stopped. None when neither this nor `validators_file` is set. |
| language | String | none | Language tag recorded for every page. |


Each page becomes a document identified by its final URL (after redirects, without the fragment). HTML is converted to plain text like feed entries; `text/plain` is taken as is; other media types (PDF, images) are skipped, as are non-2xx answers. The title is the page's `<title>`. Declared encodings other than UTF-8, US-ASCII, ISO-8859-1 and Windows-1252 are skipped (Windows-1252 is read as ISO-8859-1); with no declared encoding, bytes that are not valid UTF-8 are read as ISO-8859-1. Every document records rights `unknown`: a page's content belongs to its publisher. Fetching the same URLs again replaces pages whose text changed and skips the rest (there are no conditional requests yet). Positions resume by seeds-file line: an interrupted run continues after the last finished line, repeating at most that line's own pages. A run in which not one page could be reached, because of connection failures or timeouts, ends as failed with Offline. There is no proxy support.

Example:

    [[source]]
    name = "web"
    kind = "crawl"
    user_agent = "mysearch/1.0 (+https://example.org/about)"
    seeds_file = "/etc/dksearch/seeds.txt"   # URLs, and lines like: sitemap https://example.org/sitemap.xml
    delay_ms = 2000
    max_depth = 3
    max_pages = 500

Kind `archive` indexes the metadata of Internet Archive items (title, creator, description, subjects, dates, license fields) for the items that match a search query. It does not download the items themselves, only what the Archive's search service says about them. It uses the Archive's "scrape" search interface, which pages through any number of results with a cursor, so a run can resume where it stopped. It waits `delay_ms` between requests, identifies itself with the user agent you set, gives every request a deadline and a size cap, and verifies HTTPS against the bundled certificates.

| Key | Type | Default | Description |
|---|---|---|---|
| query | String | required | An Internet Archive search query, as on archive.org's advanced search, for example `collection:gutenberg AND mediatype:texts` or `subject:lighthouses`. |
| user_agent | String | required | The `User-Agent` header, as for `crawl`: printable ASCII starting with a product name and a way to reach you. |
| max_items | Integer | 10000 | Most items indexed in one run, 1-100000000. The default is small on purpose: some collections hold millions of items. When the limit is reached the run ends normally and the next run starts from the beginning again, so raise it to index more. |
| count | Integer | 1000 | Items asked for per request, 1000-10000. The service documents a minimum of 100, but pages of 200 or fewer returned wrong results when this was tried, so the connector never asks for fewer than 1000. |
| delay_ms | Integer | 1000 | Milliseconds between requests, 100-3600000. |
| timeout_seconds | Integer | 30 | Deadline for one request, 1-300. |
| base_url | String | `https://archive.org` | Where the service is; for a mirror. Must start with http:// or https:// and have no trailing slash. |
| ca_bundle | String | builtin | As for `crawl`. |
| language | String | none | Language tag recorded for every item (the Archive's own language field is kept as `archive_language`). |


Each item becomes one document identified by its Archive identifier, with the URL `https://archive.org/details/IDENTIFIER`. Its text is the title, the creator, the description (converted from HTML to text) and the subjects. The date, the date added to the Archive, the media type, the creator as author and a `licenseurl` are recorded. Rights are `unknown`: the Archive's metadata says what an item is, not what you may do with its content, and each item has its own terms. Items without a usable identifier or without any text are counted as skipped. A request that fails after some pages were indexed ends the run as failed, with the position saved; the next run resumes from it. A first request that cannot connect ends the run as Offline. The service may return fewer items than exist, or change between pages, as the Archive notes; run again to pick up changes.

Example:

    [[source]]
    name = "prelinger"
    kind = "archive"
    user_agent = "mysearch/1.0 (+https://example.org/about)"
    query = "collection:prelinger AND mediatype:movies"
    max_items = 2000

Regular-expression search (the `[search]` table): in a query on the public page or API, a regular expression keeps only the candidate documents whose stored text matches it. The words of the query choose the candidates through the index, in ranking order, so at least one word is required; the expression is then checked against the first 1 MiB of each candidate's text (8 MiB on the administration page). It is meant for finding patterns that words cannot express (product codes, dates, phone numbers, `colou?r`), not for scanning the corpus: with the default limits at most 200 candidates are checked in at most half a second, and when a limit stops the search the response says so. Because anyone who can reach the public page can type a pattern, everything is bounded: pattern length, nesting, repeat counts, matching steps per document, candidates, time and the number of simultaneous regex queries; the administration interface uses ten times the limits. The matcher works on bytes, not characters (so `.` matches one byte of a multi-byte character) and has no Unicode properties (`\p{L}`); it is regex-zig (vendor/regex-zig, docs/decisions/0020). Set `regex = false` to switch the feature off.


# OLLAMA, MODELS AND WRITTEN ANSWERS

Models for semantic search and written answers run in [Ollama](https://ollama.com), a separate program you install and start; dksearch never starts it and never downloads a model by itself.

    [ollama]
    url = "http://127.0.0.1:11434"     # the default; also the address tried when looking for Ollama

    [answers]
    enabled = true
    model = "llama3.2:3b"              # a model Ollama has
    # passages = 6   max_chars = 12000   timeout_seconds = 120   max_per_minute = 10

**dksearch models** talks to Ollama: `list` shows its models; `pull NAME` and `remove NAME` change what is on disk (a model is often 1 to 10 GB) and only run with `--yes`. The administration interface has the same on the *AI models* page: it says whether Ollama answers (and does not start it), lists the models, pulls one as a background task that can be cancelled, deletes one after a confirmation page, and with *Use for semantic search* or *Use for answers* writes the `[embeddings]` or `[answers]` table (restart afterwards; for embeddings run `dksearch embed` to make the vectors).

With `[answers] enabled = true` the search page offers *Also write an answer with the local AI model* and the API has `GET /api/v1/answer?q=QUESTION`. The best passages for the question (the retrieval of `/api/v1/retrieve`, at most *passages* of them, cut to *max_chars* together) are given to the model with an instruction to use only them, cite them as [1], [2], say so when they do not contain the answer, and ignore any instruction inside them (documents are untrusted text and can try to steer a model). The answer is shown as plain text above the results, labelled as written by a model and possibly wrong, with the passages it was made from. When no passage matches, the model is not asked. `max_per_minute` limits the answers the whole server writes in a minute (over it: 429 `busy`); if the model does not respond: 503 `model_unavailable`. Retrieval alone, without any model, is unchanged and stays the default.

# SEMANTIC SEARCH

Semantic search is opt-in and uses a model server that you run (nothing in dksearch starts a model):

    [embeddings]
    url = "http://127.0.0.1:11434"    # Ollama, or any server with an OpenAI-style /v1/embeddings
    model = "nomic-embed-text"        # the model name the server knows
    api = "ollama"                    # or "openai"
    # timeout_ms = 30000   max_chars = 2000 (title and start of the text that is embedded)   batch = 16
    # index_mb = 2048     (memory the vector index may use; 0 turns the index off)

**dksearch embed** asks that server for a vector for each stored document (its title and the first *max_chars* of its text) and keeps them in `data_dir/vectors.db`, one per document and model. Documents that already have one are skipped, so it can be stopped, run again, and run again after an import. Then `semantic=1` on `/api/v1/search` re-orders the lexical results: the search finds its candidates by words as usual (a wider pool than the page), the query is embedded, and the order is the reciprocal-rank fusion (k = 60) of the lexical order and the order of similarity to the query, so a result that both lists like rises and one that only one likes is not dropped. Documents without a vector keep their lexical share only. With the vector index (below) it can also bring up documents the words did not match; it applies to the first page only, and the answer says (`semantic`) whether it was used and, if not, why (no embedding model configured, no vectors yet, the model server not reachable). Without `[embeddings]` nothing changes: dksearch stays purely lexical. The retrieval API (`/api/v1/retrieve`) is not changed by this.

**Models that want prefixes, and lazy mode.** Some models are trained with a task word before the text; for `nomic-embed-text`, a search is embedded as `search_query: ...` and a document as `search_document: ...`. Set them with `query_prefix` and `document_prefix` (a space follows unless the prefix ends with whitespace). Vectors are kept under the model name plus a fingerprint of the two prefixes, so vectors made with other prefixes (or none) are never mixed with these: changing a prefix starts a new set, and `dksearch embed` makes it. With `lazy = true` no pass over every document is needed first: when a search asks for meaning, the lexical candidates that have no vector yet (at most `lazy_max`, 20 by default, the best-ranked first) are embedded then, in one request that is given up after `lazy_timeout_ms` (8000), and kept in `vectors.db`; the results page says how many were made just now. The first search that shows a document costs that request; later ones do not, and the vector index picks the new vectors up like those of `dksearch embed`. A model that does not answer leaves the search as it was. Example for nomic-embed-text:

    [embeddings]
    url = "http://127.0.0.1:11434"
    model = "nomic-embed-text"
    query_prefix = "search_query:"
    document_prefix = "search_document:"
    max_chars = 600          # the title and the opening are enough, and about four times faster than the default
    lazy = true              # make vectors as searches need them (or run `dksearch embed` for all of them)

The **vector index** holds every document's vector in memory (quantized to one byte a dimension: about 770 MB for a million documents of 768 dimensions; loaded when first needed and again when `dksearch embed` has added vectors, checked every 30 seconds) and finds the nearest documents to the query by an exact scan, a few hundred milliseconds for a million. A `semantic=1` search then merges two lists by reciprocal rank: the lexical results and the nearest documents of the whole index, so a document that shares no word with the query can be found by meaning. Those found only by vectors have no snippet. The index is used only when the search has no filters, language or type (those need the lexical side to apply them; the search then falls back to reordering the lexical candidates), and a caller's scope still applies. If the vectors need more than `index_mb` the index is not loaded and the reply says so. An exact scan has no tuning and no recall to lose; a graph index is the next step for libraries too large to scan.

When a search finds nothing, the page offers **Did you mean**: each plain word is replaced by its closest word in the index (up to the usual typo distance) and the corrected query is offered only if it does find something. `GET /api/v1/suggest?q=...` completes the last word of a query (see dksearch-api(7)), for clients that offer autocomplete; the search page itself needs no script.

The administration interface has a **Docs** page with this manual and the HTTP API reference, one section at a time. On the **ZIM files** page, when no folder is set, a form asks for one: it is created, saved as `[admin] zim_dir` in the configuration and used at once, with no restart. `dksearch serve` refuses to start when something already listens on its search or administration address (a stale server sharing the port would answer some requests with its own sessions and data).

# TOR AND I2P

A `crawl` source can index sites of the hidden networks, through a Tor daemon and an I2P router that you run yourself (dksearch never starts, installs or bundles either, and the feature is off until a proxy is named):

    [[source]]
    name = "onions"
    kind = "crawl"
    user_agent = "mysearch/1.0"
    seeds_file = "onion-seeds.txt"
    tor_socks = "127.0.0.1:9050"     # a Tor daemon's SOCKS5 port: .onion sites
    i2p_proxy = "127.0.0.1:4444"     # an I2P router's HTTP proxy: .i2p sites
    # hidden_links = true            # also follow links into them from ordinary sites
    timeout_seconds = 60             # hidden services are slow

Only version 3 onion addresses are used (56 characters of a-z and 2-7 before `.onion`, with at most two subdomain labels in front); older, mistyped or deeper names are never contacted. A seeds file may also be TOML (a name ending in `.toml`): `[[site]]` entries with a `url` (and `sitemap = true` for a sitemap), and sections, each a table with its own `[[section.site]]` entries, as in a curated `links.toml` with one section per topic. `seeds_sections = "computers, law"` takes only those sections and `seeds_skip = "Adult"` leaves some out (names are compared without regard to case); a seed address that is not an http(s) URL is skipped.

The name of a hidden site is given to the proxy as a name and is never looked up locally, so it neither reaches your resolver nor the open internet; with no proxy set for a network, its addresses are not contacted at all. Only `http://` is used: an onion or I2P address already authenticates and encrypts the connection. Everything else about a crawl is unchanged: `robots.txt` is read, the delay applies, the crawler identifies itself with your `user_agent` (a site can see it; choose one you are willing to show there). A crawl that begins on a hidden site stays in the hidden networks and does not follow links to the open internet; links from ordinary sites into them are followed only with `hidden_links = true`. The addresses are indexed and shown like any other, so a result may be a `.onion` link that your browser needs Tor to open. What you crawl and keep is your responsibility under the law where you live.

# BLOCKLIST, DEMOTION AND SAFE SEARCH

Domain lists keep unwanted sites out of the results, however they were indexed or crawled. There are three, for different purposes:

- the **ban** (`[filters]`): domains hidden from everyone, whatever the settings (for a business that wants no adult content at all, or for sites that must never be reached);
- the **demotion list** (`[filters]`): domains that are still found but rank lower;
- the **safe-search list** (`[safe_search]`): domains hidden from visitors while safe search is on, which adults can turn off for themselves (a household where adults may search everything and children may not).

    [filters]
    ban = "ban.toml"                        # a list file next to this configuration file
    blocklist = ["slop.example"]            # or entries here, or files (blocklist_files)
    demote = ["seo-farm.example"]
    demote_files = ["/path/demoted.txt"]
    demote_percent = 30                     # a demoted domain's score is multiplied by this (1-99)

    [safe_search]
    enabled = true                          # on for visitors unless they unlock it
    list = "safesearch.toml"                # domains hidden while safe search is on
    unlock_hours = 8                        # how long a PIN unlock lasts in a browser

A list file ending in `.toml` holds `domains = ["a.example", ...]` and may `import = ["ban.toml", "more.txt"]` other lists (paths relative to the file; a list that imports itself ends), so `safesearch.toml` can import `ban.toml` and add the adult domains. Other files are text lists: one domain per line, a hosts file (`0.0.0.0 domain`) or an ad-blocker list (`||domain^`), with `#` comments. An entry may also be the MD5 hash of a domain (32 hex digits, as some services publish their banned-domain lists): it matches that domain and what is under it without the list naming it. A list entry covers the domain and everything under it (`example.com` covers `www.example.com`, not `notexample.com`). dksearch ships no list: you choose them, and a file that cannot be read stops the server rather than showing what was meant to be hidden. The lists are read when the server starts. `dksearch fetch-banlist` downloads a published list on request (see below).

The administration interface has a **Safe search** page for all of this: whether safe search is on and for how long an unlock lasts (edited in the configuration file), the unlock PIN (set, changed or removed; it works at once), and three lists kept in `data_dir/lists/` (ban, hidden while safe search is on, demoted), with how many domains are in use; the list edits apply at the next start. The *Access* page can mark a new API key as adult. Its pages use a sidebar with the sections grouped (Overview, Library, Search, System) and work on a phone.

**Who sees what.** The ban always applies. Safe search applies to a request unless it comes with an API key marked adult (`dksearch api-key add NAME ... --adult`) or from a browser that has been unlocked: `dksearch safesearch-pin` sets a PIN (stored as a hash in `data_dir/safesearch-pin.toml`), and a visitor enters it at `/unlock`; a cookie then marks that browser for `unlock_hours`, and *Turn it back on* ends it. After five wrong PINs in a minute further tries are refused for the rest of the minute. The pages say whether safe search is on. With no PIN set, safe search cannot be unlocked from a page (only by a key marked adult). With `enabled = false`, safe search is off for everybody and only the ban applies.

A hidden domain's documents are removed inside the search itself (so paging, counts, excerpts, similar documents, retrieval and answers never see them) and are also refused where a document is opened by its address (`/doc/ID`, its original file and pictures: not found) and dropped from the results of peers and of fallback search engines. What is handed to peers (`/api/v1/export`) leaves out the ban only: a peer you chose is not asked to apply your household's safe search. Limits: it works on the domain of a document's address, not on what the text says, so sites that are not on a list are not filtered, a ZIM file's articles are not judged, search by image applies the ban but not safe search, and a mirror of a hidden site under another domain is a different domain. The server states at start how many domains are hidden.

**Very common words.** Ranking has to read every occurrence of every required word, so a word that is in most documents ("in", "to", "the") made searches such as "how to program in c" take many seconds on a large index and fail. With `[search] common_word_percent` (default 15; 0 turns it off), a plain word that is in more than that share of the documents is not required by a query that has other words: that query is searched as "how program c", the page says "Left out as too common to help: to, in", and the API lists them as `ignored_words`. A word in quotes, a word with `title:`, a word excluded with `-` and a query made only of common words are searched as typed. It has no effect on an index of fewer than a thousand documents.

**Excerpts.** The excerpt of a result is made by dksearch from the text in the index, in one pass: the window of 16 words with the most different query words (a few words of context before it), the matches bracketed, adjacent matches in one bracket. SQLite's own excerpt function is slow on a word that occurs thousands of times in a long document (its time grows with the square of the occurrences); with a stemmed index (`tokenizer = "porter"`) SQLite's is still used, because it knows the stems.

**Downloading ZIM files.** The Download button of the ZIM files page queues the file and keeps you on the same list; the page shows the one downloading with a progress bar (speed and time left), the ones waiting (each can be removed) and the free space. Downloads wait behind a running import or download and start by themselves; the room is checked when a file is queued and again when its turn comes.

**Thumbnail cache (opt-in).** With `[images] thumbnails = true`, the gallery (the Images button) keeps a small JPEG copy of each picture it shows, made the first time the picture is shown, and serves that instead of the original: pages load fast, and large wallpapers are not sent to every browser. Only the small copy is kept; for pictures of the web (`index_images`, `[images] remote`) the original is fetched, shrunk and dropped. `thumbnail_dir` is an absolute folder (default `thumbs` in the data directory), `thumbnail_cache_mb` the most it may hold (16 to 1048576, default 1024: about 70,000 thumbnails, at roughly 12 KB each), `thumbnail_px` the longer side (64 to 1024, default 320) and `thumbnail_quality` the JPEG quality (30 to 95, default 75). Thumbnails are spread over a two-level folder tree by document id; when the folder is over its limit the oldest are deleted until it is 10% under. Photos are turned upright by their EXIF orientation. A picture format that is not shrunk here (SVG, AVIF, TIFF), one too large to decode, or a moment when too many are being made at once sends the browser to the original instead. The Maintenance page of the administration interface shows the cache and has a button to empty it; the settings are under Settings, Pictures. Changes apply after a restart.

**Login on the search page.** Set a password with `dksearch owner-password` (or on the Access page of the administration interface) and the search page shows a **Login** button at the top right. The owner who logs in sees everything the server holds (every source, safe search lifted); visitors see only what `[access] anonymous_collections` allows. A login lasts `[access] owner_login_days` (1 to 365, default 30); it is a signed cookie, so a restart does not end it, and changing or removing the password ends every login. Wrong passwords are limited to five a minute. The same box takes an API key (`dkk_...`) for other programs that want a browser session; `/login` and `/logout` are the pages.

**The search box.** With scripts on, the box is a multi-line field: **Enter** searches, **Shift+Enter** starts a new line, and it grows with its text (a line break counts as a space). Without scripts it is a one-line box that searches on Enter.

**Block List Project lists.** The Safe search page of the administration interface offers the lists of the Block List Project (phishing, fraud, scam, abuse, malware, ransomware, ads, tracking, redirect, drugs, gambling, piracy, torrent, crypto, vaping, and ones that ban well-known sites such as porn, facebook, twitter, tiktok, whatsapp, youtube, adobe, basic and smart-tv) as switches. Each list is Off, **Ban** or **Hide**. Choosing one downloads it (https, from github.com/blocklistproject/Lists) to `data_dir/lists/blocklistproject/`. After a restart a banned list bans its domains for everyone (not crawled, never shown); a hidden list hides them only while safe search is on (they are still crawled; adults unlock them with the PIN or an adult key), which suits lists such as `porn`. The choice is kept in `data_dir/lists/blocklists.txt` (`NAME` to ban, `NAME safe` to hide). Nothing is fetched otherwise. Domains of your own that a list gets wrong go in `allow` (below). The malware list has millions of entries and needs a lot of memory.

**Allow list.** Lists made by other people make mistakes. `allow = ["wallpapers.com"]` in `[filters]` takes that domain, and entries under it, out of `blocklist` and `blocklist_files` (not out of the `ban` file or the administration interface's own ban list, which are yours). The server says at start how many entries it removed.

**dksearch export --source NAME [--source NAME ...] --out FILE.dksearch.jsonl [--force]** writes the documents of the named sources, with their full texts, one JSON object per line, to a file that a `dump` source with `format = "export"` reads on another machine (to seed a public server with a crawl made at home, for example). Documents of banned domains are left out. The file is written under a `.part` name and renamed when finished; an existing file is replaced only with `--force`. It reads the index while the server runs. Compress it with `zstd` for the copy if you like.

**Signing in with a key.** `/login` takes an API key (made with `dksearch api-key add`) and keeps it in a cookie (`dks_key`, HttpOnly, 30 days; `Secure` with `[access] cookie_secure = true`, which you set when a proxy serves the site over HTTPS). That browser then has the key's view: its collections (everything for `--all`) and, for a key made with `--adult`, no safe search. A key that is no longer valid, or that is bound to a node, leaves the browser anonymous. `/logout` deletes the cookie. With `[access] anonymous_collections` naming the public collection, one server serves a public view and a complete one.

**Public mode.** `public_mode = true` under `[server]` makes the configuration refuse to load if `[access] anonymous_collections` is missing, if a source in a collection the public may search has `serve_originals = true`, or if the administration interface does not listen on a loopback address. See `docs/deploy/public-instance.md` and `docs/deploy/home-server/`.

**dksearch fetch-banlist --url ADDRESS --out FILE --yes** downloads a list on request (https only; a web page or an error is refused and the file is left as it was) and replaces FILE, so a published list can be kept current without shipping it with dksearch: for example `--url https://ahmia.fi/blacklist/banned/`, Ahmia's list of banned onion domains as MD5 hashes. Without `--yes` it only says what it would do. A source that crawls Tor (`tor_socks`) is refused unless a ban list is configured (`[filters] ban` or `blocklist_files`) or the source says `allow_unbanned_onions = true`. The crawler uses the ban too (also when `dksearch import` runs it): a banned site is never contacted, not even for its robots.txt, whether it is a seed or a link, and is counted as skipped because `banned`.

**Trusted sources first.** `[search] trusted_first = true` (or `trusted=1` on a request; `trusted=0` turns it off for one) puts the results of the sources whose `boost` is at least `trusted_min_boost` percent (default 150) before all the others, each group in its own order of relevance, so a curated source ranks ahead of the long tail however often the tail repeats the words. It applies to searches of words in relevance order, is kept by paging and works with `per_domain`; a cursor (`after`) does not combine with it, and `next_cursor` is then not offered.

**Results per domain and hidden-network marks.** `[search] per_domain = N` (or `per_domain=N` on a request, 1 to 50; 0 is no limit) keeps at most N results from one domain, the best of each, in the order of the full ranking; paging and cursors follow the limited list. It applies to searches of words in relevance order. A result on a Tor or I2P address carries a *Tor* or *I2P* mark on the page and `network` (`"onion"` or `"i2p"`) in the API, since a normal browser cannot open it.

**Regular expressions work on characters.** A pattern's `.`, character classes, `\x{...}` code points and literal letters match whole UTF-8 characters: `.` is one letter whether it takes one byte or four, `caf\u00e9+` repeats the letter *\u00e9* (not its last byte), `[\u00e0-\u00ff]` is a range of letters, `[^a]` matches a whole character and `\w` includes every letter outside ASCII (so `\b` falls between a word and a non-word character). `\d` and `\s` stay ASCII, and case-insensitive matching folds ASCII letters only. A document with bytes that are not valid UTF-8 never breaks a match: those bytes are simply not matched by a character pattern. The pattern itself must be valid UTF-8.

**Recrawling pages on their own schedule.** A `crawl` source with `validators_file` can also set `recrawl_adaptive = true`: a page at the depth limit (which follows no links) is then asked again only when its own interval has passed. The first time a page is seen its interval is a day; each time it is found unchanged (a 304, or the same body) the interval grows by a fifth, and each time it changed it shrinks by a fifth, within `recrawl_min_hours` (default 6) and `recrawl_max_days` (default 60). Pages not yet due are not requested at all, so a recrawl of a large site costs requests only for the pages that are due. Pages with links to follow are always fetched, since the crawl needs them to find the rest.

**Finding pictures by picture.** A `files` source with `images = true` indexes pictures (JPEG, PNG, GIF, WebP, BMP, SVG, AVIF, TIFF): each becomes a small document made of the words of its folders and file name, its size and orientation and its EXIF description and camera, and the readable ones (JPEG, PNG, GIF, WebP, BMP) get a 64-bit perceptual fingerprint (a difference hash). Nothing is stored of the picture itself; with `serve_originals = true` the originals are shown from their files. Pictures of crawled pages: set `index_images = true` (and optionally `max_images_per_page`, default 12) on a `crawl` source to record each page's pictures (address, alt text, page) without downloading them, and `[images] remote = true` (with `relay_max_mb`, `relay_concurrency`) so the gallery shows them through a relay that fetches a picture when it is looked at and stores nothing. The search page's **Images** button (next to Search) searches only pictures and shows them as a gallery of 40 a page, from this server's own files. `dksearch find-image FILE [--distance BITS] [--limit N]` computes the fingerprint of a picture and lists the indexed pictures within BITS of 64 (default 10) of it, nearest first, with their source, address and title; it finds copies and resized, recompressed or slightly recoloured versions, not pictures of the same kind of thing. The administration interface has the same search as **Find by image**: upload a picture (JPEG, PNG, GIF, WebP or BMP, up to 10 MiB), choose how different it may be, and the matches are listed. Nothing uploaded is stored. Because of such uploads the administration listener accepts request bodies of up to 12 MiB (the public listener accepts none).

# SOURCE LIST AND DUPLICATES

The search page's source list shows how many documents each source holds, and `/sources` lists the sources the visitor may search with their kind, document count, when a document was last added, and the collections each is in, with a link that searches just that source. The numbers are counted at most every five minutes (counting groups the whole index). On the search page the same text found in several sources (or the same web page by its address) is shown once, naming the others ("same text in ..."); `group=0` shows every copy. The API folds them only with `group=1` (`same_in` lists the other sources).

# COLLECTIONS AND API KEYS

A *collection* is a named group of sources:

    [[collection]]
    name = "books"
    description = "Books and papers"      # optional, shown as a hint on the search page
    sources = ["folklore", "banking"]

The name follows the rules of source names and may not be one; every member must be a configured source. A collection can be searched on the page (the *Collections* choice next to the sources, `source=collection:books` in the address), in the query language (`collection:books`, `-collection:books`; several mean either) and in the API (`source=collection:books`).

By default everyone can search every source. To limit visitors, name the collections they may use:

    [access]
    anonymous_collections = ["public"]    # an empty list means nothing without a key

Collections can also be added and removed on the Access page of the administration interface (when `admin.actions` is on and the server was started with `--config`): a validated edit of the configuration file (a source that does not exist, a name that is a source's, or a collection still named in `[access]` is refused with the reason), applied after a restart.

Visitors without a key then see only the members of those collections everywhere: in results, on the page, in the document viewer (`/doc/ID`, its original file and pictures), in ZIM articles and in retrieval. A document or article outside a caller's scope is answered as if it did not exist. With an empty list the API answers 401 `key_required`, and the search page finds nothing.

An API key (made with **api-key add**) replaces the anonymous scope by the union of its collections' sources (or all of them with `--all`). It is sent as `Authorization: Bearer dkk_...`; a key that is not valid is refused with 401 `invalid_key` and is never treated as anonymous. The scope comes from the key or the setting, never from the request: nothing in a query, a parameter or a source name widens it. Keys are shown once and kept only as hashes. The administration interface and its token are separate and unaffected.

# OPENING OFFICE FILES IN A DOCUMENT SERVER

With a document server (OnlyOffice Docs, or Collabora Online / LibreOffice Online) the viewer page of an office file (`docx`, `xlsx`, `pptx`, `odt`, `ods`, `odp`, and the older `doc`, `xls`, `ppt`, `rtf`, `csv`) gets an *Open in the document viewer* button next to *Open the original file*, which shows the file formatted, read-only, in the document server. It needs a source with `serve_originals = true` (the file is fetched from there), and a server you run yourself, for example from Docker:

    [docserver]
    kind = "collabora"                     # or "onlyoffice"
    url = "http://127.0.0.1:9980"          # the document server as your browser reaches it
    public_url = "http://172.17.0.1:8080"  # this dksearch as the document server reaches it
    jwt_secret_file = "/etc/dksearch/onlyoffice.jwt"   # OnlyOffice only, if its JWT is on (its default); or jwt_secret

`/doc/ID/open` checks that the caller may see the document, then sends the browser to Collabora, or serves a small page that starts OnlyOffice's viewer. The document server has no cookie or key, so it is given a token: an HMAC over the document's id and an expiry, valid for that one document for one hour, usable only to read that file through `/wopi/files/ID` and `/wopi/files/ID/contents` (the WOPI protocol; both servers read the file this way). The tokens are signed with a secret made when the server starts, so links stop working after a restart. A token lets its holder read that file but gives no access to anything else, search included. Nothing is written back: the viewer is read-only (`permission=readonly`, `mode: view`).

For Collabora, allow dksearch as a WOPI host (`storage.wopi.host`, in Docker `-e 'extra_params=--o:ssl.enable=false --o:storage.wopi.host[0]=.+'`; use a precise pattern in real use). OnlyOffice by default refuses to fetch from private addresses (`services.CoAuthoring.request-filtering-agent.allowPrivateIPAddress`); set it for a dksearch on your LAN. `public_url` must be an address the document server can reach: from a Docker container `127.0.0.1` is the container itself, so use the host's address (`172.17.0.1` on the default bridge) and have dksearch listen there (`server.address`). OnlyOffice's page uses a policy that allows only its own script (by hash), the document server's script and frame; the rest of dksearch stays script-free.

REPLICATING A PEER'S DOCUMENTS

Federated search asks a peer at query time. A node can also keep a *copy* of one of a peer's sources, so its documents are searchable here when the peer is away. Both sides agree to it:

On the node that owns the documents, a source is shared only if its owner says so, with `share = true` in its `[[source]]` table (or the checkbox on the source's page in the administration interface); it is refused together with `rights = "forbidden"`, and nothing is shared by default. The other node also needs an API key (`dksearch api-key add`) whose collections include that source. `GET /api/v1/export?source=NAME` (see **dksearch-api**(7)) then hands out the source's documents with their full text, a page at a time; it always needs a key, even on a server that answers anonymous searches, and a source that is not shared, is off, is forbidden or is outside the key's collections looks like one that does not exist.

On the node that wants the copy, a source of kind `peer` pulls it:

    [[source]]
    name = "office-books"
    kind = "peer"
    url = "https://search.example.org"         # the other node
    source = "books"                          # its source name
    key_file = "/etc/dksearch/office.key"      # the key it made for you, mode 0600
    schedule = "daily"

A replica is an ordinary source: it has its own name, rights flags, schedule and boost, it can be put in collections, and each document keeps the redistribution flag the owner stated (`allowed`, `restricted` or `unknown`) and says where it was copied from (the attribution, and an `origin` field). Documents are updated when the owner changes them; a document the owner later removes is not removed from the copy. Copied documents have the same `ident` as the originals, so a federated search that also asks the peer shows them once. Everything the peer sends is untrusted: sizes are bounded, ids must be well formed, text must be valid UTF-8, links that are not `http` or `https` are dropped.

# NODE IDENTITY

A node can have an identity: an Ed25519 key pair. **dksearch node-key** makes it (once) in `data_dir/node-identity.toml`, mode 0600, and prints the node id, `dkn_` and 43 characters: the public key. The file is secret (anyone who has it can speak as this node; a file others can read is refused). Restart `serve` to use it. The identity does not discover anyone or decide whom to trust: peers and keys stay configured by hand. It makes two things stronger:

- **Signed requests.** With an identity, every request this node sends to a peer carries `dk-node`, `dk-time`, `dk-nonce` and `dk-sig`: a signature over the method, the target, the host the request is addressed to, the time and a fresh nonce. It cannot be replayed to another node, on another path, with another method, later than five minutes, or twice. A key made with `dksearch api-key add NAME ... --node ID` (give the id of the node that will use it) is *bound*: it works only on requests signed by that node, so a leaked key is useless without the secret. Both clocks must be right within five minutes, and the Host the other node sees must be the address you configured (behind a proxy that rewrites Host, a bound key will not work).
- **Pinned peers.** `node = "dkn_..."` in a `[[peer]]` (or in a `kind = "peer"` source) says whose answers to believe. The peer is sent a nonce and must sign its answer (the nonce, the status and a hash of the body) with that node's key; an answer that is unsigned or signed by another node is not used (status `untrusted` on the Access page; a replica run fails rather than copy from an impostor). A node with an identity signs its answers to any caller that sends a nonce.

Give your node id to the owners of peers that should recognise you, and ask for theirs. A replica source needs `identity_file` pointing at the identity file (for bound keys) and, to pin, `node`. The Access page shows this node's id.

# FALLBACK TO OTHER SEARCH ENGINES

Off by default. When the local search finds few results (or none) the page can offer other engines, in two independent ways. The second sends your visitors' words to a third party, which is why the whole feature is opt-in and says so on the page:

    [fallback]
    enabled = true
    min_results = 3            # offer it when fewer local results than this were found (0: always)
    engines = ["duckduckgo", "brave", "google", "bing"]   # link-out buttons
    # auto = false             # true: ask the providers by itself when results are few (otherwise on request)
    # max_per_minute = 30      # most requests this server makes to providers in a minute, all visitors together

    [[fallback.engine]]        # your own link-out; the address has exactly one %s where the words go
    name = "kagi"
    label = "Kagi"
    url = "https://kagi.com/search?q=%s"

    [[fallback.provider]]      # web results this server asks for itself
    kind = "searxng"           # brave, searxng or marginalia
    url = "https://searx.example.org"    # searxng: your instance, with JSON output enabled
    # key_file = "/etc/dksearch/brave.key"   # brave: a Brave Search API token; marginalia: its API key (default "public")
    # timeout_ms = 4000   count = 5

**Link-out buttons** (`engines`): the page shows "Search elsewhere: DuckDuckGo · Brave Search · ..." as plain links that open the engine with the words (`rel="noopener noreferrer nofollow"`). This server sends nothing; the visitor's browser goes to the engine only if they click. Built in: `duckduckgo`, `brave`, `google`, `bing`, `startpage`, `ecosia`, `qwant`, `mojeek`, `marginalia`, `kagi`, `yandex`, `wikipedia`, `archive`, `github`, `stackoverflow`; add your own with `[[fallback.engine]]`.

**Providers**: the page offers *Also search the web through NAME* (a link with `web=1`); with `auto = true` it asks without being asked. The answers appear under the local results, as *From the web*, each marked external with the provider's name; they are never ranked with the local results and never stored. Their text and addresses are untrusted: sizes are bounded, only `http` and `https` links are kept, everything is escaped. The API takes `fallback=1` (see **dksearch-api**(7)). Brave Search API (`kind = "brave"`) needs a subscription token from Brave; a SearXNG instance (`kind = "searxng"`) is yours or one you trust, and must allow `format=json`; Marginalia (`kind = "marginalia"`) has a public API. Scraping Google or Bing result pages is not offered: it breaks their terms and changes without notice; their link-outs are.

Nothing is shown to a caller who cannot search at all (an empty anonymous scope), and no provider is asked on pages after the first. Because requests go out on behalf of anonymous visitors, `max_per_minute` limits them for the whole server, and the server prints a note at start when providers are on.

# PEERS AND FEDERATED SEARCH

A *peer* is another dksearch node you may ask. Peers are configured by hand, never discovered:

    [node]
    name = "home"                         # shown on other nodes beside what comes from here

    [[peer]]
    name = "office"                       # letters, digits, - and _
    url = "https://search.example.org"    # no path, no credentials
    key_file = "/etc/dksearch/office.key" # a key the peer made with `dksearch api-key add`; or `key = "dkk_..."`
    timeout_ms = 1500                     # 100 to 30000
    enabled = true

A node name is required once there are peers. The key limits what the peer shows you to the collections it chose for you; give the key file mode 0600 (the key inside the configuration file also works but is easier to leak). With peers configured the search page has an *Also ask peers* box and the API takes `peers=1` (see **dksearch-api**(7)): the peers are asked in parallel and results are merged and labelled with the node they came from, with a note above the results saying which peers answered, were slow, down or refused. A peer that fails is left alone for 5 seconds, doubling after each further failure up to 5 minutes. Everything a peer sends is treated as untrusted text (bounded, escaped, never as markup), and its document links are built from the ids it returns. A visitor whose view is limited (by `[access]` or a key) is never offered peers. The Access page of the administration interface lists the peers with the last attempt (result, time taken, how long ago), when each last answered, and the failures in a row; its *Test* button asks a peer a small question at once (ignoring any backoff) and says whether the address answers and the key is accepted. Peers can introduce each other, never automatically. A `[[peer]]` with `introduce = true` is one this node is willing to tell its own peers about (the *Introduce* button next to it on the Access page); `GET /api/v1/peers` (with a key) lists those, by name and address only, never a key. On the Access page, *Ask my peers for suggestions* asks each of your peers for that list (only when you click, it uses the network) and shows the peers you do not have yet, each with a form to add it: you still need a key from that node (ask its owner) and give it as a key file. Names are made safe and addresses must be plain `http` or `https` base addresses; anything else is left out. Links to a peer's documents work in a browser only if that peer shows them without a key. Peers can also be added, switched off and removed on the Access page (when `admin.actions` is on and the server was started with `--config`): the change is validated like any edit, written to the configuration file (comments are kept, an inline key is kept, the key itself is never typed in the page: give a key file) and applies after a restart. Peers are asked over the existing API; nothing is copied between nodes.

# SEARCH SYNTAX

The search box understands: `"kernel module"` (phrase), `linux wayland` (both words), `linux AND wayland`, `linux OR bsd`, `linux NOT android` or `linux -android` (exclude), `+linux` (required, which is the default anyway), `(linux OR bsd) AND kernel` (grouping), `comp*` (words starting with comp), `compositor~` (the word or any word one typo away) and `"window manager"~5` (within five positions of each other). AND binds tighter than OR, so `a b OR c` is `(a AND b) OR c`. `AND`, `OR` and `NOT` are operators only in capitals. Everything typed is quoted before it reaches the index, so no index syntax can be injected. A query with only excluded words has nothing to search for and is an error.

Typo tolerance is on out of the box: when a search finds fewer than three results it is repeated with every word of four or more letters also matching words of the index a typo away, and the results page says so and offers "Search exactly as typed" (`fuzzy=0` in the URL). One typo means a letter missing, extra, wrong or swapped (a swap of neighbours counts as one); words of three to five letters allow one, words of six or more allow two. `word~` forces it for one word, `word~1` and `word~2` choose the number. The candidates are the words that really occur in the index (the closest and most common twelve), found from its vocabulary, so a search is also faster than the old expansion into every possible spelling. Words of three letters or fewer are never guessed at. Set `[search] fuzzy` to `always` to expand every search or `off` to turn it off.

Validation, unknown keys, reload behavior, versioning, and migration rules

The whole file is validated before anything starts, including every source's options. Unknown keys, wrong types and out-of-range values are errors that name the file and the key, for example `dksearch.toml: server.prot: unknown key`; a misspelled setting is never silently ignored. `admin` and `server` may not share the same address and port. There is no reload: configuration is read once at start, so a restart is required to apply changes. There is no configuration versioning yet.

# EXAMPLES

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
**check** prints one line per database and the verification totals, then `ok` and exit status 0, or a `problem:` line and exit status 1 when it finds damage. To restore, stop dksearch, move the damaged files out of `data_dir`, and run `dksearch restore --config dksearch.toml /backups/dksearch-2026-11-14`; it verifies the backup, copies it in and recreates the index.

Ask the running server
    curl 'http://127.0.0.1:8080/api/v1/search?q=truth&limit=5'

Automation and failure handling
    if ! dksearch check-config dksearch.toml; then
        printf 'bad configuration\n' >&2
    fi

# DIAGNOSTICS

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

# SECURITY CONSIDERATIONS

The public HTTP listener has no authentication unless collections and keys are set up (see COLLECTIONS AND API KEYS); the search API is read-only and intended to be public if the administrator exposes it. It listens on loopback by default. To expose it, set `server.address` explicitly. Prefer a reverse proxy for TLS (not implemented here) and rate limiting.

The administration interface is a separate listener (default 127.0.0.1:8081) and separate code; nothing on the public listener reaches it. Everything on it except the sign-in page and the style sheet needs a credential: a bearer token (for scripts) or a session obtained by signing in with the password or the token. Credentials are kept only as hashes (SHA-256 for the token, Argon2id for the password) in `admin.secrets_file`, never in the main configuration, and the file is refused if group or others can read it. The secrets file is read again for every check, so replacing a credential takes effect immediately and ends all sessions. Sessions live only in memory (a restart signs everyone out), use an unguessable 256-bit id in an `HttpOnly`, `SameSite=Strict` cookie, expire after the idle and absolute limits, and every state-changing request is a POST that also carries a per-session form token. Failed attempts are slowed down for the whole process (none for the first three, then 250 ms doubling to 5 s, forgotten after 15 quiet minutes; wrong bearer tokens are not counted), at most four attempts wait at once (more get status 429) and at most two password checks run at once; there is no per-client tracking, because client addresses are not recorded, so an attacker who keeps failing also slows the administrator's own form sign-ins down (the token is not affected). If the `[admin]` table exists but there is no credential, the administration interface does not start and the reason is printed; there is no default password. By default it is read-only. With `admin.actions = true` it can also start an import of a configured, enabled source and cancel the running one (never rebuild, remove, back up or change configuration), under the same authentication, with the form token required for browser sessions. Imports started this way take the same data-directory lock as the command line, so they cannot overlap a command-line import, rebuild or removal. Which paths a source reads comes only from the configuration file, not from the request. It transmits the token or password in clear text unless HTTPS is provided by a reverse proxy, so keep it on loopback or put it behind one (and set `admin.cookie_secure = true`).

Trust boundaries: all request data is untrusted. Request heads are size-limited and must complete within a deadline; a client sending data slowly cannot hold a connection open past it. Request bodies are refused. Query text is never interpreted as search-engine syntax: operators, column filters and punctuation are searched as ordinary text, and queries are limited to 1024 bytes and 32 terms. Result pages escape all text, link only http and https URLs, and are sent with a Content-Security-Policy that forbids external resources and inline scripts and styles (only the administration interface serves one script file of its own, for live import progress). Database error details are never sent to clients. These properties are covered by the project's tests; they are not an audit.

SQLite is compiled without extension loading, so no native code is loaded at run time.

The index directory should be writable only by the account running dksearch. The configuration file holds no secrets; the credential hashes are in the separate secrets file, which should be readable only by the account running dksearch.

The regular-expression filter (`[search]`) runs patterns typed by anyone who can reach the public search page. It is bounded in pattern size, matching steps, candidate documents, time and concurrency, and the matcher never reads outside the text, but a pattern can still cost up to its budget in CPU for each query: lower the limits, or set `search.regex = false`, on a server where that matters, and put a rate limit in the reverse proxy. The `crawl` connector fetches pages as untrusted input: HTML is reduced to text and never interpreted, bodies are size-capped, redirects stay on the same site, HTTPS certificates are always verified, and the response of a site is never trusted to name where to fetch next. It does not block requests to private or loopback addresses on the sites you list, so do not list internal hosts you would not want indexed. The `feeds` connector treats feed files as untrusted input in the same way (no XML entity expansion, document type declarations refused, bounded nesting and field sizes, HTML reduced to text and never interpreted), and reads only the files under `path`. Feed content is third-party text that becomes searchable and is shown in results.

The `wikipedia` connector treats the dump as untrusted input: it refuses any XML document type declaration (so entity-expansion attacks cannot work), bounds nesting depth and the size of every field and article, converts the text in time linear in its size, and executes nothing. It reads only the one file named by `dump`. The bundled bzip2 library and the XML parser (xml-zig, which never expands entities beyond the five predefined ones) are vendored.

The `gutenberg` connector treats the catalog and the book files as untrusted input: it bounds field and file sizes, refuses malformed catalogs and invalid text, derives file names only from validated numeric catalog ids, never follows symbolic links, and executes nothing. Project Gutenberg's license and trademark terms apply to the books you import; read them at https://www.gutenberg.org/policy/license.html before redistributing text or running a public service with it.

The `files` connector treats the directory tree as untrusted input. It never follows symbolic links, skips hidden entries, reads only regular files with the expected extensions, enforces a size limit, rejects invalid text, and executes nothing. It indexes only what its account can read, and the text of every indexed file becomes searchable and is shown in results, so point it only at directories whose contents may be searched by everyone who can reach the server. Result URLs for these files are `file://` URLs, which the HTML page shows as plain text, not links.

# PRIVACY

dksearch sends no telemetry and contacts no external service. Nothing about requests is written anywhere unless you set `access_log`. In memory only, the server keeps counters (requests by status class, response-time buckets, connections accepted, refused and timed out), shown on the administration dashboard and lost at exit. With `access_log` set, each request adds one line with exactly these fields: UTC time, method, a fixed route label such as `/search` (never the actual URL), status, duration in milliseconds, and response bytes. Query text, URLs, client addresses, user agents, cookies and credentials are never logged. Rotating the log is up to the operator (logrotate with `copytruncate` works; restarting reopens it). **import** records, in `state.db`, the name, time, counts and last position of each run; it does not record file contents beyond what is indexed. Anything placed in front of it, such as a reverse proxy, has its own logging.

# RESOURCE USAGE

**import** processes one document at a time and holds one batch open (at most 1000 documents, or fewer when the connector saves positions more often) in database transactions before committing it. The `files` connector keeps the sorted list of file paths in memory and reads one file at a time. **serve** memory per connection is the configured `max_header_bytes` read buffer, a 4096-byte write buffer, and the arena for the current request, whose size is bounded by the response (at most 100 hits). Each connection uses one task. At most `max_connections` connections exist at once. These are design bounds; measured figures for a 20,000-document index (about 35 MB resident for **serve**, index files about 2.2 times the text size) are in `docs/performance.md`.

# PERFORMANCE

Search time is that of SQLite FTS5 over the index. **serve** answers searches on a pool of read-only index connections (the smaller of the CPU count and 8, at least 2), so concurrent searches run in parallel. On a synthetic index of 20,000 articles, one client saw a median of 15 ms and a 99th percentile of 43 ms per query, and four clients together reached about 230 queries per second; see `docs/performance.md` for the method, the caveats and what was not measured. Real data at scale has not been measured. Results are limited to a window of 10000 (offset plus limit) to bound deep-pagination cost.

# CONCURRENCY AND ATOMICITY

Requests are served concurrently. Do not run two servers on the same `data_dir`. **import**, **rebuild** and **remove** take an exclusive lock on `data_dir/write.lock`, so a second one refuses to start (exit status 4) while another runs; the operating system releases the lock when the process ends, even after a crash, and the lock file itself is harmless and may stay. **check** and **backup** may run at any time. Running **serve** while **import** writes is supported: readers are not blocked, and new documents appear when each batch commits.

Imports write in batches: content first, then the index, then the document records, and only then the saved position. After a crash, everything up to the last committed batch is intact and the run resumes from its position; the interrupted batch is lost as a unit and repeated, and the pipeline's duplicate detection makes that repetition harmless. The index file is written in WAL mode with synchronous=NORMAL: after a power loss the last few commits may be lost, but the file remains consistent. Because the index is derived data, this is accepted in exchange for write speed.

# SIGNALS

| Signal | Behavior |
|---|---|
| SIGINT | Graceful stop, as for SIGTERM. During **import**: stop after the current file, commit the batch in progress, record the run as cancelled with its position, and exit with status 1. |
| SIGTERM | During **import**, as SIGINT. During **serve**, a graceful stop: stop accepting connections, close idle (keep-alive) connections at once, let requests already being handled finish for up to `server.shutdown_grace_ms`, then exit with status 0. Anything still running after the grace period is cut off. A second signal does not hasten this. |
| SIGHUP | Not handled; terminates the process (default action). There is no reload. |
| SIGKILL, power loss | The index file stays consistent, but the last few commits may be lost (see above). |


# NETWORK

Listens on one TCP address (IPv4 or IPv6) for HTTP/1.1 with keep-alive. No TLS. No outbound connections. Works fully offline. Timeouts and limits are as listed under CONFIGURATION. Clients that exceed them are disconnected without a response, except oversized or malformed request heads, which receive 431 or 400.

# COMPATIBILITY

Platforms

Developed and tested on Linux x86_64 with Zig 0.17.1. Other platforms are untested.

Standards

HTTP/1.1 message syntax as implemented by the Zig standard library; JSON per RFC 8259. Compliance is not claimed beyond that.

Stability guarantees

The `/api/v1/` API is intended to be stable within version 1 (see dksearch-api(7)). The command-line syntax, configuration keys and diagnostics text are experimental at version 0.

# LIMITATIONS

Six connectors are bundled (`files`, `gutenberg`, `wikipedia`, `feeds`, `crawl` and `archive`); only `crawl` (for the URLs you list) and `archive` (for the Archive's search service) use the network. It follows only same-site links up to `max_depth` unless `follow_external` is set, reads uncompressed sitemaps, sends no conditional requests, has no proxy support and understands few text encodings. The `gutenberg` connector reads only the CSV catalog, not the RDF catalog, and does not unpack archives or read HTML or EPUB books. Documents whose items vanished from a source are removed only with **import --prune**, and only the `files` and `gutenberg` connectors can tell. Backups are manual (no scheduling or retention) and the copies are not encrypted. The administration interface cannot run **check**, **rebuild**, **remove** or **backup**, or edit configuration; it can start and cancel imports only when `admin.actions` is true. No TLS. No reload or request log. Only two tokenizers exist: `unicode61` and `porter` (English stemming). Languages without word separators (such as Chinese or Japanese) are not segmented well, and stemming is English only. Index size and query time at large scale (millions of documents) have not been measured.

# BUGS

No issue tracker is published yet. When one exists it will be listed under AVAILABILITY. Include the dksearch version, the configuration file, the full diagnostic output and the request that failed.

# TROUBLESHOOTING

Program fails to start

Run `dksearch check-config FILE`. Check that the port is free (`ss -ltn`), that `data_dir` is writable, and that no other dksearch uses the same `data_dir`.

Unexpected output

Searches return nothing: the index may be empty. Run **import** for a configured source, or check that the source's `path` holds `.txt` or `.md` files that are not hidden. Check `GET /api/v1/health`, then `GET /api/v1/search?q=...`.

Slow operation

Check that `data_dir` is on a local filesystem. WAL mode does not work reliably on network filesystems, and a filesystem with slow fsync slows index writes.

# WORKAROUNDS

Hacks that are used on purpose, with why, the commands, and how to undo them.

Build and test cache on a fast disk (developers). `zig build test` writes a large cache (it reached 76 GB after many runs), and the tests make their temporary folders in `.zig-cache/tmp` under the repository, with many synced writes. When the repository is on a slow or shared spinning disk, a test run that takes minutes elsewhere takes a quarter of an hour (the test program waits in `wait_log_commit`). Keep the cache on a fast disk and make `.zig-cache` a link to it:

    mkdir -p ~/.cache/dksearch-zig
    rm -rf .zig-cache && ln -s ~/.cache/dksearch-zig .zig-cache
    export ZIG_LOCAL_CACHE_DIR=~/.cache/dksearch-zig      # before zig build / zig build test
    echo .zig-cache >> .git/info/exclude                  # the .gitignore entry (".zig-cache/") matches folders, not links

Prune it when it passes about 20 GB (`rm -rf ~/.cache/dksearch-zig/*`; the next build is a full one). To undo: remove the link and the variable; Zig makes `.zig-cache` again.

Replacing the binary of a running server. Copying over a program that is running fails ("Text file busy"). Put the new file beside it and rename it over the old one (`cp dksearch dksearch-new && mv -f dksearch-new dksearch-cur`): the running process keeps the old file until it stops, and the next start uses the new one.

A server and an import together. A new server cannot start while an import holds the databases (`cannot open state.db`), but an import started after the server works. Start the server first, then the import; to restart the server while an import runs, stop the import (it resumes from its checkpoint), start the server, and start the import again. The Restart button of the administration interface does this for the server alone.

Profiling the server. `perf record -g` and hardware events are refused for a normal user. With `kernel.perf_event_paranoid=2` (`sudo sysctl -w kernel.perf_event_paranoid=2`, until reboot; `=4` restores the usual default) user-space samples work: `perf record -e cpu-clock:u -F 499 -p PID -- sleep 10`, then `perf report --no-children --stdio --sort symbol`.

Do not use `pkill -f` or `pgrep -f` with text that is also in the command that runs it: the pattern matches the shell itself. Name the program exactly (`pgrep -x dksearch`) or take the process id from the process list.

# NOTES

The three databases are SQLite files. The index holds a `docs` table and an FTS5 table `fts`. Layouts are internal and may change between versions; a version mismatch is detected and reported.

# CAVEATS

Deleting `index.db` is safe: **rebuild** restores it. Deleting `state.db` or `content.db` is not: they are the only copy of what was imported, and an index cannot be rebuilt without them. Back them up with **backup**, and check them now and then with **check**; do not copy the files with `cp` while **import** runs, because the write-ahead log (`-wal`) files must be copied with them to be consistent. Re-importing never deletes documents whose source items were removed unless you pass **--prune**; **remove** deletes a whole source.

# HISTORY

Version 0.0.0 is the first, pre-release version.

# DEPRECATION

Nothing is deprecated.

# SEE ALSO

dksearch-api(7), toml-syntax(5)

Project documents: `ai/SPEC.md`, `docs/decisions/`. SQLite FTS5: https://www.sqlite.org/fts5.html. TOML: https://toml.io/

# AUTHOR

dksearch contributors.

# COPYRIGHT

Copyright 2026 dksearch contributors. SPDX-License-Identifier: GPL-2.0-only

# LICENSE

GNU General Public License, version 2 only. The complete text is in the file `LICENSE` in the source distribution. Vendored components keep their own licenses, which are compatible with it: SQLite is in the public domain (`vendor/sqlite/README.md`); toml-zig is MIT (`vendor/toml-zig/LICENSE`).

# AVAILABILITY

Source code, releases and issue tracker: not yet published.

# VERSION

This manual describes dksearch version 0.0.0. It is updated together with the program.

