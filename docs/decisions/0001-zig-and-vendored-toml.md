# 0001. Zig 0.17.1 and a vendored toml-zig

- Status: Accepted
- Date: 2026-11-14

## Context

`ai/AGENTS.md` requires the core to be written in Zig, TOML for configuration, and reproducible, offline-buildable dependencies. The selected TOML library is `toml-zig` (https://github.com/BearzRobotics/toml-zig). At the time of this decision its version 0.2.0 declares `minimum_zig_version = "0.17.1"` and has no dependencies of its own.

## Decision

- Target Zig 0.17.1 (`minimum_zig_version` in `build.zig.zon`).
- Vendor `toml-zig` under `vendor/toml-zig/` at revision `910d6450aacbb1b7fbd74c29919226cd1026a446`, recorded in `vendor/toml-zig/VENDORED_REVISION`. It is referenced as a path dependency, so a build needs no network access.
- The API in use was taken from the vendored source and its tests, not assumed. The project uses `Document.parse`, `Diagnostic` and the typed `Table` accessors.
- Vendored code is not edited in place. Updates replace the directory wholesale and update `VENDORED_REVISION`.

## Alternatives

- A fetched dependency pinned by hash: smaller repository, but a first build needs the network.
- A git submodule: adds a second tool requirement and makes offline checkouts fragile.
- Writing a TOML parser: rejected by AGENTS.md section 4.

## Consequences

- Builds are reproducible and work offline.
- The repository carries `toml-zig`'s sources, docs and tests. Its MIT license text is retained in `vendor/toml-zig/LICENSE`.
- Moving to a newer Zig requires a matching `toml-zig` revision.
