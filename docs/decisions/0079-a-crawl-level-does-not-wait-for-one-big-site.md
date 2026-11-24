# 0079. A crawl level does not wait for one big site

- Status: Accepted (2026-11-24), after the owner asked that the crawl keep running and produce an index
- Date: 2026-11-24

## Context

The crawler works a level at a time (ADR 0032) and asks each site with one worker at a time (ADR 0057). When a level's queue is empty and only pages of sites that are being asked remain, one worker per such site is all that can work, and every other worker and every other site's next level waits. With a politeness delay of 2 to 10 seconds and up to 5,000 pages per site (ADR 0078), one site's tail kept a run at almost no new documents for a day.

## Decision

Once a level's queue is empty, the pages still set aside get `tail_grace_s` (120 seconds) more. Then the level ends and those pages go on into the next level, after the pages the workers found, so other sites' work fills the workers meanwhile. A tail of many sites (at least half as many as there are workers, judged from the pages taken next) is not cut, since the workers stay busy. No page is dropped: a level that was cut hands everything left to the next, and a run stopped part-way still repeats its window as before.

## Not done

A fully pipelined frontier with no levels. It would change the order the crawl visits pages in (ADR 0058), and this removes the stall without that.
