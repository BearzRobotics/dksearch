# SearXNG

Status: source read; no experiments (not installed or run). Research order: 8 of 10.

- Focus: metasearch and provider federation: engine adapters, parallel fan-out, merging, privacy.
- Source: <https://github.com/searxng/searxng>, shallow clone at `/mnt/scratch/research/searxng`, commit `2d500cb6b8e9` (2026-11-15).
- Claims marked (read) were checked in the files named; (known) are from prior knowledge and not checked. Paths are under `searx/`. Python, Flask, AGPL-3.0; optional Valkey (Redis fork) for the limiter and caches (`settings.yml`, read).

## What it is

A self-hostable metasearch front end: it holds no index. A query is sent to many third-party search engines at once, the results are merged and shown without the user's address or identifying headers reaching those engines. About 255 engine modules ship in `engines/` (read: `ls`). It matters to dksearch for two reasons: it is the best-known design for *fan out, merge, tolerate failure*, and it already contains engine adapters for other self-hosted search systems (`yacy.py`, `marginalia.py`, `meilisearch.py`, `elasticsearch.py`, `solr.py`, `sqlite.py`, `recoll.py`, `command.py`, read as file names, `marginalia.py` and `meilisearch.py` read in full).

## Architecture as read

**Engine = a module plus a settings entry.** A module under `engines/` defines module-level attributes (`about`, `categories`, `paging`, `time_range_support`, `safesearch`, `language_support`, `timeout`, `weight`, `shortcut`) and two functions: `request(query, params)` fills `params["url"]`, headers, cookies, method, data; `response(resp)` returns an `EngineResults` of typed results (`result_types`: main result, answer, infobox, suggestion, correction). Optional `setup()`, `init()`, `fetch_traits()` (downloads language and region tables). `engines/__init__.py` `load_engine` loads the module, fills `ENGINE_DEFAULT_ARGS`, overlays the YAML entry, and drops engines that are inactive or malformed (names must be lowercase with no underscore). Generic engines need no Python: `xpath` and `json_engine` are configured entirely in YAML (`search_url`, `results_xpath`, `url_xpath`, ...), and one module can serve several entries (`mojeek`, `mojeek images`, `mojeek news` share a module and a `network:`).

