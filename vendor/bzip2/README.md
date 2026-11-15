# Vendored bzip2 (libbz2)

- Version: 1.0.8 (13 July 2019)
- Source: https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
- SHA-256 of the tarball: `ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269`. It matches the value recorded by independent packagers (Debian, OpenEmbedded, Meson WrapDB, Wolfi).
- Files kept, unmodified: `blocksort.c bzlib.c bzlib.h bzlib_private.h compress.c crctable.c decompress.c huffman.c randtable.c LICENSE`. The command-line tools, documentation and build files are not vendored.
- License: bzip2 license (BSD-style), see `LICENSE`.
- Used only by the Wikipedia connector (`docs/decisions/0011-wikipedia-connector.md`), and compiled only when the build option `-Dwikipedia` is on (the default).

Do not edit these files. To update: download the new release, verify its published hash, replace the files, and update this README.
