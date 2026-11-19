# 0055: The thumbnail cache

Status: accepted

## Context

The gallery showed the original pictures, scaled by the browser: heavy for large wallpapers, and for pictures of the web every
view went through the relay. The owner wanted small copies kept, but only as an opt-in, with a size limit they choose, and
without storing more than the small copy.

## Decision

- `[images] thumbnails = true` turns it on. A thumbnail is made on first use: the original (a file the server may serve, or a
  web picture fetched through the relay) is decoded, turned upright by its EXIF orientation, reduced to `thumbnail_px` on the
  long side and written as a JPEG; only that is kept (`dir/ab/cd/ID.jpg`). Nothing is made until a picture is shown.
- The libraries that read pictures cannot write them, so `jpegenc.zig` is a small baseline JPEG encoder (4:2:0, the standard
  quantisation tables scaled by a quality, Huffman tables made per picture). It is tested against another decoder.
- The folder has a size limit (`thumbnail_cache_mb`, 16 MiB to 1 TiB, default 1 GiB). Its size is measured once and kept; over
  the limit, the oldest thumbnails are deleted until it is 10% under. At most two are made at once.
- What cannot be shrunk (a format not read here, too large, busy) redirects to the original, so a picture is never missing.

## Consequences

Disk use is capped and visible (Maintenance page, with a clear button). Thumbnails are derived copies of other people's
pictures: they exist only when the owner turns the cache on. Eviction is oldest-made-first, not least-recently-used, and a
changed original is not noticed until its thumbnail is evicted or the cache is cleared.
