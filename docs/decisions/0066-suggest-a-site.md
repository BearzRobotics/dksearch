# 0066: The owner suggests a site that should have been found

Status: accepted

## Context

For "linux rescue cd" the owner expected SystemRescue, Clonezilla and Super GRUB2 Disk; none of them was in the index, so no ranking could have shown them. A mark on a result (ADR 0064) cannot say "this result is missing"; the owner had been giving such sites to the assistant to add to the list of seeds by hand.

## Decision

With the owner signed in, a search page has a small form, *A site missing from these results?*. It POSTs the search and the address to `/suggest`, which (owner only, plain http(s) addresses only):

1. adds the address to `data_dir/suggested-sites.txt` unless it is there (at most 5000 addresses), a plain-text seeds file that a crawl source reads (`seeds_file`), so the site is crawled on that source's next run;
2. records the address as a good answer for that search in `feedback.jsonl`, so `dksearch eval` keeps the expectation and reports it as missing until a search finds it.

Nothing is crawled at the moment of the request, and nothing reaches the network from the request itself.

## Consequences

Adding a site takes one paste, from the page where its absence was noticed. The list is the owner's; a visitor cannot write to it. A suggested address is crawled as any seed is (robots.txt, delay, limits). The crawl source for the file is configuration (`seeds_file`), not built in, so a server without it only collects the suggestions.
