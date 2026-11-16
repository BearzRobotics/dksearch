# Test corpus and evaluation

A repeatable corpus, with queries and the documents each should find, so that search quality, speed and size can be compared across changes and against reference projects. Nothing here duplicates the specification.

## Contents (to assemble)

A small ZIM; a document collection of mixed types; an HTML site; PDFs with text and scanned PDFs; EPUB; Office and OpenDocument files; Markdown; source code; RSS and Atom feeds; a small WARC sample; documents duplicated across sources; non-English text and Unicode edge cases; documents with similar titles and different contents; documents that change or vanish between runs. Where possible use public or self-made material that may be kept in the repository (small), and keep large data under `/mnt/scratch`. The owner's personal documents are never part of the corpus and never named.

## Judgments

A file of queries with the documents expected for each (the repository already has a judgments format used by the `evaluate` command; extend it rather than inventing another).

## Measures

Recall and precision at K, ranking quality (for example reciprocal rank), query latency percentiles, index size, ingestion speed, extraction quality (text compared with a reference), memory and CPU.

## Existing measurements

`docs/performance.md` holds import, size and latency numbers for Simple English Wikipedia, English Wikipedia and a PDF book pilot.
