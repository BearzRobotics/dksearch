# 0065: The title weight, chosen against the owner's marks

Status: accepted for the owner's instance; the project default is unchanged

## Context

On "how to program in c" the owner marked 30 results (ADR 0064): 28 bad, 2 good. The bad ones were long pages that mention "program" and the letter "c" many times (Windows CMD manuals, Lua and SQLite documentation, GitHub topic pages) with titles unrelated to the question; the good ones had a short title about it ("C - Gentoo wiki", the GNU C library). With `[search] title_weight = 10` the scores were nearly flat (12.3 down to 9.7 over 50 results) and driven by the body.

## Measurement

`dksearch eval` on the 11 golden queries and the owner's marks together (pictures left out, one result per page, English preferred):

| title_weight | mean reciprocal rank | mean nDCG@10 |
|---|---|---|
| 10 (default) | 0.667 | 0.740 |
| 30 | 0.765 | 0.783 |
| 100 | 0.803 | 0.810 |
| 200 to 1000 | 0.818 | 0.811 |

"css flexbox" and "little book about os development" went from second and seventh to first; the first wanted result for "how to program in c" from ninth to second; "zig comptime" from fourth to sixth.

## Decision

The owner's configuration sets `title_weight = 100`. The default stays 10 until there are more marks than a dozen queries; the numbers above are a small set, partly chosen by the author, and weights beyond 200 change nothing (the title dominates).

## Consequences

A page whose title is about the query now beats a page that only mentions the words many times, which is what the marks asked for. A page whose title is unrelated but whose text is the best answer ranks lower than before. The marks keep growing: the comparison is repeated with `dksearch eval --config` on a copy of the configuration with another `title_weight`.
