# 0016. Feeds connector and the XML build split

- Status: Accepted (2026-11-14), implementing the RSS/Atom item of SPEC milestone 6 within the project's existing rules (local files, no crawling)
- Date: 2026-11-14

## Context

SPEC section 4.2 and milestone 6 list RSS and Atom feeds. AGENTS.md says crawling must not be the primary ingestion path, connectors are optional, and the project works offline once data has been obtained. ADR 0007 already vendors Expat for the Wikipedia connector and sets the rule "read local files; fetching is a separate, explicit step".

## Decisions

1. **A `feeds` connector that reads feed files from disk**, a single file or a directory (`.xml`, `.rss`, `.atom`, `.rdf`), like the other bundled connectors. It never uses the network. Fetching feeds is left to the administrator (a scheduled `curl` into a directory, see docs/deploy), which keeps polling policy, politeness, conditional requests and any credentials out of the program for now. A fetching connector would be a separate decision with its own policy (user agent, rate limits, robots and terms), and is not part of this record.
2. **Formats**: RSS 2.0, RSS 1.0 (RDF) and Atom 1.0, with `content:encoded`, Atom `content` of type text, html and xhtml, `dc:creator`, `dc:date` and categories. Parsing uses the vendored Expat (so no hand-written XML parser), with the same hardening as the Wikipedia connector: no entity expansion, DOCTYPE refused, bounded depth and field sizes.
3. **Entry to document**: the id is the entry's id (`guid`, Atom `id`) or its link; an id that is not URL-like is prefixed with the feed's link so unrelated feeds cannot collide. The body is the full content if present, else the summary, else the title, converted from HTML to plain text by a small converter (tags dropped, block tags become line breaks, scripts and styles removed, entities decoded, never fails on malformed markup). Dates in RFC 822 and ISO 8601 forms are parsed; unparseable dates are left unset rather than guessed.
4. **Rights are unknown, on purpose.** A feed does not state a license for its entries. Each document records the feed title as attribution, `redistribution = unknown` and a note that the content belongs to its publisher; the project never assumes public availability grants reuse.
5. **Failure handling**: a feed file that cannot be parsed is counted as rejected and the run continues with the next file, because one broken feed must not stop a directory of feeds. Entries with no id and no link, or with no text at all, are counted as rejected. Positions resume by file name.
6. **Build split.** Expat is now needed by two connectors and bzip2 by one, so the build options are `-Dwikipedia` (Wikipedia connector, bzip2 and Expat) and `-Dfeeds` (feeds connector, Expat), both on by default except on Windows. A library no enabled connector needs is not compiled or linked (checked: with both off the binary has no Expat or bzip2 symbols; with only feeds it has Expat and no bzip2). The shared Expat wrapper moved from `connectors/wikipedia/` to `src/xml.zig`.

## Not done

Fetching feeds; conditional GET and polling schedules; OPML subscription lists; sitemaps and the seed bank (the rest of milestone 6); enclosure and media handling; feed autodiscovery.
