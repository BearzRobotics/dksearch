# 0059: MediaWiki sites are listed through their API

Status: accepted

## Context

A wiki has thousands of articles and its front page links to a few dozen. Following links from the front page, even three deep, reaches an arbitrary part of it, and a wiki's own pages (history, edit, recent changes, special pages) are made to lead round in circles. MediaWiki has an official API for programs, and one of its calls lists every article.

## Decision

With `mediawiki = true`, a listed site whose first page has `<meta name="generator" content="MediaWiki ...">` is read through its API: the address from the page's `EditURI` link (else `/api.php`, `/w/api.php` on the same site), the article path from `meta=siteinfo`, then `list=allpages` (main namespace, redirects left out, 500 a time, following `apcontinue`) up to `mediawiki_max_pages` (5000) articles. The articles join the next level as pages at the depth limit. Every call goes through the same fetching as a page: `robots.txt` is read for the API's path, the delay and backoff apply, and a wiki that does not allow its API to crawlers is left to its links. Wiki special pages, edit and history views stay out as traps (ADR 0058).

## Consequences

Two or three extra requests per wiki, then one per 500 articles. The cap bounds a very large wiki (the page budget of the run still applies). Only the main namespace is listed: help, project and category pages are reached only if linked.
