# 0011. Wikipedia connector

- Status: Accepted (2026-11-14), implementing ADR 0007 decisions 5-9; the maintainer chose English first ("english comes first")
- Date: 2026-11-14

## Context

ADR 0007 settled the plan: vendor libbz2 and Expat for this connector only, read a local dump, convert wikitext modestly, keep provenance and licensing, resume by position. This record notes what was built and the choices the plan left open.

## Decisions

1. **Libraries.** bzip2 1.0.8 and Expat 2.10.0 are vendored under `vendor/bzip2` and `vendor/expat`, unmodified except for a project-written `expat_config.h`. Hashes and sources are recorded in each directory's README. The bzip2 tarball's SHA-256 matches several independent packagers; the Expat tarball's matches the digest GitHub publishes, and its detached signature was not checked (no maintainer key installed), which should be done before relying on it for a release.
2. **Build option `-Dwikipedia`, default on** (off by default only on Windows, which is unsupported for now). With `-Dwikipedia=false` neither library is compiled or linked (verified: no `XML_*` or `BZ2_*` symbols remain), the `wikipedia` kind is unknown, and the other connectors are unaffected. The default is on so that a plain `zig build` offers the connector; the amendment to ADR 0007 is that no data or source is enabled by default, not that the code is absent.
3. **Expat hardening.** Built with `XML_GE=0` (no general entity expansion) and without `XML_DTD`; the connector also refuses any DOCTYPE outright. A dump has none, and a hostile document therefore cannot use entity expansion. Parsing is a push parser fed 64 KiB chunks, so memory does not grow with the dump. Nesting depth is capped at 64 and every field has a size cap (article text: `max_article_bytes`).
4. **Resume without the index file.** ADR 0007 planned to use the multistream index file. It is not needed: libbz2 reports where each stream ends, so the connector saves the offset where the next stream starts (`bz2:OFFSET`) between pages, and plain XML saves the offset just after a page (`xml:OFFSET`). A resumed run is given a synthetic `<mediawiki>` root, because it starts mid-document. A single-stream `.bz2` cannot be entered mid-way and restarts, which duplicate detection makes cheap in writes (but not in decompression time).
5. **Which pages.** Namespace 0 only, no redirects, non-empty text. Disambiguation pages are indexed like any other article (no reliable marker without template expansion).
6. **Text conversion** is `wikipedia/wikitext.zig`: a single pass, linear time even for hostile input (an unclosed construct is tried once, then treated as plain text; nesting depth is bounded), UTF-8 preserved. It drops everything from level-2 headings such as "References" or "See also" on. Quality is judged on invented fixture articles, not on real dumps; real-world quality is unmeasured and will need a sample run on a real dump.
7. **Rights.** License `CC-BY-SA-4.0` with its URL, attribution pointing to the page history, an access note naming the older GFDL license and excluding media, and redistribution `allowed` (the explicit license grants it, with conditions). This is a claim about the dump's license as Wikimedia publishes it, to be re-checked against their terms when shipping.
8. **Fixtures** are invented articles in the export format, in plain and multistream bzip2 form (`src/connectors/testdata/wikipedia/`), so tests are offline and no real text is copied.

## Measured and not measured

Measured on a synthetic 1500-page multistream dump (not real Wikipedia): 1.8 s of CPU for the whole import, search correct on the converted text, `check` clean. Wall time there was dominated by this machine's slow fsync (6 minutes for 15 batches). Also tried on real wikitext: ten real English articles (Lighthouse, Rhubarb, Alan Turing, Roman Empire and others, 600 KB of XML) fetched through Special:Export, which uses the dump's format, and kept outside the repository. This found two converter bugs, both fixed with tests: a bare link target kept `&nbsp;` undecoded, and a template ending in `|}}` inside a table closed the table early (MediaWiki only honours `{|` and `|}` at the start of a line). After the fixes, none of the ten converted texts contained any template, link, table, tag or entity residue, and the prose read cleanly. Ten articles are a spot check, not a quality measurement.

Not measured: a real dump (tens of GB), memory at that scale, and conversion quality on real wikitext.

## Not done

Other language editions' specifics (tokenizer work for languages without word separators), Wikipedia's other dump types (abstracts, categories, history), image or media import, template expansion, and fetching dumps (the administrator downloads them).