**Settings.** `settings.yml` (about 3500 lines) has `general`, `search` (safe search, autocomplete, `ban_time_on_fail: 5`, `max_ban_time_on_fail: 120`, per-exception suspend times such as 3600 s for captcha), `server` (bind `127.0.0.1`, `method: GET`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex`, `limiter`, `image_proxy`), `outgoing` (`request_timeout: 3.0`, connection pool, HTTP/2), `plugins` (on/off per class), `categories_as_tabs` and `engines:` (list). An engine entry looks like `- name: marginalia / engine: marginalia / shortcut: mar / api_key: ... / disabled: true`. Engines have `categories` (general, images, news, it, science, files, ...); the category tabs choose which engines a query runs on. Users override choices per browser in cookies; an admin file overrides defaults.

**Query syntax (read, `query.py`).** `!shortcut` or `!category` picks engines, `:lang` a language, a timeout override (`TimeoutParser`) and `!!` external bangs are parsed from the query before search.

**Processors (read, `search/processors/`).** One processor class per engine type: `online` (HTTP), `offline` (local code, for example `sqlite`, `command`), `online_dictionary`, `online_currency`, `online_url_search`. Each holds the engine's suspended state.

## One query, end to end (read)

1. `webapp.py` builds a `SearchQuery` (query, categories, engine refs, language, page, time range, `timeout_limit`) from the form and cookies.
2. `Search.search` (`search/__init__.py`): external bang, then *answerers* (local instant answers), else `search_standard`.
3. `_get_requests`: for each selected engine, skip if its processor is *suspended* (`extend_container_if_suspended` reports it as unresponsive), skip if the engine cannot do the page or time range, else build request params. The overall deadline is the largest engine timeout, lowered by the user's `timeout_limit` and the server's `outgoing.max_request_timeout`.
4. `search_multiple_requests`: one thread per engine runs `processor.search`; the main thread joins each with the *remaining* time to the shared deadline; a thread still alive is recorded as `timeout` in the result container and abandoned (it cannot cancel it, but it no longer matters to the response).
5. In each thread: `request()` then an HTTP call through `searx.network` (per-engine network, proxies, retries optional), then `response()`; exceptions (SSL, timeout, access denied, captcha, too many requests) call `handle_exception(..., suspend=True)`: the engine is suspended for `ban_time_on_fail` seconds (growing with consecutive errors up to the maximum) or the exception's own time; a success resets it.
6. Results enter `ResultContainer.extend` and pass plugin `on_result` hooks (plugins also have `pre_search`, `post_search`). Each main result is hashed by template, host, path, query, fragment and image (scheme ignored: `result_types/_base.py` `MainResult.__hash__`). A hash already present is *merged*: longer title and content win, missing fields are copied, engines are unioned, https is preferred, and the position the engine gave is appended to `positions`.
7. `close()` scores each result: `weight = product of engine weights x number of positions`; `score = sum(weight / position)` over positions (priority `high` counts weight per position, `low` zero). So a result found by several engines, or at the top of one, ranks higher; engine `weight` is an operator knob (`calculate_score`, `results.py`). Results are sorted, then *grouped* by category and template (up to 8 consecutive, within 20 positions) so images, videos and web results cluster.
8. The page also lists unresponsive engines (name and reason), suggestions, corrections, answers and infoboxes, and per-engine timings (`add_timing`).

## Privacy handling (read where noted)

- Outgoing requests are made by the server from headers the engine builds (`default_request_params`: empty `headers` and `cookies`, `Accept-Language` derived from the locale, `online.py`); no code copying the client's IP or headers to engines was found in `search/` and `network/` (grep for `X-Forwarded`/`remote_addr` found nothing there).
- Server-side state per user: none. Preferences live in cookies the browser sends back (`preferences.py` `set_cookie`); queries use GET by default but POST can be chosen; `image_proxy` fetches images through the server; `plugins/tracker_url_remover` strips tracking parameters from result URLs.
- Abuse defence for public instances: `limiter.toml` and `botdetection/` (IP-prefix limits, header sanity checks, link tokens, trusted proxies; needs Valkey). Irrelevant for a private node.

## Useful patterns

- Fan-out with a single shared deadline, join with remaining time, report slow engines by name instead of failing the page.
- *Circuit breaker* per engine: suspend after an error, longer after repeated ones, with the reason shown to the user; reset on success.
- Typed result records with a content hash that a result type may override; duplicates merged field by field and the set of origins kept.
- Rank-based merge using positions only (no cross-engine score comparison), with an operator weight per engine: the same idea as reciprocal-rank fusion (`1/rank`, not `1/(k+rank)`).
- Declarative engines (xpath/json in config) so a new provider needs no code; categories as the scope selector; shortcuts (`!mar`) in the query.
- Plugin hooks before search, per result and after search.

## Limits and what not to copy

- Scraping HTML of commercial engines breaks constantly (captchas, proof-of-work, blocking; many shipped engines are `inactive`/`disabled` in `settings.yml`, for example `mojeek`). dksearch peers speak a stable API of its own; no scraping.
- Needs the internet by nature. For dksearch the federation layer must be absent or empty by default and never required.
- Python/Flask stack, Valkey for the limiter, a very large settings file; not a reference for resource use. Threads are abandoned, not cancelled, on timeout.
- Rank-position merge discards score gaps (noted in `p2p-plan.md`); weights are operator guesses; the merge trusts that an engine's order is honest, which dksearch cannot assume for peers.
- Duplicate identity is the URL. dksearch's node-independent `ident` is stronger (works for files and non-URL sources).

## Possible dksearch uses

- Federation (`p2p-plan.md` step 2): copy the control flow of steps 3-5 and the suspend rule: per-peer deadline inside one overall deadline, partial answers labelled, a peer that failed is skipped for 5 s doubling to 120 s with the reason visible in the admin page, instead of a fixed timeout every time.
- Merge: positions-only fusion is the same family as the planned reciprocal-rank fusion; keep dksearch's `1/(k+rank)` with a per-peer weight in `[[peer]]`; merge duplicates by `ident`, keep the longest snippet, union the `node` list ("also on node B").
- Result model: a peer result is a typed record with `node`, `ident`, bounded fields and escaped snippet, validated at the boundary (SearXNG normalises fields in `normalize_result_fields`).
- External engines as optional *providers* distinct from peers: a `[[provider]]` of kind `searxng`, `yacy`, `meilisearch` or `marginalia-api`, off by default, results always marked "external" and never indexed. A SearXNG instance can also query a dksearch node today through its generic `json_engine` against `/api/v1/search`, which makes dksearch a source for people who already run SearXNG.
- Collections vs categories: map the search-time `!category` idea to saved source groups and the Source drop-down (open question in `source-selection.md`); shortcut tokens (`!notes`) could be sugar for `source:`.
- Show timings and failures per source and per peer on the results page (SearXNG's "engine timings / unresponsive engines" box).

## Questions for dksearch

- Should suspend times be per peer in memory only (restart clears) or stored? A restart-clears rule is simpler and cannot get stuck.
- Is a result's `weight` (peer trust) a number the operator sets, or only on/off?
- Should abandoned slow peer requests be cancelled (Zig async, socket close) rather than left running as SearXNG's threads are?
- Does an external provider belong in core at all, or only as a documented example config of a generic JSON provider?
- Experiment still to do: run a local SearXNG with `json_engine` pointed at a dksearch node to check that the API shape is enough, and with one deliberately slow engine to confirm the join-with-remaining-time behaviour.
