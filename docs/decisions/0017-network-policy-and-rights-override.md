# 0017. Crawler direction, feed fetching, Windows, rights override

- Status: Accepted (2026-11-15), the user's answers to four open questions
- Date: 2026-11-15

## Context

After ADRs 0015 and 0016 four questions were open: whether to build a web crawler (SPEC milestones 5 and 6), whether the feeds connector should fetch, whether Windows is supported, and how rights flags are decided.

## Decisions

1. **A crawler will be built, polite and opt-in.** It is a connector like the others: nothing is fetched unless a `[[source]]` of kind `crawl` is configured. It obeys robots.txt, rate-limits per host, and sends a user agent the administrator configures (project name plus a contact URL the administrator chooses; the program never fills in personal details). The first version takes an explicit seed list; open-web discovery is a later step. Not implemented yet. Its own record will settle HTTP and TLS client choice (vendored, no Docker, offline tests with a local server), defaults for the rate limit and size caps, and how fetched pages are stored.
2. **Feeds stay file-only for now.** Fetching feeds is revisited after the crawler exists, reusing its HTTP client and politeness policy.
3. **Windows is unsupported.** Linux, macOS and the BSDs only. Revisit if asked.
4. **Rights flags are the administrator's decision.** Connector defaults stay conservative (Gutenberg `restricted`, Wikipedia `allowed`, feeds `unknown`). A source may set `rights = "unknown" | "allowed" | "restricted" | "forbidden"` to override the flag for all its documents. The override applies to documents added or changed after it is set; unchanged documents keep their stored flag until they change or the source is removed and re-imported. This is a record of the administrator's choice, not legal advice.

## Consequences

The `rights` key is accepted on every source, validated at load, and applied in the pipeline. Documentation: `dksearch.1` source keys.
