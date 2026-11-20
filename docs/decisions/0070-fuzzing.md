# 0070: Fuzzing the parsers of outside input

Status: accepted

## Context

Two bugs of today (an integer underflow in the word-forms stemmer, found by an ordinary test only by luck; a second session parameter left in an address by `frontier.tidy`) are of the kind a fuzzer finds at once. The crawler reads arbitrary web pages, feeds, robots.txt files, sitemaps and wiki answers, and the server reads headers and forms; only two tests used random input.

## Decision

`src/fuzz.zig` holds fuzz targets (`std.testing.fuzz`, Zig's built-in coverage-guided fuzzer) for the parsers of input that nobody here wrote: HTML text, titles and links; RSS and Atom feeds; robots.txt; address tidying; address parts; domain lists; the answers of a wiki's API; `Accept-Language`, language checks and word stems; query text; judgments and feedback lines; picture metadata; configuration files. Each checks what must hold of the result (idempotence, limits, quoting, no leak) besides not crashing. A plain `zig build test` runs each once on its seed inputs; `zig build test --fuzz=300K` searches for failing inputs. The build leaves the C libraries uninstrumented in fuzz mode. The first run found the `tidy` bug within seconds; it is fixed and tested.

## Consequences

New parsers of outside input get a target with a few lines. The report of Zig 0.17.1 ends with "corrupted coverage file ... pcs_len was zero" because the HTTP test binary has no fuzz target; it does not mean nothing ran. The zip reader, the HTTP request head and the importers are not fuzzed yet.
