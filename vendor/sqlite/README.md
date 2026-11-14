# Vendored SQLite

- Version: 3.54.1 (amalgamation `sqlite-amalgamation-3540100.zip`)
- Source: https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
- SHA3-256 of the zip (matches the value published at https://sqlite.org/download.html):
  `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`
- Files kept: `sqlite3.c`, `sqlite3.h`. The shell (`shell.c`) and `sqlite3ext.h` are not vendored; extension loading is compiled out.
- License: public domain (https://sqlite.org/copyright.html).
- Build options are set in the top-level `build.zig`. See `docs/decisions/0003-index-backend.md`.

Do not edit these files. To update: download the new amalgamation, verify its published hash, replace both files, and update this README.
