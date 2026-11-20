# 0077: regex-zig 0.4.0

Status: accepted

## Context

regex-zig v0.4.0 is a performance release: the lazy DFA's hot loop is one transition-table lookup per byte, first-byte sets and literal prefixes are searched with vector scans, and `Searcher.matchingLines` skips lines that cannot match. The public API is unchanged.

## Decision

`vendor/regex-zig` is the v0.4.0 release as published (`src/`, `build.zig`, `build.zig.zon`, `SPEC.md`, `README.md`; the tarball's SHA-256 is in `VENDORED_REVISION`). No dksearch code changed.

## Consequences

- Regular-expression searches over the index (`regexsearch.zig`) run on the faster engine; the library's own benchmarks show 3 to 10 times on line searches. Not measured in dksearch itself.
- The full test suite passes unchanged.
