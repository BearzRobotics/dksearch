# 0067: regex-zig 0.3.0

Status: accepted

## Context

dksearch vendors the owner's regex-zig library (ADR 0020). The vendored copy was v0.1.0 with a local patch for matching over characters (ADR 0050); the revision file said a re-vendoring "must carry them over or take upstream's own UTF-8 mode". Upstream v0.3.0 has its own: `Options.utf8` since 0.2.0, with Unicode properties and simple case folding.

## Decision

`vendor/regex-zig` is the v0.3.0 release as published (`src/`, `build.zig`, `build.zig.zon`, `SPEC.md`; the tarball's SHA-256 is in `VENDORED_REVISION`). The local patch is dropped. `regexsearch.zig` needed no change: it already set `utf8 = true` and the limits that still exist.

## Consequences

- The default engine is a lazy DFA with a Pike VM for captures: patterns without back-references, look-around, atomic groups or possessive quantifiers run in time proportional to the text, so `(a+)+$` is no longer refused as too complex. Only patterns that need the backtracker are bounded by `search.regex_max_steps`; the tests use `(a+)+\1$` for that.
- `\p{L}` and other Unicode properties are accepted (they were refused before).
- The source grows by about 0.9 MB (the Unicode tables are 340 KB of it) and the binary by some 170 KB; `-Dunicode_tables=false` on the library would leave them out.
- POSIX BRE and the Rust dialect exist in the library; dksearch still offers Perl and POSIX ERE.
