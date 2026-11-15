% DKSEARCH(1) Version 0.0.0 | Project Manual
% dksearch contributors
% 2026-11-14

NAME
dksearch - self-hosted search engine: import documents, serve a search index over HTTP, and validate its configuration

SYNOPSIS
dksearch [-h | --help] [-V | --version]

dksearch serve [--config FILE]

dksearch import --config FILE (SOURCE | --all) [--prune]

dksearch remove --config FILE SOURCE [--yes]

dksearch rebuild [--config FILE]

dksearch check [--config FILE]

dksearch admin-token [--config FILE]

dksearch admin-password [--config FILE]

dksearch backup [--config FILE] DIR

dksearch check-config FILE

DESCRIPTION
dksearch is an independently operated, self-hostable search engine. It maintains its own full-text index and does not use an external search provider.

This version provides the public search interface (a JSON API and a server-rendered HTML page, both read-only), an import command, an index rebuild command, and commands to check and back up the stored data. Documents arrive through *sources* defined in the configuration file. Sources are optional: with none configured, **serve** still works and serves whatever index exists. Each source is one instance of a *connector*; this version bundles six: `files`, which indexes plain-text and Markdown files from a local directory; `gutenberg`, which indexes Project Gutenberg books from a catalog file and a directory of book files you have already downloaded; `wikipedia`, which indexes the articles of a Wikipedia dump file you have already downloaded; `feeds`, which indexes the entries of RSS and Atom feed files you have already downloaded; `crawl`, which fetches a list of web pages you name, over HTTP or HTTPS; and `archive`, which indexes the metadata of Internet Archive items matching a search. `crawl` and `archive` are the only connectors that use the network. The `wikipedia`, `feeds`, `crawl` and `archive` connectors are built by default and can be left out with `zig build -Dwikipedia=false`, `-Dfeeds=false` and `-Dcrawler=false` (the last one removes both network connectors). A separate administration interface (sources, import jobs, counters, a query-testing page that shows ranking scores, and optionally starting and cancelling imports) is served on its own address when the configuration has an `[admin]` table and credentials exist; see **admin-token**, **admin-password** and SECURITY CONSIDERATIONS.

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

Usage: dksearch import --config FILE (SOURCE | --all) [--prune]

Arguments: SOURCE, the `name` of a `[[source]]` in FILE. A source with `enabled = false` is not run, and naming one is an error. **--all** runs every enabled source in file order. Exactly one of SOURCE or **--all** is required. **--config** is required, since sources are defined there.

Options: **--prune** also removes the source's documents whose items are no longer in the source, after a run that completed. The `files` connector treats a file that no longer exists (or is no longer a regular file) as gone; the `gutenberg` connector treats a book with no remaining local file as gone. If the source itself cannot be read (the directory is missing or unmounted), nothing is removed. Without **--prune**, re-importing never deletes anything.

Examples: dksearch import --config dksearch.toml my-notes

Connectors that can say why they skipped something (currently `crawl`) add a line such as `web: skipped because: robots=3, http_status=2`. The reasons are `robots` (disallowed by robots.txt, or robots.txt unreadable), `network` (could not connect, or timed out), `certificate` (a TLS certificate that did not verify), `http_status` (an answer other than success), `wrong_type` (not HTML or text), `too_large`, `encoding`, `no_text` (empty, or marked `noindex`), `redirect` (refused or looping) and `limit` (page or site limit, or an unusable URL). They are also kept with each job and shown in the administration interface.

remove
Remove every document of the source named SOURCE from the index, the retained text and the document records, and forget the source's import history, so a later import of that name starts afresh. SOURCE need not be in the configuration file, which is the usual case after deleting a source from it. Without **--yes** nothing is changed: it reports how many documents the source has. Removal works in batches that are committed one at a time, and is safe to interrupt (SIGINT) or repeat: what was not removed yet is removed by the next run. The documents can be restored by importing the source again.

Usage: dksearch remove --config FILE SOURCE [--yes]

Arguments: SOURCE, the name the documents were imported under. **--config** is required because it names the data directory. **--yes** performs the removal.

Examples: dksearch remove --config dksearch.toml old-notes --yes

