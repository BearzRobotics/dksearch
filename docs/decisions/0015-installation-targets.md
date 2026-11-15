# 0015. Installation targets and service integration

- Status: Accepted (2026-11-14), as the minimal first answer to SPEC section 16 item 7
- Date: 2026-11-14

## Context

The SPEC lists installation targets and service integration as an open decision. The project does not use Docker (AGENTS.md), works offline, and ships a single binary plus a configuration file and a data directory.

## Decision

- **First target: Linux with systemd, installed from source.** `zig build -Doptimize=ReleaseSafe` produces the binary; `docs/deploy/` holds a hardened service unit, an import unit template, a backup unit and timer, an example configuration and a reverse-proxy and operations guide. The hardening settings were exercised with a transient user service (see that guide for what was and was not tested).
- **No installer, distribution package or container image yet.** The program has no post-install steps beyond creating a user and a directory, so the guide is the installer. Packages can be added later without changing the program.
- **TLS and rate limiting are the reverse proxy's job** (ADR 0004); the guide shows Caddy and nginx.
- **Other platforms**, cross-compiled from Linux with `-Dtarget=... -Doptimize=ReleaseSafe` on 2026-11-14: x86_64-linux-musl (a fully static binary; **run** here: import, check, serve and search work), aarch64-linux-gnu and -musl, riscv64-linux-gnu, x86_64-macos, aarch64-macos and x86_64-freebsd all **compile and link** (not run: no emulator or hardware here). Cross-compiling found one real bug, fixed: SQLite's "transient" marker constant was not valid for function pointers on ARM. **Windows does not build** (the program uses POSIX facilities such as file modes and terminal control, and the standard library's argument handling differs); it is not supported.

## Consequences

Operations documentation is part of the repository and must be kept in step with the commands and configuration keys. Platform support claims stay limited to what has been run.
