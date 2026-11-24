# 0081. Removing the documents of blocked domains, and hosts files as block lists

- Status: Accepted (2026-11-22), as asked by the owner after adding a published hosts file as a block list
- Date: 2026-11-22

## Context

A block list (`[filters] blocklist_files`, `blocklist`, `ban`; `[safe_search] ban_files`) hides a domain from every search and keeps the crawler from contacting it, but the documents stored before stay in the stores and the index. `dksearch remove` removed only a whole source (ADR 0010), which cannot separate one domain from the rest.

## Decisions

1. **`dksearch remove --config FILE --blocked [--yes]`** reads every document record, and removes those whose address is on a blocked domain (a subdomain counts) from the retained text, the index and the records, in batches of 1,000 after the records are all read. Without `--yes` it counts. It takes the write lock, so `serve` must be stopped. A repeat finds what an interrupted run left.
2. **`fetch-banlist` accepts a hosts file** (`0.0.0.0 domain` lines), as it accepts lists of domains and MD5 hashes; the owner's playground uses the Anti-Porn HOSTS file (70,677 domains) as `blocklists/antiporn.txt`. The list is a snapshot: fetch it again, restart, and run `remove --blocked --yes` to clear what new entries cover. The `[filters] allow` list still overrides `blocklist_files` (deviantart.com is allowed there).
