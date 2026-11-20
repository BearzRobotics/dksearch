# 0075: Tags in results and ranking; author, dates and media details

Status: accepted

## Context

ADR 0074 made the crawler read the tags of a page, but nothing showed or used them, and the crawler still ignored who wrote a page, when, and what a video or picture page says about its media.

## Decision

- **Tags in results:** each result lists its tags (at most 12) as links to `tag:x`; under the results, "Narrow by tag" offers the tags that occur on at least two of them, added to the query.
- **A hashtag in a search** (`#nature`, at the start of the query or after a space) is a word as before and also puts pages with that tag first (a factor of 3). Plain words count against a page's tags only when `[search] tag_boost` (percent, default 0) is set: it is off because tags exist only on pages crawled since ADR 0074 and the weight must be chosen with `dksearch eval` and the owner's marks, not by eye. Both factors appear in the score breakdown ("other").
- **Author and dates:** `author` metas (`author`, `article:author`, `dc.creator`, ...) and JSON-LD `author` set the document's author (shown as "by", searched with `author:`); `article:published_time`, `datePublished`, `uploadDate` and the like set the published date, `dateModified` and `article:modified_time` the modified one (a page with only a published date has it for both, so it is shown and `modified:` finds it). An address is not an author.
- **Media details:** `og:type`, `og:site_name`, a video's `duration` (seconds or ISO 8601, kept as "1:02:03") and its or a picture's size (`og:video:width/height`, `og:image:width/height`, JSON-LD) are stored as `type`, `site`, `duration` and `resolution` on the document (the `meta` filters find them). They are not yet shown on results.

## Consequences

Pages stored before this have none of it; a recrawl from empty validators adds it. The video itself is still not read.
