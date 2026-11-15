# 0015. Installation targets and service integration

- Status: Accepted (2026-11-14), as the minimal first answer to SPEC section 16 item 7
- Date: 2026-11-14

## Context

The SPEC lists installation targets and service integration as an open decision. The project does not use Docker (AGENTS.md), works offline, and ships a single binary plus a configuration file and a data directory.

## Decision

- **First target: Linux with systemd, installed from source.** `zig build -Doptimize=ReleaseSafe` produces the binary; `docs/deploy/` holds a hardened service unit, an import unit template, a backup unit and timer, an example configuration and a reverse-proxy and operations guide. The hardening settings were exercised with a transient user service (see that guide for what was and was not tested).
- **No installer, distribution package or container image yet.** The program has no post-install steps beyond creating a user and a directory, so the guide is the installer. Packages can be added later without changing the program.
- **TLS and rate limiting are the reverse proxy's job** (ADR 0004); the guide shows Caddy and nginx.
- **Other platforms**: the code is portable Zig and the build selects entropy sources per OS, but only Linux has been built and run. macOS and the BSDs are expected to work and untested; Windows is not supported (the Wikipedia connector refuses to build there; the rest is untested).

## Consequences

Operations documentation is part of the repository and must be kept in step with the commands and configuration keys. Platform support claims stay limited to what has been run.
