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

## Correction: what YaCy's count means, and a second run with concurrency

YaCy's "documents" include records of failed fetches. Of its 1,795 entries after the six minutes, **855 were real pages** (HTTP 200; 796 HTML, the rest PDF) on 541 hosts; the other 940 were failure records (robots.txt denials 140, HTTP 403 156, 404 126, 429 21, and about 500 timeouts and other load errors). So the first comparison overstated YaCy by about two times, and dksearch was about 25 times slower, not 50.

After adding workers to the crawler (16 workers, same seeds, 6 minutes, per-host delay 500 ms, run on its own while YaCy's crawl was paused):

| | YaCy (global mode) | dksearch, 1 worker | dksearch, 16 workers |
|---|---|---|---|
| Real pages in 6 minutes | 855 | 35 | **2,441** |
| Hosts reached | 541 | about 10 | 119 |
| Seed addresses indexed | 131 of 784 | 1 | 19 of 784 |
| Seed hosts reached | 118 of 448 | n/a | 26 of 448 |
| Pages that came from hosts the other crawler also reached | | | 18 of YaCy's 828 not found by dksearch were on such hosts; 810 were on hosts dksearch never got to |

**Reading:** dksearch now fetches about three times as many real pages as YaCy in the same time, but it is *narrower*: its workers went deep into the first seeds (the list is alphabetical; 310 pages from one site, 297 from the next) while YaCy took one step from many seeds first (breadth-first across the whole list). Nothing suggests a page that YaCy could fetch and dksearch could not: the pages dksearch missed were on sites it had not reached yet, and the other way round dksearch fetched 10 pages for which YaCy had recorded failures. Both obey robots.txt (YaCy recorded 140 denials; dksearch counted 455 in its larger crawl). So for the same seeds it is speed and ordering, not reach, that differs. What was not compared yet: text quality of the extraction, and what each does after the first six minutes (YaCy's count stopped growing after four).

**Next step (proposed, not built):** schedule breadth-first. The simple form is to crawl each tree level by level across a window of seeds (so that every seed gets its first pages before any gets its deep ones) and move the resume position per window; a cheaper stop-gap is a limit on pages per seed.