rebuild
Delete the search index and rebuild it from the retained content and document records, without reading any source. Use it after deleting or losing `index.db`, after a version change, or after changing `index.tokenizer` (rebuild is the one command that recreates the index with a new tokenizer). Documents whose text was not retained (`retain_text = false`) cannot be rebuilt and are reported as skipped. It is safe to run again if interrupted. Searches made while it runs see a partial index, so stop **serve** first if that matters.

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

help
Show help at the terminal: `dksearch --help` lists the commands and topics, `dksearch help COMMAND` (or `dksearch COMMAND --help`) explains one command, and the topics `dksearch help start`, `dksearch help config` and `dksearch help admin` give a first run, the shape of the configuration file and the steps to set up the administration interface.

Usage: dksearch help [COMMAND | start | config | admin]

eval
Measure the ranking. JUDGMENTS is a text file with one JSON object per line, naming a query and the documents relevant to it, by URL or by document id: `{"query": "lighthouse keeper", "relevant": ["https://example.org/keeper"]}`, or with grades from 1 up, `{"query": "tides", "relevant": {"https://example.org/tides": 3, "https://example.org/moon": 1}}`. Blank lines and lines starting with `#` are skipped. Each query is run against the index as **serve** would run it, and the command prints, per query and as means, precision and recall in the first K hits, the reciprocal rank of the first relevant hit, and nDCG (with gain 2^grade-1), then lists judged documents that were outside the first K with their rank (searched to 100). A query the search cannot run (no searchable terms) is reported as failed and scores zero. Nothing is written. Use it to compare settings, such as the tokenizer, on judgments you trust; a handful of queries shows direction, not proof.

Usage: dksearch eval [--config FILE] [-k N] [--json] JUDGMENTS

Arguments: JUDGMENTS, the file described above. **-k** is the cutoff, 1-100, default 10. **--json** prints one JSON object instead of the table.

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
All diagnostics, each prefixed `dksearch: `. **import** and **rebuild** write their one-line result to standard output. **serve** writes a startup line giving the address and index path, and `stopped` after a graceful stop. If the configuration has an `[admin]` table it also reports that the administration interface is serving, or why it was not started (no credentials, unreadable secrets file, address in use). Request logging is off unless `access_log` is set; see PRIVACY. The format of diagnostic lines is not stable.

EXIT STATUS
Status	Meaning
0	Success, including a normal stop of **serve** by SIGINT or SIGTERM, and an **import** in which every run source completed.
1	The server stopped on an unexpected error after starting, an **import** run did not complete (it failed, or was cancelled by a signal), or **check** found damage. The run's state and any resume position are recorded.
2	Invalid command-line usage, including naming a source that does not exist or is disabled.
3	Configuration error: syntax error, unknown key, wrong type, out-of-range value.
4	I/O or resource error: another **import**, **rebuild** or **remove** is running on the same data directory, configuration file unreadable, data directory or index cannot be created or opened, address cannot be bound, a backup could not be written or verified or would overwrite an existing file.
Termination by an unhandled signal (for example SIGKILL or SIGHUP) has the usual status of that signal.

ENVIRONMENT
No environment variables are consulted by dksearch itself.

FILES
dksearch.toml (any name, passed with **--config**)
: Configuration file. There is no default search path.

*data_dir*/index.db
: The search index (SQLite, written in WAL mode), with companion files `index.db-wal` and `index.db-shm` while open. *data_dir* is `storage.data_dir`, default `data`, created with parents if missing. The index is derived data: delete it freely and run **rebuild**.

