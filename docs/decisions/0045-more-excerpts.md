# 0045: More than one excerpt per result

Status: implemented.

## Context

One excerpt shows why a document matched, but a long document may use the word in places that say different things. The index gives one best fragment.

## Decision

- Further excerpts are taken from the **stored text** at request time, only when asked (`snippets=N`, 1 to 5), for the ten or so results of a page: the query's plain words (no operators, exclusions or `field:` conditions) are looked up in the text, and a window of about 180 bytes around each place is kept, at least that far from each other and from the excerpt already shown. They come in text order, with the usual markers; control bytes (including a stray marker byte) never enter an excerpt.
- They need the content store and a stored document; texts over 1 MiB and results of peers are left alone.
- The index and its ranking are untouched: no extra index data, nothing to rebuild.

## Alternatives

- Several FTS5 `snippet()` calls: the function returns one best fragment.
- Storing passage positions at indexing time: more index to keep and rebuild for a display feature.

## Consequences

- A request with `snippets=5` reads the text of each result: fast for a page, not for thousands (the API limit still applies).
- Excerpts are not ranked; they are the first places, in order.
