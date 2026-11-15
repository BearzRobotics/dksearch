# 0007. First dataset connectors and their format dependencies

- Status: Accepted (2026-11-14, by the maintainer), with the amendment below
- Date: 2026-11-14

## Context

SPEC section 15 milestone 3 asks for a Project Gutenberg catalog/content importer and a Wikipedia dump importer, with job tracking, resumability and provenance. AGENTS.md requires: offline operation after datasets are obtained, no crawling as the primary path, respect for source terms, preserved licensing and attribution, and no custom parser for an established format when a maintained library exists.

What the Zig 0.17.1 standard library provides (checked in its source): tar, zip, flate (deflate/gzip/zlib, compress and decompress), lzma, xz, zstd (decompress only). It has no bzip2 decoder, no XML parser and no CSV parser.

What the sources provide (from their own documentation, found by web search and to be re-checked against the live pages before implementation):

- **Project Gutenberg** offers its catalog as downloadable files: an Excel-compatible CSV (updated weekly) and XML/RDF (updated daily, distributed as a `.tar.bz2` archive). Its pages ask automated users to use these feeds to populate a database rather than robot the website. Books are generally public domain in the USA, but the files carry the Project Gutenberg license and trademark conditions; the site's terms (which I could only read secondhand) are on gutenberg.org and must be read in full before shipping.
- **Wikipedia** publishes dumps; the one most users want is `pages-articles-multistream.xml.bz2` (current revisions of articles, tens of GB compressed) with an index file for seeking. Article text is MediaWiki wikitext, not plain text. Text is licensed CC BY-SA (and mostly GFDL), with attribution requirements; images and other media differ. The Wikimedia Terms of Use control where they conflict with the dump license page. One source claims the legacy XML dumps are being deprecated; that is unconfirmed and must be checked.

## Decisions

1. **Order: Gutenberg first, Wikipedia second.** Gutenberg needs only a CSV catalog plus plain-text book files from a local directory or mirror the administrator has already downloaded. Wikipedia needs bzip2, XML streaming and a wikitext-to-text step, each a larger piece of work.

2. **Both connectors read from local files.** Fetching datasets is an explicit, separate administrator step (download or rsync, optionally scripted outside the program). Connectors never fetch on their own in this milestone, so they work offline and cannot become crawlers. Network fetching can come later as a separate, opt-in capability that honors the sources' stated policies.

3. **Gutenberg metadata from the CSV catalog.** It carries the fields we need (id, title, authors, language, subjects, rights status) and avoids requiring an XML parser for this connector. Book text is read from the files in a user-supplied directory; the standard PG start/end markers are used to separate the book from the license boilerplate, which is kept as rights metadata rather than indexed as content. Rights, attribution and the trademark/licence notice are stored in `Document.rights`; the redistribution flag is `restricted` until the license terms are modelled explicitly, so the default is conservative.

4. **CSV parsing:** RFC 4180 CSV is small and stable, and no maintained Zig CSV library has been identified. Proposal: a small, strictly tested CSV reader inside the connector (quoted fields, embedded newlines and quotes, size limits, malformed-input handling), documented here as the exception to "don't write a parser for an established format". If you know of a library you prefer, we use that instead.

