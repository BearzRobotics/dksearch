# 0025. ZIM (Kiwix) connector

- Status: Accepted (2026-11-15), the user's request ("can you support zim files from Kiwix as a search source")
- Date: 2026-11-15

## Decisions

1. **A connector reading `.zim` files** (format 5 and 6), offline: Wikipedia and many other sites are distributed this way. Options: `path`, `language`, `url_base`, `max_article_bytes`, `max_cluster_bytes`.
2. **A reader in Zig, not libzim.** libzim is a large C++ library with dependencies (xz, zstd, ICU, Xapian); a ZIM file is untrusted input; the format is small (a header, a MIME list, pointer tables, directory entries, clusters of blobs). The reader uses Zig's own xz and zstd decoders, checks every offset and size against the file, caps every allocation (`max_cluster_bytes`, `max_article_bytes`) and is covered by tests that damage and truncate a real archive randomly. This is a second exception to "use a library for an established format" (after the EXIF reader, ADR 0023), for the same reason: safety on untrusted input and no heavy dependency. It can be revisited if libzim support becomes necessary (for example for the newest features).
3. **Cluster order.** Directory entries are sorted by URL but clusters are filled in creation order, so reading article by article would decompress the same 1-2 MB cluster again and again. The connector scans the directory once (cluster, blob and entry number, 12 bytes per article), sorts by cluster and handles each cluster once. Resume position: the next cluster.
4. **What becomes a document**: entries in namespace `C` (or `A` in old files) of type text/html, application/xhtml or text/plain; the rest is skipped. The `Title` metadata names the dataset. Rights `unknown`.
5. **Limits of the standard library**: its xz decoder is young and keeps the whole decompressed cluster in memory (twice while copying); `max_cluster_bytes` bounds that. Its zstd decoder needs a window of 8 MiB; archives using larger windows are skipped per cluster (counted as `encoding`).

## Not done

Following a ZIM's own full-text index; images as documents; the title index; reading ZIM files in split form (`.zimaa`); a real-archive size benchmark (only a synthetic fixture and the tests are in the repository).
