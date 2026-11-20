# regex-zig (vendored)

A pure-Zig regular-expression library by the dksearch project owner (https://github.com/BearzRobotics/regex-zig), vendored at the revision in `VENDORED_REVISION` (version 0.3.0: Perl, Oniguruma and POSIX ERE parsers and a bounded backtracking engine). `SPEC.md` is its own specification.

Notes for dksearch:

- The upstream repository has no LICENSE file yet. The code is the project owner's own work and is included here under the project's GPL-2.0-only licence; a licence file should be added upstream and this note updated when it is.
- Matching over characters uses the library's own UTF-8 mode (`Options.utf8`, Unicode properties and simple case folding; `-Dunicode_tables=false` would leave the tables out). The default engine is the lazy DFA with the Pike VM for captures; the backtracker (still bounded by a step budget and a stack limit, which dksearch sets itself: see `src/regexsearch.zig` and docs/decisions/0020-regex-search.md) runs the patterns the linear-time engines cannot (back-references, look-around).
- Only `src/`, `build.zig`, `build.zig.zon` and `SPEC.md` are vendored.

The latest upstream release when vendored was v0.3.0 (the same revision): see `VENDORED_REVISION`.
