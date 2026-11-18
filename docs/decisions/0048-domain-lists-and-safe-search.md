# 0048: Domain lists and safe search

Status: implemented (blocklist, demotion list, safe search). Safe search was amended in ADR 0049 (adults can turn it off; the ban stays for everyone). "Trusted first" ordering is not built.

## Context

Search results of crawled sites include sites the owner never wants to see (SEO filler) and, for some owners or audiences, adult sites. Removing documents from the index is not enough: a recrawl brings them back, and the index may be shared with peers.

## Decision

- **Domain lists, matched on the host of the document's address**, covering subdomains. Lists come from entries and files (plain, hosts and ad-blocker formats), read at start; an unreadable file stops the server.
- **The match is made by the database itself** through a SQL function over the document's domain column, so the condition applies to every query that goes through the index (words, conditions, chunk search for retrieval and answers, image search, export) and results, pages and counts are right. Demotion is another function that multiplies the score.
- **Safe search adds the ban lists to the blocklist for everyone** and cannot be turned off by a request: the owner decides, not the visitor. No list is bundled; classifying text by its content is error-prone, so the filter is the owner's choice of public domain lists.
- **Where the index is not the path** (a document opened by id, similar documents from vectors, results of peers and of fallback engines, the retrieval of peers) the handler checks the same list.

## Alternatives

- Deleting blocked documents from the index: they return with the next crawl and the choice is lost when the list changes.
- Filtering in the handler after the search: pages come out short and counts wrong.
- Word lists over the text: false positives (innocent words) and misses; a better tool for a later, optional step.

## Consequences

- A blocked domain still takes space in the index and in crawls; a source can be pointed away from it separately.
- The lists change only at a restart.
