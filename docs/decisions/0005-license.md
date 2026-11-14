# 0005. License: GPL-2.0-only

- Status: Accepted (2026-11-14, by the maintainer)
- Date: 2026-11-14

## Context

The project needs a license before it is published or accepts contributions. It vendors `toml-zig` (MIT) and SQLite (public domain), and builds with the Zig standard library (MIT).

## Decision

The project's own code and documentation are licensed under the GNU General Public License, version 2 only (SPDX identifier `GPL-2.0-only`). The full text is in `LICENSE`. Vendored components keep their own licenses and notices, recorded next to them in `vendor/`.

"Only" rather than "or later" follows the maintainer's request for version 2 specifically; moving to `GPL-2.0-or-later` later is possible with the agreement of all copyright holders.

## Alternatives

- GPL-2.0-or-later, GPL-3.0 and permissive licenses (MIT, Apache-2.0) were not selected.

## Consequences

- Anyone distributing modified versions, including as a network service's source if they choose to distribute it, must do so under GPL-2.0. Running an unmodified or modified copy as a service without distributing it does not trigger the license's source obligations (GPL-2.0 has no network clause).
- MIT and public-domain vendored code can be combined with GPL-2.0-only code. Any future dependency must be checked for compatibility; GPL-3.0-only and Apache-2.0 code, for example, is not compatible with GPL-2.0-only.
- Contributions are accepted under the same license.