*data_dir*/admin-secrets.toml
: The administration credential hashes (default location; see `admin.secrets_file`). Mode 0600. Created by **admin-token** or **admin-password**. Back it up with your other secrets; losing it just means creating new credentials.

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
server.access_log	String	none	`stderr` or a file path (appended to): write one line per request to the public listener's access log. Off when absent. See PRIVACY for exactly what a line holds.
admin.*	-	-	The administration listener accepts the same keys as `server.*` (default port 8081, loopback) and the keys below. It must not share an address and port with `server`.
admin.secrets_file	String	`data_dir`/admin-secrets.toml	File holding the credential hashes. Must not be readable by group or others.
admin.session_idle_minutes	Integer	30	A sign-in session ends after this much inactivity, 1-1440.
admin.session_max_hours	Integer	8	A sign-in session ends this long after it began, however active, 1-168.
admin.actions	Boolean	false	Let the administration interface start and cancel imports of configured sources. Off: the interface is strictly read-only.
admin.cookie_secure	Boolean	false	Add `Secure` to the session cookie. Set it when a reverse proxy serves the interface over HTTPS.
index.tokenizer	String	`unicode61`	How text is split and normalised: `unicode61` (case and diacritics folded) or `porter` (the same, plus English stemming, so "running" matches "run"). The index keeps the tokenizer it was built with; after changing this setting **serve** and **import** refuse the old index until **rebuild** recreates it.
storage.data_dir	String	data	Directory for the index and other state. Must not be empty.
source	Array of tables	none	Optional. Each `[[source]]` defines one connector instance; see Sources below.

Sources
Each `[[source]]` table has these keys. Any other key is an option of the connector named by `kind` and is validated by it, so a misspelled option is an error.

Key	Type	Default	Description
name	String	required	Unique name, 1-64 characters of `a-z`, `0-9`, `_` and `-`, starting with a letter or digit. Resume positions are kept per name, and it becomes the `connector` of each document, so renaming a source makes it start afresh and its old documents stay under the old name.
kind	String	required	Connector type. This version knows `files`, `gutenberg`, `wikipedia`, `feeds`, `crawl` and `archive` (the last four only in builds that include them).
enabled	Boolean	true	A disabled source stays in the file but is never run.
retain_text	Boolean	true	Keep each document's text so the index can be rebuilt without reading the source again. Set false for a source whose terms forbid keeping its text; its documents are then skipped by **rebuild**.
rights	String	connector default	Override the redistribution flag (`unknown`, `allowed`, `restricted`, `forbidden`) of every document from this source. Defaults are conservative guesses, not legal advice; the decision is yours. Only documents that are added or changed afterwards pick it up; unchanged ones keep the flag they were stored with.

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

Kind `wikipedia` indexes the articles of a Wikipedia (MediaWiki) XML dump such as `enwiki-YYYYMMDD-pages-articles-multistream.xml.bz2`. It never uses the network: download the dump yourself, from https://dumps.wikimedia.org/ or a mirror, and read the terms there.

Key	Type	Default	Description
dump	String	required	Path of the dump: a `.bz2` file (multistream or single stream) or a plain `.xml` file.
language	String	`en`	Language tag stored on each document.
url_base	String	`https://LANGUAGE.wikipedia.org/wiki/`	Prefix of article URLs; must start with http:// or https:// and end in `/`.
dataset_version	String	none	A label for the dump, such as its date, stored on each document.
max_article_bytes	Integer	8388608	Largest article text accepted, 1-67108864. Larger articles are refused, never truncated.

Only articles are indexed: pages in the main namespace (0) that are not redirects and have text. Other namespaces (talk, user, template, category, file pages) and redirects are skipped. The wikitext is converted to plain text by a deliberately modest converter, so it is good for searching, not a faithful rendering: templates (including infoboxes), tables, references, comments, galleries and math are dropped; links keep their label; bold, italic, list and heading marks are removed; and everything from a "References", "External links", "See also", "Notes", "Further reading" or similar level-2 heading to the end is dropped. The id is derived from the source name and the page id; the revision is the revision id, so a newer dump updates changed articles and skips unchanged ones. Each document records the dataset "Wikipedia", the dump label, the article URL, the revision timestamp as modified date, and rights: the license `CC-BY-SA-4.0` with its URL, an attribution line pointing to the article's page history, and a note about the older GFDL license. Wikipedia's text is free to reuse only under those license conditions, which include attribution and share-alike; the search results show the source so that attribution is possible. Images and other media are not imported.

