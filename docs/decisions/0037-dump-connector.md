# 0037: One connector for archives and dumps

Status: implemented (zip, warc, stackexchange, reddit).

## Context

People have data in archive and dump formats that dksearch could not read: ZIP files of documents, WARC web archives (Common Crawl, wget), Stack Exchange data dumps and Reddit dumps. Each is "files you already have", needs no network, and is read the same way: walk a path, stream each file, emit documents.

## Decision

- One connector kind, `dump`, with a `format` option, instead of four kinds. Each kind costs a registry entry, an option table, a form in the administration interface, documentation and a place in every list of kinds; the four formats share all of that and differ only in a reader function.
- Every reader streams: gzip and zstd through the standard decompressors, XML through xml-zig's pull reader, lines through a bounded line reader. A file is never held whole; a document's text is capped by `max_file_bytes`.
- Stack Exchange is read in two passes over `Posts.xml`: the first remembers each question's title and which answers were accepted (small), the second emits documents, so an answer can carry its question's title (its row has none) without holding the answers.
- WARC `.gz` files are read member by member. Responses are accepted only with status 200, an HTML or plain text media type, UTF-8 text and an encoding that can be undone (identity, chunked, gzip); everything else is counted with its reason (`wrong_type`, `encoding`, `http_status`) like the crawler's refusals.
- Reddit lines that are not JSON or that are over 8 MiB are skipped, not fatal. Filters (`subreddits`, `min_score`, `include_nsfw`) decide what is kept before anything is stored, because these dumps are far larger than anyone wants indexed whole.
- The resume position is the last finished file. A restart repeats the file it was in; the pipeline's content hashes make that cost time only.
- Rights: Stack Exchange documents carry CC BY-SA with attribution; web archive and Reddit documents say redistribution is unknown and the terms of the source apply.

## Alternatives

- A kind per format: simpler per reader, four times the plumbing.
- Position inside a file for resume: precise for plain files, not for compressed streams without an index; not worth the state.
- Extracting 7z (Stack Exchange dumps ship as `.7z`): no 7-zip reader in the standard library; unpack once with `7z x`.

## Consequences

- A very large dump is one long run. Cancel and restart repeat the current file.
- zstd dumps made with `--long` need a large window in memory; the option says so.
