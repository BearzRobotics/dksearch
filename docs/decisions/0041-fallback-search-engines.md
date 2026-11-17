# 0041: Fallback to other search engines

Status: implemented.

## Context

A private index finds only what it holds. People want a way out when it finds little: another engine, one click away, or a few web results below the local ones. Both change the privacy of a search, so they must be explicit, off by default and honest about where the words go.

## Decision

- **Everything is under `[fallback]` and off unless `enabled = true`.** With it off there is no mention of other engines on any page and no code path that contacts one.
- **Link-outs first.** The default and safest way is a list of links (a built-in table of well known engines plus the operator's own `[[fallback.engine]]`). The page shows them when local results are fewer than `min_results`. This server sends nothing; the visitor's browser goes to the engine only on a click. Templates are checked: http(s), exactly one `%s`, no quotes or spaces.
- **Providers are separate and explicit.** `[[fallback.provider]]` (Brave Search API, a SearXNG instance with JSON, Marginalia) lets this server ask for web results. By default the page only offers "Also search the web through X" (`web=1`); `auto = true` asks without being asked. Results are shown under the local ones, labelled external with the provider's name, never ranked with the local results, never stored or indexed.
- **Untrusted answers**: bounded sizes, only http(s) links, escaped on output, `rel="noopener noreferrer nofollow"`.
- **A global rate limit** (`max_per_minute`, default 30) across all visitors, because anonymous visitors would otherwise spend the operator's API quota or reputation; over it, a note on the page and nothing is sent.
- **No scraping.** Google's and Bing's result pages are not fetched: it violates their terms and breaks without notice. They are link-outs only.
- Not for callers with no access (empty anonymous scope), not after the first page, and the server prints a note at start when providers are enabled.

## Alternatives

- Always ask providers when results are few: simplest, but it quietly sends every low-result query to a third party.
- Per-visitor opt-in cookie: a cookie for a privacy feature; the explicit `web=1` link does the same without state.
- Mixing external results into the ranking: scores are not comparable and it hides what is local; a labelled section is honest.

## Consequences

- The operator decides what leaves the server; the visitor sees where a result came from.
- Providers have their own terms and quotas (Brave's API is paid beyond a free tier).
