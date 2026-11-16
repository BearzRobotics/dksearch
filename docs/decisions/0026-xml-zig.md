# 0026: Our own XML library (xml-zig), vendored

Status: vendored and building; not used yet. Replacing Expat is a later step.

## Context

dksearch reads XML today through Expat (ADR 0007, 0011), vendored as C and used
only by the Wikipedia connector. Two upcoming features need XML too: text
extraction from Office documents (`docx`, `odt`, which are zip files of XML
parts) and, later, other XML sources. The project rule is to prefer our own
pure-Zig libraries (`toml-zig`, `regex-zig`) over new C code, and the maintainer
asked for an XML library of the same kind.

## Decision

- Write `xml-zig` as a standalone repository (https://github.com/BearzRobotics/xml-zig, MIT): a streaming pull parser over `std.Io.Reader`, a small tree that keeps comments, and a writer. Its requirements, limits and test results are in its `ai/SPEC.md`; it passes the W3C XML Conformance Test Suite except where it deliberately does not interpret DTDs or support XML 1.1.
- Vendor release 0.1.0 under `vendor/xml-zig` (revision in `VENDORED_REVISION`) as a path dependency, like `toml-zig` and `regex-zig`; a build needs no network access. Vendored code is not edited in place; updates replace the directory.
- Import it into the core module as `xmlzig`. It adds no C code and no compile-time option.
- Keep Expat for the Wikipedia connector for now. Switching the connector to `xml-zig`, and dropping the vendored C Expat, is a separate step after measuring it on a full dump (the library read a 100 MB sample at about Expat's speed).

## Consequences

- The Office-document extractor can be written without a new C dependency.
- Known limits carry over: UTF-8, US-ASCII, UTF-16 and ISO-8859-1 input only; DTD entities are not expanded (callers can supply names).
- One more vendored directory to keep in step with upstream.

## References

- `vendor/xml-zig/ai/SPEC.md`, `vendor/xml-zig/docs/decisions/0001-pull-parser-and-scope.md`.
- XML 1.0 (Fifth Edition), https://www.w3.org/TR/xml/ ; Namespaces in XML 1.0, https://www.w3.org/TR/xml-names/ .
