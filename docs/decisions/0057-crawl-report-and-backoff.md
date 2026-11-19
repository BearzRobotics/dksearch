# 0057: Crawl report and polite backoff

Status: accepted

## Context

A crawl of thousands of sites gives no way to see why a site is missing: the skip reasons are counted for the whole run, with a few sample addresses, not per site. (The OSDev wiki was in the seeds and gave nothing: Cloudflare's bot check answered 403 on every request.) And a site that answered 429 or 503 was simply skipped, though the right answer is to wait.

## Decision

- Every page request, skip and stored page is counted per site (host name, lower case) while the run goes. At the end of a run (or when it is stopped) the counts are written to a tab-separated report file, one line per site, with a verdict in words made from the counts: `ok`, `robots.txt disallows it`, `blocked by the site (403)`, `rate limited (429)`, `unreachable or certificate error`, `asks to be left alone`. The Crawl report page of the administration interface shows the sites that need a look first.
- A 429 or 503 is a refusal, not an error. The site's `Retry-After` (seconds) is obeyed up to two minutes; extra spacing is added to every later request to that site (the first time the larger of `delay_ms` and two seconds, then doubled up to a minute, halved after twenty good answers); the page is asked again up to two more times. A site that asks for more than two minutes is given up for the rest of the run.
- A site that blocks crawlers (a 403 with a bot check) is reported as blocked and is not worked around.

## Consequences

The report costs a map of counts per site in memory (bounded by the number of sites contacted). A refusing site slows the worker that asks it, since one worker at a time asks a site; other sites are not held up. A `Retry-After` given as a date is not read (the backoff decides).
