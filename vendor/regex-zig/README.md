# regex-zig (vendored)

A pure-Zig regular-expression library by the dksearch project owner (https://github.com/BearzRobotics/regex-zig), vendored at the revision in `VENDORED_REVISION` (version 0.1.0: Perl, Oniguruma and POSIX ERE parsers and a bounded backtracking engine). `SPEC.md` is its own specification.

Notes for dksearch:

- The upstream repository has no LICENSE file yet. The code is the project owner's own work and is included here under the project's GPL-2.0-only licence; a licence file should be added upstream and this note updated when it is.
- Matching is bytewise (no UTF-8 mode) and every search is bounded by a step budget and a stack limit rather than a linear-time guarantee. dksearch sets those limits itself (see `src/regexsearch.zig` and docs/decisions/0020).
- Only `src/`, `build.zig`, `build.zig.zon` and `SPEC.md` are vendored.

The latest upstream release when vendored was v0.1.0 (2026-11-13), the same revision.