The position is saved after every bzip2 stream (Wikipedia's multistream dumps hold about 100 pages per stream) or, for a plain XML file, every 100 pages, so an interrupted import of a very large dump resumes close to where it stopped. A single-stream `.bz2` file cannot be entered in the middle and starts over each time, skipping unchanged pages. A truncated or damaged dump fails the job; what was committed before the damage stays.

Example:

    [[source]]
    name = "wikipedia-en"
    kind = "wikipedia"
    dump = "/data/wikipedia/enwiki-20260101-pages-articles-multistream.xml.bz2"
    dataset_version = "20260101"

Kind `feeds` indexes RSS 2.0, RSS 1.0 (RDF) and Atom 1.0 files. It never uses the network: fetch the feeds yourself (a scheduled `curl` into a directory works, see `docs/deploy/README.md`) and point the source at them.

Key	Type	Default	Description
path	String	required	A feed file, or a directory of feed files (`.xml`, `.rss`, `.atom`, `.rdf`, in subdirectories too; hidden entries and symbolic links are skipped).
language	String	the feed's own	Language tag for every entry, overriding the language a feed declares.
max_file_bytes	Integer	16777216	Largest feed file accepted, 1-67108864. Larger files are refused.

Each entry becomes a document. Its text is the full content if the feed has one, else the summary, else the title, converted from HTML to plain text (tags removed, paragraphs kept as lines, scripts and styles dropped, entities decoded). The document id is the entry's `guid` or Atom `id`, or its link; an id that is not URL-like (for example `42`) is prefixed with the feed's link so that different feeds cannot collide. Fetching the same feed into the same file again updates entries whose text changed and skips the rest. Each document records the feed title as its source and attribution, the entry's link, author, categories and dates, and rights `unknown`: a feed does not say what you may do with its entries, so the content is treated as belonging to its publisher. A file that cannot be parsed, or an entry with no id and no link or no text, is counted as skipped, and the run continues. Only the XML encodings UTF-8, UTF-16, ISO-8859-1 and US-ASCII are understood: a feed declaring another encoding (such as windows-1252) is skipped as unparseable; convert it first. Dates before 1970 are ignored.

Example:

    [[source]]
    name = "news"
    kind = "feeds"
    path = "/srv/feeds"

Kind `crawl` fetches the web pages listed in a file and indexes each as one document. It is the only connector that uses the network, and it does nothing unless a source of this kind is configured and imported. It is built to be polite: it reads `robots.txt` (RFC 9309) before any page of a host and never requests a page the file disallows; it keeps at least `delay_ms` between requests to one host, one request at a time (a larger `Crawl-delay` in `robots.txt`, up to 60 seconds, is honored); it sends exactly the user agent you configure; it follows redirects only within the same site (a leading `www.` is ignored), checking `robots.txt` again for each step, at most 5; and every request has a deadline and a size cap. A `robots.txt` that cannot be fetched (network error, server error, oversized, or redirected to another site) disallows that host for the run; an answer of 4xx means it has no rules. From each URL listed it follows links to other pages of the same site, down to `max_depth`, and a line of the form `sitemap URL` in the seeds file makes it fetch the pages that sitemap lists. By default it never leaves the site of the URL it started from (see `follow_external`), and a page that says `<meta name="robots" content="noindex">` is not stored (`nofollow` stops its links being followed, as does `rel="nofollow"` on a single link).

Key	Type	Default	Description
user_agent	String	required	The `User-Agent` header, 1-200 printable ASCII characters starting with a product name, for example `mysearch/1.0 (+https://example.org/about)`. There is no default: choose a name and a way for site owners to reach you. The product token (up to the first `/`, space or `(`) is what `robots.txt` groups are matched against.
seeds_file	String	required	A text file with one entry per line: an absolute `http://` or `https://` URL, or `sitemap URL` for a sitemap or sitemap index (XML, plain or gzip-compressed (`sitemap.xml.gz`, at most 10 MiB once decompressed); a sitemap can only name pages of its own site, and its pages are fetched without following their links). Blank lines and `#` comments are skipped; lines that are not usable URLs (no host, other schemes, credentials in the URL) are ignored. Several seeds may share a site. At most 10000 URLs are read. Re-read at every run.
delay_ms	Integer	1000	Minimum milliseconds between two requests to the same host, 100-3600000.
max_depth	Integer	3	How many links deep to follow from each listed URL, 0-10. 0 fetches only the listed URLs. Links to other sites, to obvious non-page files (images, archives, PDFs, scripts) and `mailto:` and similar are never followed. A page is fetched at most once per run.
max_pages	Integer	1000	Most pages requested in one run (`robots.txt` not counted), 1-1000000. When it is reached the run ends normally; raise it to crawl more. The same pages are reached first next time, so this bounds a run, it does not resume a large crawl.
follow_external	Boolean	false	Also follow links, and redirects, to other sites, within `max_depth` and `max_pages`. Each new site gets its own `robots.txt` check and its own delay. Links to private or local addresses (localhost, names with no dot or ending in `.local`, `.internal` or `.lan`, IPv6 literals, and IPv4 addresses in private, loopback, link-local and reserved ranges) are still refused unless `allow_private_addresses` is true; this stops a public page from steering the crawler at your own network. A name that merely resolves to a private address is not detected, so run the crawler where such requests cannot reach anything sensitive.
allow_private_addresses	Boolean	false	Let `follow_external` reach private and local addresses too. Seeds you list yourself are always fetched.
max_hosts	Integer	100	Most different sites (scheme, host and port) one run contacts, 1-100000; pages of further sites are skipped.
max_page_bytes	Integer	2097152	Largest response body accepted (after decompression), 1-33554432. Larger pages are skipped.
timeout_seconds	Integer	30	Deadline for one request (connect, send and receive), 1-300.
ca_bundle	String	builtin	Which certificates HTTPS servers are verified against: `builtin` (the Mozilla root store embedded in the program, `vendor/cacert/README.md`), `system` (the operating system's store), or the path of a PEM file. A server whose certificate does not verify is skipped; there is no way to turn verification off.
language	String	none	Language tag recorded for every page.

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

Key	Type	Default	Description
query	String	required	An Internet Archive search query, as on archive.org's advanced search, for example `collection:gutenberg AND mediatype:texts` or `subject:lighthouses`.
user_agent	String	required	The `User-Agent` header, as for `crawl`: printable ASCII starting with a product name and a way to reach you.
max_items	Integer	10000	Most items indexed in one run, 1-100000000. The default is small on purpose: some collections hold millions of items. When the limit is reached the run ends normally and the next run starts from the beginning again, so raise it to index more.
count	Integer	1000	Items asked for per request, 1000-10000. The service documents a minimum of 100, but pages of 200 or fewer returned wrong results when this was tried, so the connector never asks for fewer than 1000.
delay_ms	Integer	1000	Milliseconds between requests, 100-3600000.
timeout_seconds	Integer	30	Deadline for one request, 1-300.
base_url	String	`https://archive.org`	Where the service is; for a mirror. Must start with http:// or https:// and have no trailing slash.
ca_bundle	String	builtin	As for `crawl`.
language	String	none	Language tag recorded for every item (the Archive's own language field is kept as `archive_language`).

Each item becomes one document identified by its Archive identifier, with the URL `https://archive.org/details/IDENTIFIER`. Its text is the title, the creator, the description (converted from HTML to text) and the subjects. The date, the date added to the Archive, the media type, the creator as author and a `licenseurl` are recorded. Rights are `unknown`: the Archive's metadata says what an item is, not what you may do with its content, and each item has its own terms. Items without a usable identifier or without any text are counted as skipped. A request that fails after some pages were indexed ends the run as failed, with the position saved; the next run resumes from it. A first request that cannot connect ends the run as Offline. The service may return fewer items than exist, or change between pages, as the Archive notes; run again to pick up changes.

Example:

    [[source]]
    name = "prelinger"
    kind = "archive"
    user_agent = "mysearch/1.0 (+https://example.org/about)"
    query = "collection:prelinger AND mediatype:movies"
    max_items = 2000

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
**check** prints one line per database and the verification totals, then `ok` and exit status 0, or a `problem:` line and exit status 1 when it finds damage. To restore, stop dksearch, move the damaged files out of `data_dir`, and run `dksearch restore --config dksearch.toml /backups/dksearch-2026-11-14`; it verifies the backup, copies it in and recreates the index.

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
The public HTTP listener has no authentication; the search API is read-only and intended to be public if the administrator exposes it. It listens on loopback by default. To expose it, set `server.address` explicitly. Prefer a reverse proxy for TLS (not implemented here) and rate limiting.

The administration interface is a separate listener (default 127.0.0.1:8081) and separate code; nothing on the public listener reaches it. Everything on it except the sign-in page and the style sheet needs a credential: a bearer token (for scripts) or a session obtained by signing in with the password or the token. Credentials are kept only as hashes (SHA-256 for the token, Argon2id for the password) in `admin.secrets_file`, never in the main configuration, and the file is refused if group or others can read it. The secrets file is read again for every check, so replacing a credential takes effect immediately and ends all sessions. Sessions live only in memory (a restart signs everyone out), use an unguessable 256-bit id in an `HttpOnly`, `SameSite=Strict` cookie, expire after the idle and absolute limits, and every state-changing request is a POST that also carries a per-session form token. Failed attempts are slowed down for the whole process (none for the first three, then 250 ms doubling to 5 s, forgotten after 15 quiet minutes; wrong bearer tokens are not counted), at most four attempts wait at once (more get status 429) and at most two password checks run at once; there is no per-client tracking, because client addresses are not recorded, so an attacker who keeps failing also slows the administrator's own form sign-ins down (the token is not affected). If the `[admin]` table exists but there is no credential, the administration interface does not start and the reason is printed; there is no default password. By default it is read-only. With `admin.actions = true` it can also start an import of a configured, enabled source and cancel the running one (never rebuild, remove, back up or change configuration), under the same authentication, with the form token required for browser sessions. Imports started this way take the same data-directory lock as the command line, so they cannot overlap a command-line import, rebuild or removal. Which paths a source reads comes only from the configuration file, not from the request. It transmits the token or password in clear text unless HTTPS is provided by a reverse proxy, so keep it on loopback or put it behind one (and set `admin.cookie_secure = true`).

Trust boundaries: all request data is untrusted. Request heads are size-limited and must complete within a deadline; a client sending data slowly cannot hold a connection open past it. Request bodies are refused. Query text is never interpreted as search-engine syntax: operators, column filters and punctuation are searched as ordinary text, and queries are limited to 1024 bytes and 32 terms. Result pages escape all text, link only http and https URLs, and are sent with a Content-Security-Policy that forbids scripts and external resources. Database error details are never sent to clients. These properties are covered by the project's tests; they are not an audit.

SQLite is compiled without extension loading, so no native code is loaded at run time.

The index directory should be writable only by the account running dksearch. The configuration file holds no secrets; the credential hashes are in the separate secrets file, which should be readable only by the account running dksearch.

The `crawl` connector fetches pages as untrusted input: HTML is reduced to text and never interpreted, bodies are size-capped, redirects stay on the same site, HTTPS certificates are always verified, and the response of a site is never trusted to name where to fetch next. It does not block requests to private or loopback addresses on the sites you list, so do not list internal hosts you would not want indexed. The `feeds` connector treats feed files as untrusted input in the same way (no XML entity expansion, document type declarations refused, bounded nesting and field sizes, HTML reduced to text and never interpreted), and reads only the files under `path`. Feed content is third-party text that becomes searchable and is shown in results.

The `wikipedia` connector treats the dump as untrusted input: it refuses any XML document type declaration (so entity-expansion attacks cannot work), bounds nesting depth and the size of every field and article, converts the text in time linear in its size, and executes nothing. It reads only the one file named by `dump`. The bundled bzip2 and Expat libraries are vendored, and Expat is built without general entity expansion or DTD support.

The `gutenberg` connector treats the catalog and the book files as untrusted input: it bounds field and file sizes, refuses malformed catalogs and invalid text, derives file names only from validated numeric catalog ids, never follows symbolic links, and executes nothing. Project Gutenberg's license and trademark terms apply to the books you import; read them at https://www.gutenberg.org/policy/license.html before redistributing text or running a public service with it.

The `files` connector treats the directory tree as untrusted input. It never follows symbolic links, skips hidden entries, reads only regular files with the expected extensions, enforces a size limit, rejects invalid text, and executes nothing. It indexes only what its account can read, and the text of every indexed file becomes searchable and is shown in results, so point it only at directories whose contents may be searched by everyone who can reach the server. Result URLs for these files are `file://` URLs, which the HTML page shows as plain text, not links.

PRIVACY
dksearch sends no telemetry and contacts no external service. Nothing about requests is written anywhere unless you set `access_log`. In memory only, the server keeps counters (requests by status class, response-time buckets, connections accepted, refused and timed out), shown on the administration dashboard and lost at exit. With `access_log` set, each request adds one line with exactly these fields: UTC time, method, a fixed route label such as `/search` (never the actual URL), status, duration in milliseconds, and response bytes. Query text, URLs, client addresses, user agents, cookies and credentials are never logged. Rotating the log is up to the operator (logrotate with `copytruncate` works; restarting reopens it). **import** records, in `state.db`, the name, time, counts and last position of each run; it does not record file contents beyond what is indexed. Anything placed in front of it, such as a reverse proxy, has its own logging.

RESOURCE USAGE
**import** processes one document at a time and holds one batch open (at most 1000 documents, or fewer when the connector saves positions more often) in database transactions before committing it. The `files` connector keeps the sorted list of file paths in memory and reads one file at a time. **serve** memory per connection is the configured `max_header_bytes` read buffer, a 4096-byte write buffer, and the arena for the current request, whose size is bounded by the response (at most 100 hits). Each connection uses one task. At most `max_connections` connections exist at once. These are design bounds; measured figures for a 20,000-document index (about 35 MB resident for **serve**, index files about 2.2 times the text size) are in `docs/performance.md`.

PERFORMANCE
Search time is that of SQLite FTS5 over the index. **serve** answers searches on a pool of read-only index connections (the smaller of the CPU count and 8, at least 2), so concurrent searches run in parallel. On a synthetic index of 20,000 articles, one client saw a median of 15 ms and a 99th percentile of 43 ms per query, and four clients together reached about 230 queries per second; see `docs/performance.md` for the method, the caveats and what was not measured. Real data at scale has not been measured. Results are limited to a window of 10000 (offset plus limit) to bound deep-pagination cost.

CONCURRENCY AND ATOMICITY
Requests are served concurrently. Do not run two servers on the same `data_dir`. **import**, **rebuild** and **remove** take an exclusive lock on `data_dir/write.lock`, so a second one refuses to start (exit status 4) while another runs; the operating system releases the lock when the process ends, even after a crash, and the lock file itself is harmless and may stay. **check** and **backup** may run at any time. Running **serve** while **import** writes is supported: readers are not blocked, and new documents appear when each batch commits.

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
Six connectors are bundled (`files`, `gutenberg`, `wikipedia`, `feeds`, `crawl` and `archive`); only `crawl` (for the URLs you list) and `archive` (for the Archive's search service) use the network. It follows only same-site links up to `max_depth` unless `follow_external` is set, reads uncompressed sitemaps, sends no conditional requests, has no proxy support and understands few text encodings. The `gutenberg` connector reads only the CSV catalog, not the RDF catalog, and does not unpack archives or read HTML or EPUB books. Documents whose items vanished from a source are removed only with **import --prune**, and only the `files` and `gutenberg` connectors can tell. Backups are manual (no scheduling or retention) and the copies are not encrypted. The administration interface cannot run **check**, **rebuild**, **remove** or **backup**, or edit configuration; it can start and cancel imports only when `admin.actions` is true. No TLS. No reload or request log. Only two tokenizers exist: `unicode61` and `porter` (English stemming). Languages without word separators (such as Chinese or Japanese) are not segmented well, and stemming is English only. Index size and query time at large scale (millions of documents) have not been measured.

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
Deleting `index.db` is safe: **rebuild** restores it. Deleting `state.db` or `content.db` is not: they are the only copy of what was imported, and an index cannot be rebuilt without them. Back them up with **backup**, and check them now and then with **check**; do not copy the files with `cp` while **import** runs, because the write-ahead log (`-wal`) files must be copied with them to be consistent. Re-importing never deletes documents whose source items were removed unless you pass **--prune**; **remove** deletes a whole source.

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
