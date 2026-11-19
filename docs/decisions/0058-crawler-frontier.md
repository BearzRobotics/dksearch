# 0058: The crawler's frontier: tidy addresses, traps, priority, sitemaps and feeds

Status: accepted

## Context

A crawl that goes one link deep from a front page reaches little of a documentation site or a wiki, and a crawl that goes deeper can drown in addresses that lead nowhere new: tracking parameters that make one page many addresses, calendars and search results that never end, relative links that go round in circles. With a limit on pages per run, the order in which pages are asked for decides what is indexed.

## Decision

- **Tidy addresses** (`crawl/frontier.zig`): the fragment, a default port, repeated slashes, session parameters and tracking parameters are removed and the other query parameters sorted, so one page is requested once.
- **Traps** are not followed and are counted per site in the crawl report: a path that repeats a segment three times, more than twelve segments, an address over 2000 characters, search and comment-reply parameters, a wiki's edit, history, old-version and `Special:` pages, more than eight parameters.
- **Priority**: the addresses found on a level are put in order of a score (short path, no query, short address first) within each seed, so the page budget goes to the top of a site before its tail.
- **Sitemaps from robots.txt** (`robots_sitemaps`, off by default): the `Sitemap:` lines are kept by the robots parser; for each listed site the pages of those sitemaps (own site only, at most 5000) join the next level as pages at the depth limit.
- **Feeds** (`use_feeds`, off by default): the feed that the first page of a listed site names is read once per site and its newest 100 entries (own site only) join the next level the same way.

## Consequences

Dropping a query parameter is a guess that the page is the same: it is right for the parameters named (tracking and session ones), which are a fixed list. The trap rules can hide a page someone wants (a wiki's `Special:` page); the report shows how many were left out per site. Sitemaps and feeds are opt-in because they add requests and pages for every listed site.
