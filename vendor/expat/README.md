# Vendored Expat

- Version: 2.10.0 (released 2026-11-02)
- Source: https://github.com/libexpat/libexpat/releases/download/R_2_10_0/expat-2.10.0.tar.gz
- SHA-256 of the tarball: `5466a341f9c692ef7a958a6881311be597f8e1ce345984cf78414f54793dea4c`. It matches the digest GitHub publishes for that release asset. The detached signature (`.asc`) was not checked, because no maintainer key is installed here; checking it is a good thing to do before relying on this copy.
- Files kept, unmodified: the C sources and headers of upstream `lib/`, and `COPYING`. Only `xmlparse.c`, `xmlrole.c` and `xmltok.c` are compiled (the other `.c` files are included by those or are alternative entropy sources; the right one is selected by the build).
- Not upstream: `expat_config.h` was written for this project (minimal features: no general entities, no DTD) and replaces the generated one.
- License: MIT, see `COPYING`.
- Used by the Wikipedia and feeds connectors (`docs/decisions/0011-wikipedia-connector.md`, `0016-feeds-connector.md`), and compiled only when the build option `-Dwikipedia` or `-Dfeeds` is on (both are the default).

Do not edit the upstream files. To update: download the new release, verify its published hash and signature, replace the files, and update this README.
