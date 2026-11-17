% DKSEARCH-API(7) Version 0.0.0 | Project Manual
% dksearch contributors
% 2026-11-14

NAME
dksearch-api - HTTP interface of dksearch: JSON API version 1 and the HTML search page

SYNOPSIS
GET /api/v1/search?q=TEXT[&language=L][&content_type=T][&connector=C][&source=S]...[&filter=F]...[&sort=ORDER][&explain=1][&limit=N][&offset=N][&regex=PATTERN[&regex_flags=i][&regex_dialect=perl|ere]]

GET /api/v1/retrieve?q=TEXT[&source=S]...[&filter=F]...[&k=N][&candidates=N][&context=N][&chunk_chars=N][&overlap=N][&dedupe=0]
: Passages for a RAG client: the best chunks of the documents a search for `q` finds. `q`, `source`, `connector` and `filter` mean what they mean for search (`regex` is not available here), and `q` needs at least one word to look for. A question in plain words is searched by its meaningful words joined by OR ("What did the ravens of Odin do?" looks for ravens or Odin; the most common English words are left out), so a passage need not contain every word; a query that uses the query language is searched as written. The same work in several formats in one source (`book.md`, `book.epub`, `book.pdf`) counts once, the format with the most structure being kept (Markdown, HTML, EPUB and Office formats before PDF); `dedupe=0` keeps them all, and `duplicates_merged` says how many were folded in. The picture addresses are served by the search server (`GET /doc/ID/image/N`, PNG, JPEG, GIF or WebP only, only for sources with `serve_originals`). A `page` comes from the stored text's own page breaks (`page_source` "text": PDF text has them after it is imported again) or, for a Markdown copy without them whose PDF copy is in the same source, by matching the passage's words against the PDF's pages (`page_source` "pdf"; a good guess, not a proof); otherwise it is null. Documents of at least `search.chunk_index_min_kb` (default 64) KiB also have their passages in a chunk index, so a passage inside a very large document is found even when the document as a whole ranks low; for those, `chunk_chars` and `overlap` do not apply (the index's own chunking, 1200 and 150, is used). The first `candidates` documents (default 30, at most 100) have their stored texts split into chunks of about `chunk_chars` bytes (default 1200, 200 to 8000, cut at paragraph ends and never across a heading unless the section is tiny) with `overlap` bytes (default 150) of the previous chunk repeated, and the chunks are ranked on the query's words with BM25 (a word in a heading counts double). Returns `chunks` (at most `k`, default 8, at most 50), `candidates` and `without_text` (candidates that have no stored text). Each chunk has `doc_id`, `view_url`, `source`, `title`, `url`, `heading` (the headings above it, outermost first), `index` and `of` (its place among the document's chunks), `start` and `end` (its byte span in the document's stored text), `page` (see below) and `page_source`, `entries` (bold terms that open paragraphs, which is how encyclopedias converted to Markdown mark their entries: what the passage is about), `score`, `text`, and `before` and `after`: the texts of up to `context` neighbouring chunks (0 to 3, default 0), and `images`: the pictures of the original file that sit in the passage (Markdown converted from a PDF carries its figures), each with its number `n` and, when the source serves its original files, its address `/doc/ID/image/N`. Chunks are made when asked, from the stored text, so nothing needs rebuilding. With `peers=1` the configured peers (see `peers` under `/api/v1/search`) are asked for their best passages for the same `q` (with `k`, `context`, `chunk_chars` and `overlap`, and twice the usual time limit), and the passages are merged with this node's by reciprocal-rank fusion (BM25 scores of different indexes are not comparable); the same passage of the same web page on several nodes counts once and names the others in `also_on`. A passage from a peer has `node` (its name), a `view_url` that is an absolute address on that peer, and no `images` (their addresses need the peer's key). The response gains `peers`, one entry per asked peer as for search; it is null when peers were not asked for, and peers are never asked for a caller whose view is limited. Errors: 400 `invalid_parameter` or `empty_query`, 503 `no_content` when nothing has been imported yet.

AUTHENTICATION
: By default the search API needs no key. A server can limit what anonymous callers see (`[access] anonymous_collections`) and issue API keys (`dksearch api-key add`). A key is sent as `Authorization: Bearer dkk_...` and restricts the results of `/api/v1/search` and `/api/v1/retrieve`, and the documents, pictures and articles under `/doc/` and `/zim/`, to the collections it was made for. Signed requests: a request may carry `dk-node` (the sender's node id, `dkn_...`), `dk-time` (Unix seconds), `dk-nonce` (22 characters) and `dk-sig` (base64url Ed25519 signature of `"dksearch-v1 request\n" METHOD "\n" TARGET "\n" HOST "\n" TIME "\n" NONCE`, with TARGET the request target as sent and HOST the lower-case `Host`). A key bound to a node (`api-key add --node`) is accepted only with a valid, recent, unused signature by that node (401 `invalid_key` otherwise, the message says why). A caller that sends `dk-nonce` (signed or not) to a node that has an identity gets `dk-node` and `dk-sig` on the answer: a signature of `"dksearch-v1 response\n" NONCE "\n" STATUS "\n" SHA256-HEX-OF-BODY`. See NODE IDENTITY in **dksearch**(1). Errors: 429 `rate_limited` (with `Retry-After`, in seconds) for a key over its per-minute limit (`dksearch api-key add --rate`; every request with the key counts, the others are not affected); 401 `invalid_key` for a key that is not valid or is sent to a server with no keys, 401 `key_required` when the server gives anonymous callers nothing (`/api/v1/health` stays open). A document outside the key's scope is answered with 404, the same as one that does not exist. The `collection:NAME` filter of the query language and `source=collection:NAME` select a collection within the scope.

GET /api/v1/export
Copy the documents of a source to a peer that replicates them (`kind = "peer"`, see **dksearch**(1)).

Parameters:
source
: Required. The name of a source whose owner set `share = true`.

after
: Optional. The `next` value of the previous answer; the first page without it.

limit
: Optional. Documents per page, 1 to 200, default 50. A page is also cut at 16 MiB of text.

Needs an API key (`Authorization: Bearer dkk_...`) whose collections include the source, whatever the anonymous setting of the server: 401 `key_required` without one. A source that does not exist, is off, is not shared, has `rights = "forbidden"` or is outside the key's collections answers 404 `not_shared`. The answer is `{"source": NAME, "documents": [...], "next": CURSOR or null}`. Each document has `id`, `ident` (see `/api/v1/search`), `source`, `url`, `title`, `text` (the full stored text; documents with no retained text or over 4 MiB are left out), `language`, `content_type`, `modified_at`, `published_at`, `author` and `redistribution` (what the source's owner says may be done with the text: `unknown`, `allowed` or `restricted`). Pages are in a stable order, so a replica can continue from a cursor.

GET /api/v1/peers
The peers this node is willing to introduce to the nodes it answers (`introduce = true` on the `[[peer]]`, and enabled). Needs an API key, like `/api/v1/export`. The answer is `{"node": NAME, "peers": [{"name": ..., "url": ...}]}`: names and addresses only, never keys. They are suggestions: the asking node's operator decides whether to add any, and needs a key from that peer's own node.

GET /api/v1/health

GET /, GET /search?q=TEXT[&language=L][&source=S]...[&connector=C][&offset=N]

GET /help/search and GET /help/regex\nHTML pages that explain the query language (with typo tolerance) and, when the server offers it, the regular-expression filter with the limits this server applies. `/help` is the same as `/help/search`. The search form links to both.\n\nGET /assets/style.css

DESCRIPTION
The public, read-only interface served by dksearch(1). It needs no authentication. Every endpoint accepts GET and HEAD only; any other method receives 405 with `Allow: GET, HEAD`. Request bodies are refused with 400 and the connection is closed.

There are two adapters over the same search service. The JSON API under `/api/v1/` is for programs. The HTML pages are for people and need no JavaScript.

CONVENTIONS
Parameter values are percent-encoded; `+` in a query string means a space. Parameter and path names are case-sensitive. Paths are matched exactly: they are not percent-decoded, and a trailing slash is a different path. If a parameter is repeated, the first occurrence is used. Unknown parameters are ignored.

COMMANDS
GET /api/v1/search
Run a search.

Parameters:
q
: Required. The text to search for, in a small query language. Words are combined with AND. Text in double quotes is a phrase. `OR` and `NOT` (capitals; `AND` too) combine terms, parentheses group them, a leading `-` excludes a word and a leading `+` is accepted (the word is required, as it already is), `comp*` matches words starting with comp, `word~` matches the word or any word one typo away, and `"two words"~5` matches the words within five positions of each other. In lower case `and`, `or` and `not` are ordinary words, and any operator can be searched for literally by quoting it. `title:word` and `body:word` (or `title:(a OR b)`) restrict words to the title or the text. Conditions on the document can be written in the query too: `ext:pdf`, `type:image` (page, text, markdown, pdf, image, video, audio, data, other), `mime:text/*`, `source:NAME`, `lang:en`, `site:example.org` (also `domain:`), `path:/docs/`, `author:"Jo Smith"`, `tag:linux`, `meta.NAME:text`, `size:>1mb` (also `<10k`, `10k..2mb`), `modified:>2026-01-01`, `modified:2026-03`, `modified:7d`, `created:` and `indexed:` likewise; a minus in front leaves matching documents out, and the same condition repeated (`ext:pdf ext:md`) means either. A search of conditions alone lists the matches, newest first. `re:/pattern/` or `re:/pattern/i` is a regular expression (see `regex` below). `^`, `NEAR(...)` and all other index syntax are never interpreted: they are searched as ordinary text. The parser is forgiving: a stray `)` is ignored and a missing one supplied. A query needs at least one word that is not excluded. At most 1024 bytes, 32 terms and 8 levels of parentheses. A query with nothing searchable is an `empty_query` error. A server can turn the language off (`[search] query_syntax = "simple"`), in which case every word is plain text.

fuzzy
: Optional typo tolerance. By default (`[search] fuzzy = "auto"`) a search that finds fewer than three results is repeated with every word of four or more letters also matching the words of the index that are a typo away (a letter missing, extra, wrong or swapped; two typos for words of six letters or more), and the response says so. In the query, `word~` does the same for one word, `word~1` and `word~2` fix the number of typos. `fuzzy=1` always allows typos and `fuzzy=0` allows none (exact words only); anything else is `invalid_parameter`.

filter
: Optional, may be repeated (at most 16, each at most 200 characters): one condition in the query language's spelling, such as `ext:pdf`, `-domain:example.org`, `size:>1mb` or `modified:7d`. Every condition must hold, except that the same kind repeated means either. It works like writing the condition in `q`, and lets a program keep the words and the conditions apart. A condition that is not one (an unknown name, a value that makes no sense) is `invalid_query`. A search made only of `filter` parameters, with `q` empty, lists the matches.

sort
: Optional order of the results: `relevance` (the default), `newest` or `oldest` (by the date the source gave, else the date it was added), `largest` or `smallest` (by the size of the file when the source knows it, else of the text) or `title` (A to Z, ignoring case). Documents without the date or size come last. Ties fall back to relevance. Other values are `invalid_parameter`. Ordering by anything but relevance has to rank every matching document, so on a very large index a very common word may reach the time limit (503 `search_timeout`).

source
: Optional, may be repeated (at most 64): a source name, or `kind:NAME` for every source of a kind (`kind:zim`). Several are alternatives. Without any, all sources are searched. Together with `connector` they are all alternatives.

language, content_type, connector
: Optional exact-match filters on the document's language tag, media type and source connector. At most 64 bytes, no control characters. An empty value means no filter.

peers
: Optional. `1` also asks the configured peers (other dksearch nodes, `[[peer]]` in the configuration) the same `q` and merges their results with this node's by reciprocal-rank fusion (the sum of 1/(60 + rank) over the lists a page is in; scores are not comparable between indexes). Only `q` and the page size are sent on, with this node's key for that peer; `source`, `filter` and the other parameters apply here only, and a peer never asks its own peers. Each result of a peer has `node` (the peer's name, null for this node's own), a `view_url` that is an absolute address on that peer, and `also_on`, the other nodes that have the same page (every result and passage has an `ident`, 32 hex digits that do not depend on the node: for a web page the hash of its address apart from scheme, host case, fragment and trailing slash, so the same page is the same everywhere; for any other document the hash of its stored text, so the same file on two nodes, under any name or path, is one result; null for a document with neither an address nor stored text. Peers' `ident`s are only used to decide what is the same, and ignored unless well formed). The response gains `peers`: one entry per asked peer with `peer`, `status` (`ok`, `timeout`, `down`, `refused`, `bad_answer`, `backoff` after recent failures, `unavailable`), `ms`, `results`, `cached` (true when the answer is a recent one reused, see `search.peer_cache_seconds`) and, for a refusal, `http_status`. A slow or failing peer never delays the local results beyond its own time limit (`timeout_ms`, default 1500), and `peers` is null when it was not asked for. Ignored (with `peers` null) when the caller's view is limited by a key or the anonymous setting, when `offset` is not 0, and when no peer is configured. The pager of the page does not carry peers to later pages.

semantic
: Optional. `1` re-orders the results by meaning (see SEMANTIC SEARCH in **dksearch**(1)): the lexical results, a wider pool than the page, are fused by reciprocal rank with their similarity to the query as judged by the embedding model of `[embeddings]`. First page only. The response gains `semantic`: `used`, `model`, `compared` (how many results had a vector) and, when not used, `reason`; null when not asked for.

group
: Optional. `1` folds results that are the same document (same `ident`) into the first, which lists the other sources that hold it in `same_in`. Not used with `peers=1`.

explain
: Optional. `1` adds the parts of each hit's score (`explain` object), to see why a result ranks where it does.

limit
: Optional page size. Default 10, maximum 100.

offset
: Optional number of hits to skip. `offset + limit` may not exceed 10000. With `regex`, it counts matching hits.

regex, regex_flags, regex_dialect
: Optional regular-expression filter. The words in `q` choose the candidate documents through the index, in ranking order; the pattern is then checked against each candidate's stored text and only matching documents are returned, with a snippet around the first match (marked with the same `\u0002` and `\u0003` bytes). `q` must therefore contain at least one word: the filter never scans the whole corpus. `regex_flags` may be `i` for ignore case. `regex_dialect` is `perl` (the default: classes, groups, alternation, repetition, lazy and possessive quantifiers, back-references, look-around, `\d \w \s \b`) or `ere` (POSIX extended). The pattern is matched on bytes, not characters, so `.` matches one byte of a multi-byte character; unsupported constructs (for example `\p{L}`) are refused. The server limits it strictly (see `[search]` in dksearch(1)): at most 200 bytes of pattern, 200 candidate documents, 500 ms in total and a bounded number of matching steps per document by default. The response then has an additional member, `"regex": {"examined": N, "truncated": B}`: how many candidates were checked, and whether a limit ended the search early, so that more matches may exist (`has_more` is then true as well). Errors: 400 `invalid_pattern` (with the reason and position), `invalid_parameter` for bad flags or dialect, `empty_query` when `q` has no words, `regex_disabled` when the server has turned the filter off; 422 `pattern_too_complex` when the pattern ran out of steps on several documents; 429 `busy` (with `Retry-After`) when too many regex searches are running. Any search, with or without `regex`, answers 503 `search_timeout` (with `Retry-After: 5`) when it ran past the server's time limit, which happens for very common words on a very large index; use more specific words.

Response: 200 with `application/json`:

    {
      "hits": [
        {
          "id": "2715fef3ff2a8b8ffcb1039525a6e4d5",
          "connector": "gutenberg",
          "url": "https://example.org/pg1342",
          "title": "Pride and Prejudice",
          "snippet": "It is a \u0002truth\u0003 universally acknowledged",
          "score": 0.42,
          "view_url": "/doc/2715fef3ff2a8b8ffcb1039525a6e4d5",
          "language": "en",
          "content_type": "text/plain",
          "kind": "text",
          "domain": "example.org",
          "author": null,
          "size": 718345,
          "modified_at": 1700000000
        }
      ],
      "has_more": false,
      "interpreted": null,
      "fuzzy": false
    }

`interpreted` is how the query was read, as text like `linux OR bsd NOT android`, when it used the query language or typo tolerance, and null for plain words. `fuzzy` is true when the results include words one typo away from those typed. `id` is the 32-hex-digit stable document id. `url`, `title`, `snippet`, `language`, `content_type`, `kind`, `domain`, `author`, `size` and `modified_at` may be null (a source need not know them; documents indexed before these were recorded have none until they are imported again or the index is rebuilt). `view_url` is the document's page on this server, with its details and stored text. `kind` is page, text, markdown, pdf, image, video, audio, data or other; `domain` is the host of the address; `size` is in bytes; `modified_at` is Unix time in seconds. `score` is higher for better matches and is comparable only within one response. It is the weighted text match (title and text, `[search] title_weight` and `body_weight`) times the source's `boost` and, if `[search] recency_boost` is set, a factor for how new the document is. With `explain=1` every hit also has an `explain` object: `text` (the weighted text match), `source` (the boost factor) and `recency` (the age factor), with `score` = `text * source * recency`, plus `title` and `body`, how well the title and the text match on their own (unweighted; they do not add up to `text`, because the search engine weighs word counts before it saturates them). Without `explain` the member is null. Hits are ordered by score, ties by id, so paging an unchanged index is stable. `has_more` says whether another page follows. `snippet` brackets matched text with the control characters U+0002 and U+0003 (JSON `\u0002`, `\u0003`); a client must escape the text for its output format first and only then replace the markers with its own markup. Snippets come from untrusted documents and may themselves contain such characters.

GET /api/v1/health
Returns 200 and `{"status":"ok"}`. It reports that the process is serving requests and nothing about the index.

GET /search and GET /
HTML pages. `/` is the search form. `/search` takes `q`, `language`, `source` (repeatable: one per ticked source, a source name or `kind:NAME` for all sources of a kind; the Source list on the page is a set of tick boxes, none ticked means all), `connector` (one source, as before), `sort`, `offset`, `fuzzy` and, when the server offers it, `regex` and `regex_flags` (on the page a pattern is written in the search box as `re:/pattern/` or `re:/pattern/i`, with a minus in front to keep only documents that do not match; the same form works in the `q` parameter of the API and cannot be combined with `regex`); the page size is fixed at 10 and any `limit` is ignored. Result URLs are links only if they begin with `http://` or `https://`; otherwise they are shown as text. An empty `q` shows the form again.

GET /assets/style.css
The stylesheet, cacheable for one hour. All other responses are `Cache-Control: no-store`.

OPTIONS
None beyond the query parameters above.

OPERANDS
None.

INPUT
Request heads larger than `server.max_header_bytes` receive 431. A request target is at most 8192 bytes, must start with `/`, may not contain spaces or control characters, and may have at most 32 query parameters; otherwise the response is 400 with a plain-text body. Percent-escapes must be valid and decode to valid UTF-8.

OUTPUT
Errors from `/api/` have the form:

    {"error": {"code": "empty_query", "message": "the query has no searchable terms"}}

Code	Status	Meaning
invalid_parameter	400	A parameter is malformed (for example `limit=abc`); the message names it.
empty_query	400	`q` is missing or has no searchable terms.
invalid_query	400	The query is too long or has too many terms, or `limit`/`offset` are out of range.
not_found	404	No such endpoint.
method_not_allowed	405	Method other than GET or HEAD.
internal_error	500	The search failed. The cause is never included; it is for the operator's logs.

Messages are for humans and may change; the codes are stable. Every response, including errors, carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cross-Origin-Resource-Policy: same-origin` and a Content-Security-Policy with `default-src 'none'` that allows stylesheets and scripts only from the same origin, never inline (the only script is the administration interface's `/assets/admin.js`, which updates import progress; the public interface serves none). HTML responses are `text/html; charset=utf-8`; JSON is UTF-8.

EXIT STATUS
Not applicable.

ENVIRONMENT
Not applicable.

FILES
Not applicable.

CONFIGURATION
Limits are set in the `[server]` table of the configuration file; see dksearch(1).

EXAMPLES
Basic use
    curl 'http://127.0.0.1:8080/api/v1/search?q=truth'

Phrase, filtered, second page
    curl 'http://127.0.0.1:8080/api/v1/search?q=%22truth+universally%22&language=en&limit=10&offset=10'

DIAGNOSTICS
A 400 with a plain-text body means the request target itself was malformed. A connection closed without any response means a limit or timeout in dksearch(1) was exceeded.

SECURITY CONSIDERATIONS
See dksearch(1). In particular, never insert `snippet` into HTML without escaping it first.

PRIVACY
The API sets no cookies and keeps no per-client state.

RESOURCE USAGE
A response contains at most 100 hits.

PERFORMANCE
Not measured.

CONCURRENCY AND ATOMICITY
Each request is independent. A search sees a consistent snapshot of the index.

SIGNALS
Not applicable.

NETWORK
HTTP/1.1 over plain TCP; keep-alive is supported. See dksearch(1) for timeouts and connection limits.

COMPATIBILITY
Platforms
Any HTTP client.

Standards
JSON (RFC 8259); HTTP semantics (RFC 9110) as far as implemented.

Stability guarantees
Within `/api/v1/`: adding response fields or optional parameters is allowed, so clients must ignore unknown fields. Removing a field, changing its meaning, or changing error codes requires a new version `/api/v2/`. A superseded version stays available for a documented period. The HTML pages and their markup are not part of the stable API.

ADMINISTRATION API
The administration interface is a separate listener (see dksearch(1), `admin.*`), not part of the public API above. It has the same conventions (JSON, `error` objects with stable codes, `no-store`), accepts GET and HEAD for data, and requires authentication: `Authorization: Bearer TOKEN` (see **dksearch admin-token**) or a session cookie from signing in at `/login`. Without it the API answers 401 with `WWW-Authenticate: Bearer` and code `unauthorized`; pages redirect to `/login`. The endpoints below are read-only except the two that start and cancel imports, which work only when the server is configured with `admin.actions = true` (otherwise they answer 403 with code `actions_disabled`).

GET /api/v1/admin/status
: Returns `version`, `uptime_seconds`, `documents` (total), `data_bytes` (`index`, `state`, `content`, null when a file is absent), `auth` (`token`, `password`: whether set; `sessions`: live sessions), and the counters `public` and `admin`, each with `requests`, `status_2xx` to `status_5xx`, `latency_le_10ms`, `latency_le_50ms`, `latency_le_250ms`, `latency_le_1000ms`, `latency_over_1000ms`, `connections_accepted`, `connections_refused_busy`, `connections_timed_out` (all since the process started).

GET /api/v1/admin/sources
: Returns `sources`: one entry per configured source (`name`, `kind`, `enabled`, `configured: true`, `documents`, `last_job`) and one per name that has documents but is no longer configured (`configured: false`).

GET /api/v1/admin/jobs
: Returns `jobs`: the 50 most recent import jobs, newest first (`id`, `source`, `kind`, `state`, `started_at`, `finished_at` as Unix seconds or null, `submitted`, `rejected`, `skip_reasons` (an object with the counts `robots`, `network`, `certificate`, `http_status`, `wrong_type`, `too_large`, `encoding`, `no_text`, `redirect`, `limit` and `unreadable`; they add up to at most `rejected`, because only some connectors say why they skipped something), `error_message`). A job shown as `running` may belong to an import that was killed; it is marked interrupted the next time a command opens the data.

GET /api/v1/admin/jobs/skipped?job=ID
: Returns `job` and `skipped`: examples of what that job skipped, each with a `reason` (as in `skip_reasons`) and `what` (the address or path), at most twenty per reason and a hundred in all. The counts in `jobs` are complete; this is only a sample, so you can see what is being left out. Sources whose connector does not name what it skips have none. 400 if `job` is not a number.

GET /api/v1/admin/search
: Runs a search like the public API (`q`, optional `language` and `connector`, at most 20 results) and returns `hits` with their ranking `score`, plus `tokenizer`, `title_weight` and `body_weight`, so ranking can be inspected. Same errors as the public search (`empty_query`, `invalid_query`). The HTML page `/search` is the same thing for people.

GET /api/v1/admin/imports
: Returns `actions` (whether imports can be started), `running` (`source`, `started_at`, `submitted` so far, `progress_done` and `progress_total`: the connector's own measure of how far it is, such as bytes of a dump read or files handled, with a total of 0 when it cannot tell; or null) and `last` (the last import started through this interface since the process began: `source`, `state`, `submitted`, `rejected`, `skip_reasons` (as for jobs), `failure`, `finished_at`, or null).

POST /api/v1/admin/imports
: Starts an import of the source named by the form field `source` (`application/x-www-form-urlencoded` body). Returns 202 with `started`. Errors: 404 `unknown_source`, 409 `source_disabled`, `already_running` or `locked` (another import, rebuild or removal holds the data directory), 403 `actions_disabled`.

POST /api/v1/admin/imports/cancel
: Asks the running import or maintenance operation to stop at its next safe point (an import's position is saved). Returns 200 with `cancelling` (false if nothing was running).

POST /api/v1/admin/sources
: With actions enabled and the server started with `--config`, edits the `[[source]]` tables of the configuration file and applies the change at once. Form fields: `op` is `save` (the default: add a source, or with `original` replace the source of that name), `delete` or `toggle`. For `save`: `name`, `kind`, `enabled` and `retain_text` (`1` or `0`; default 1), `rights` (`unknown`, `allowed`, `restricted` or `forbidden`; default the connector's own) and `options`, the connector's options as TOML, one `key = value` per line (text, whole numbers and true/false only). For `delete` and `toggle`: `name`; `toggle` also takes `enabled`. The whole new file is validated as at startup before anything is written; the old file is kept as `FILE.bak` and the new one replaces it atomically. Returns 200 with `done` and `name`. Errors: 400 `invalid_source` (with the reason), 409 `no_config_file` (the server was started without `--config`), 500 `config_not_writable`, 403 `actions_disabled`. Only sources can be edited this way; other settings are changed by hand and need a restart. Deleting a source does not delete its documents (use `maintenance` for that).

POST /api/v1/admin/maintenance
: With actions enabled, starts a maintenance operation in the background (only one import or operation runs at a time; they share the data directory's writer lock). Form fields: `op` is `check` (verify the stored data, read-only), `backup` (write verified copies of `state.db` and `content.db` into a new folder under `[admin] backup_dir`; 409 `not_configured` if that is not set) or `remove` (delete every document of `source`; also needs `confirm=yes`, or from the page the source's name typed again, else 400 `confirmation_required`). Returns 202 with `started`. Progress and the result appear in `GET /api/v1/admin/imports` as `running` and `last`, each with an `op` member (`import`, `check`, `backup`, `remove` or `download`), and `last` also has a `summary` text (the check's findings, the backup's location, how many documents were removed). Errors: 409 `already_running` or `locked`, 400 `unknown_operation`, 403 `actions_disabled`.

The HTML pages `/` (dashboard) and `/jobs`, `POST /login` (field `credential`: the password or the token), `POST /logout` and, with actions enabled, `POST /actions/import` (fields `source`), `POST /actions/maintenance` (fields `op`, `source`, `confirm`), `POST /actions/sources` and `POST /actions/cancel` are for browsers; the page `/maintenance` shows the buttons; the last three carry the per-session form token in the field `csrf`. The same compatibility rules apply: fields may be added within `v1`.

LIMITATIONS
No document endpoints. The administration API can start and cancel imports only when enabled, and cannot rebuild, remove, back up or change configuration. No sorting options, total counts, or faceting. The public API has no authentication or rate limiting; the administration API requires a credential.

BUGS
See dksearch(1).

TROUBLESHOOTING
Empty `hits` for a query that should match: check the filters, and check that the index is populated (see **import** in dksearch(1)).

NOTES
Document ids are derived from the connector name and the source's own identifier, so the same item keeps the same id across re-imports and index rebuilds.

CAVEATS
Scores are not comparable between different queries.

HISTORY
Version 1 of the API is introduced with dksearch 0.0.0.

DEPRECATION
Nothing is deprecated.

SEE ALSO
dksearch(1)

AUTHOR
dksearch contributors.

COPYRIGHT
Copyright 2026 dksearch contributors. SPDX-License-Identifier: GPL-2.0-only

LICENSE
GNU General Public License, version 2 only. See dksearch(1).

AVAILABILITY
Not yet published.

VERSION
This manual describes the `/api/v1/` interface of dksearch version 0.0.0.