5. **bzip2 (needed by Wikipedia, and by Gutenberg's RDF archive):** vendor the reference `libbz2` (bzip2 1.0.8, BSD-style license, a handful of C files, no dependencies), wrapped as a `std.Io.Reader`, following the SQLite precedent (ADR 0003). Administrators who prefer can decompress beforehand and point the connector at the plain XML; the connector accepts both.

6. **XML (Wikipedia):** the dump is regular, machine-generated XML read as a stream. Proposal: vendor a small streaming XML parser (expat, MIT) rather than write one. Memory stays bounded because pages are processed one at a time.

7. **Wikitext to text:** a deliberately modest converter (drop templates, tables, reference tags, comments and markup; keep article prose and headings; resolve simple links to their display text), because a full MediaWiki parser is out of scope. Quality is judged on a fixture of real article excerpts; redirects, disambiguation and non-article namespaces are skipped. Wikipedia import is explicitly "good enough for search", not a faithful renderer.

8. **Provenance and rights are first-class.** Each document records source dataset and version (e.g. the dump date), the source id, revision, canonical URL, license identifier and attribution text. Wikipedia pages get `CC-BY-SA-4.0`/`CC-BY-SA-3.0` as stated by the dump, and attribution pointing to the article history URL; search results display the source so attribution is possible.

9. **Resumability:** both connectors report a checkpoint (Gutenberg: position in the catalog; Wikipedia: byte offset of the next stream in the multistream archive, using the index file). Job records live in `state.db` (ADR 0006).

10. **Test fixtures:** each connector ships a tiny committed fixture (a few catalog rows and books; a few real-style articles) so tests run offline and deterministically, as AGENTS.md requires. No test downloads data.

## Amendment: connectors are optional

The maintainer's condition: users must not be forced to use the connectors, but the project supports them. Consequences, binding on this and later milestones:

- **Nothing requires a connector.** The program starts, serves search and passes its tests with zero connectors configured. A fresh install has no sources enabled.
- **Connectors are opt-in per source.** A source exists only if the administrator configures it, and each can be enabled or disabled independently. Configuration validation never demands one.
- **Other ways in are first-class.** Content must be able to arrive without any bundled connector: through the shared pipeline's normalized-record interface, and (planned) a documented import format for records produced by the user's own tools, plus the local-files connector listed in SPEC section 4.2. Bundled connectors use exactly the same interface as anything else; they get no private access.
- **Dependencies follow the connectors.** The vendored libbz2 and expat exist only for the Wikipedia connector. They are compiled in only when that connector is, selectable at build time, so a build without it carries no extra third-party code.
- **Bundled does not mean mandatory data.** No dataset is downloaded, shipped or fetched by default.

## Implementation notes: Gutenberg connector

Built 2026-11-14 as `src/connectors/gutenberg.zig` with the CSV reader in `src/csv.zig`, following decisions 1-4, 8 and 9. Where it differs from or refines the text above:

- Catalog columns are found by header name (`Text#`, `Type`, `Title`, `Language`, `Authors`, `Subjects`, `LoCC`, `Bookshelves`, `Issued`); only `Text#` and `Title` are required.
- Book files are looked up under five naming patterns, flat or in a per-book subdirectory, so both a plain download and a mirror layout work. Ids are digits only, so a catalog row cannot name a path outside the books directory.
- The license header and footer are not stored at all; the rights record carries the license name, its URL, an attribution line and the conservative `restricted` flag instead of the boilerplate text.
- The CSV reader is strict (malformed input fails the job rather than being repaired) and bounded (field size and field count).
- The resume position is the catalog row count, which assumes the same catalog file; delivery after a replaced catalog repeats documents but never loses them.
- Fixtures are invented books under invented catalog entries, not copies of real ones, so tests are offline and no text is passed off as a real edition. Real files have not been tried against the full catalog yet; that needs a catalog download from the administrator's side.

Note (2026-11-14): Expat is also used by the feeds connector (ADR 0016); the build options are `-Dwikipedia` and `-Dfeeds`, and a library no enabled connector needs is still not built.

## Alternatives

- **Gutenberg from the RDF archive instead of CSV:** richer metadata but needs bzip2 and XML before the first connector works.
- **Wikipedia via a third-party plain-text extractor (e.g. WikiExtractor):** better text, but a Python dependency in the data path, and it contradicts the Zig-first, minimal-dependency rules.
- **Fetching from the web:** crawling Wikipedia or Gutenberg pages is against the sources' stated preference and the project's own rules.
- **Writing bzip2 and XML parsers ourselves:** against AGENTS.md section 4.

## Consequences if accepted

- Two more vendored C libraries (libbz2, expat) with pinned versions and recorded hashes, only when the Wikipedia connector is started.
- The first connector (Gutenberg) adds no new third-party dependency.
- Wikipedia text quality will be limited by the modest wikitext converter; this is documented as a limitation.

## Questions

Answered by the maintainer's acceptance of this record: the small CSV reader (decision 4) and vendoring libbz2 and expat for Wikipedia (decisions 5 and 6) are accepted.

Answered later (2026-11-14): English first. Still open: other language editions. It affects tokenizer work (today only the `unicode61` tokenizer is used) and is not needed until the connectors are built.
