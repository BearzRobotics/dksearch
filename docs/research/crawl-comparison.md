# Crawl comparison: dksearch and YaCy on the same seeds (2026-11-16)

A short head-to-head, not a benchmark. Both crawlers ran at the same time on the same machine and connection for 6 minutes, from the same seed list (785 start addresses on 450 hosts: the owner's bookmarks and the shared community sites; the list stays out of the repository), to depth 3, following links to other sites, obeying `robots.txt`.

- dksearch: `crawl` connector, `max_depth = 3`, `follow_external = true`, `delay_ms = 500`, one request at a time (as designed).
- YaCy 1.942: a single node in a network unit with global crawling and no peers (`yacy.network.solo.unit`), crawl start with the whole list, depth 3, range "wide", defaults otherwise (up to 200 crawler threads, adaptive per-host delay).
- A first YaCy attempt in the private-lab network unit stalled after 154 pages: its `domain = local` unit selects the "intranet" crawler agent. That run is discarded.

| Elapsed | YaCy documents indexed | dksearch documents stored |
|---|---|---|
| 30 s | 178 | n/a (counted every 25 pages) |
| 60 s | 383 | |
| 120 s | 512 | |
| 150 s | 1,087 | |
| 210 s | 1,774 | |
| 330 s | 1,795 | 35 stored, 21 skipped (robots 8, wrong type 13) |

**Result: dksearch does not match YaCy here; it is about 50 times slower** (about 0.1 pages per second against about 5 per second at the start of YaCy's run, which then flattened at about 1,790 pages after 4 minutes). The cause is plain: dksearch fetches one page at a time across the whole crawl, so every slow answer, every new host's `robots.txt` fetch and every politeness wait is serial; YaCy keeps hundreds of fetches in flight, each host being limited separately. Per-host politeness is not the difference (both wait between requests to one host); concurrency across hosts is.

What was not compared: quality of extracted text, duplicate handling, how many distinct hosts were reached, and what YaCy's plateau means (its frontier running dry, a per-host cap, or load limits). Those need a longer run and the same measurements taken from both indexes.

**What to do about it** (not yet done): fetch with several workers while keeping the guarantees that matter, in this order: one request at a time per host and the delay between requests to a host stay as they are (a lock and a timestamp per host); several seeds' trees are crawled at once (a `workers` option, default 8), sharing the host table, the visited set and the page budget; documents still go to the pipeline through one lock; the resume position stays "the last seed line before which every seed is finished". See ADR work to follow.
