# 0049: Safe search that adults can turn off

Status: implemented. Amends ADR 0048, where safe search was one switch for everyone.

## Context

A household where adults may search adult content but children may not, and a business that wants it banned outright, need different things: a ban nobody can lift, and a filter that some people can.

## Decision

- **Two sets of domains.** The ban (`[filters]`) applies to every request. The safe-search list (`[safe_search]`) applies only to requests for which safe search is on. Both are TOML list files next to the configuration (`domains`, `import`) or text lists, and hashes are accepted.
- **Safe search is on by default for visitors** (`enabled = true`) and is switched off for a request by (1) an API key marked adult (`api-key add --adult`), or (2) a browser unlocked with a PIN: the PIN is set from the command line (`safesearch-pin`), stored only as an Argon2 hash, entered at `/unlock`, and remembered as a random token in an HttpOnly cookie for `unlock_hours`; five wrong tries a minute are refused. No request parameter turns it off.
- **Applied in the index, per query.** A SQL function takes the domain and a flag (`safe`), so one connection serves both kinds of requests, pages and counts are right, and the cursor and per-domain features are unaffected. Where results do not come from the index (documents by address, similar documents by vector, peers, fallback engines) the handler asks the same lists with the same flag.
- **Not applied** to what is exported to peers (the ban only: peers are the owner's choice) and to search by image (the ban only).

## Alternatives

- Per-profile accounts: more machinery than a household needs.
- A visitor toggle without a PIN: children can click it.
- Admin sign-in as the unlock: ties browsing to the administration password.

## Consequences

- The PIN protects against children, not against someone with the server's files: a determined person can read the configuration. The ban list is for what must never appear.
- A browser's unlock lives in server memory: a restart locks every browser again.
