# 0050: Regular expressions over characters

Status: implemented (supersedes the byte-semantics point of ADR 0020).

## Context

The vendored engine (ADR 0020) matched bytes: `.` matched one byte, `[é]` was two byte alternatives, `é+` repeated the last byte, and `\w` ignored every letter outside ASCII. Results were wrong for most languages other than English.

## Decision

- The vendored library gains an option `utf8`. In that mode the parser reads characters: a non-ASCII literal becomes one unit (a group of its bytes, so a quantifier repeats it), `.` and classes are compiled to alternations of UTF-8 byte sequences (a range of code points is split into sequences of byte ranges, the classic algorithm, with surrogates left out), negated classes are complemented over all code points, `\x{...}` names a code point, and `\w` includes every non-ASCII character. The engine stays bytewise; only the compiled program changes, and a word boundary treats bytes of non-ASCII characters as word bytes.
- dksearch turns it on for every regex search. Results and snippets are widened to character boundaries as before.
- Invalid UTF-8 in a document never crashes the matcher: a character pattern simply does not match those bytes. An invalid pattern is refused.

## Not done

- Case-insensitive matching of non-ASCII letters, Unicode properties (`\p{L}`), `\d` and `\s` beyond ASCII, nested classes and class intersection over characters: refused or ASCII only, and documented.

## Consequences

- Patterns with big non-ASCII ranges compile to larger programs (a range such as `[\u{80}-\u{10FFFF}]` is a handful of alternatives, not thousands); the program-size limit still applies.
