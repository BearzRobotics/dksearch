# Wuffs (vendored)

Google's Wuffs, "Wrangling Untrusted File Formats Safely": decoders generated from a memory-safe language, used here to read JPEG, PNG, GIF, WebP and BMP images (untrusted input: files in indexed folders, crawled pages, images uploaded to search by image).

- File: `wuffs-v0.4.c`, the single-file release of **v0.4.0-alpha.11** from https://github.com/google/wuffs-mirror-release-c (release/c/wuffs-v0.4.c). SHA-256: `458066457347bd6d9bc3c906aa8292bea4488577727569ddd9436fdd89d5f04d`.
- License: Apache-2.0 OR MIT (the file's header says so), SPDX `Apache-2.0 OR MIT`.
- Why this version: v0.3 is the stable release but has no stb_image-compatible API; v0.4 (still alpha upstream) does, which keeps our wrapper to three calls. The decoders are generated code with bounds checks, which is the point of using Wuffs rather than stb_image (whose own header recommends Wuffs for security-sensitive use).
- `impl.c` compiles it with only the modules needed (base, BMP, GIF, JPEG, PNG, WebP/VP8, zlib/deflate/adler32/crc32/lzw) and the stb-compatible interface turned on. `../wuffs_c.h` declares the four functions dksearch calls.
- Built only with `-Dmedia` (default on, except on Windows).
