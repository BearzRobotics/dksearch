# 0012. Admin interface, authentication and request logging

- Status: Accepted (2026-11-14, by the maintainer): bearer token as the primary credential with a password login as the fallback; counters plus an opt-in access log that never records query text
- Date: 2026-11-14

## Context

SPEC milestone 4 needs an administration interface, separate from the public one (AGENTS.md section 3 and 7), and ADR 0004 left its authentication to its own record. The public server also had no operational visibility and no log. Search queries can reveal personal information, so logging needs an explicit privacy position.

## Decisions

### Authentication

1. **Primary credential: a bearer token.** `dksearch admin-token` generates 32 random bytes (printed once as `dks_` plus base64url), stores only its SHA-256 in the secrets file, and prints the token. API clients and scripts send `Authorization: Bearer TOKEN`. Rotating means running the command again; the old token stops working at once for new requests.
2. **Fallback: a password.** `dksearch admin-password` reads a password (hidden on a terminal, else one line from standard input), stores an Argon2id hash (std.crypto, OWASP parameters), and never the password. The browser login form accepts the password or the token (so a token-only setup can still use a browser). A successful login creates a session.
3. **Sessions** are random 256-bit ids kept in memory only (a restart logs everyone out), sent as a cookie with `HttpOnly`, `SameSite=Strict`, `Path=/` and, when configured, `Secure`. They expire after a configurable idle time (default 30 minutes) and an absolute lifetime (8 hours). Every state-changing request is a POST that must carry a per-session CSRF token as well as the cookie. Logging out deletes the session.
4. **Brute force.** Failed form logins are slowed down: after repeated failures in the whole process, each attempt waits a growing delay (none for three, then 250 ms doubling to 5 s, forgotten after 15 quiet minutes). At most four attempts may be waiting at once (more get 429 at once) and at most two password verifications run at once, since Argon2 is deliberately expensive; a delay never holds a verification slot. Wrong bearer tokens are neither counted nor delayed: they carry 256 bits, and counting them would let anyone slow the administrator's sign-in. There is no per-client tracking, because that needs client addresses, which are not recorded, so an attacker who keeps failing can keep the form slow for everyone; the token is unaffected, and the delay is capped below the write timeout. (Found in an independent review of the first implementation.)
5. **Secrets file.** `secrets_file` in `[admin]` (default `data_dir/admin-secrets.toml`) is TOML, written with mode 0600, replaced atomically. dksearch refuses to read it when group or others can read it. It is never part of the main configuration and never contains a plaintext secret.
6. **Fail closed.** If the admin listener is configured but the secrets file holds neither a token hash nor a password hash, it does not start (the public server still does) and says how to fix it. No credential is created implicitly and there is no default password.
7. **Transport.** The admin listener defaults to loopback. TLS is terminated by a reverse proxy (ADR 0004); when the proxy serves HTTPS, set `cookie_secure = true`. The documentation states plainly that a token or password sent over an unencrypted non-loopback connection can be read by anyone on the path.

### Admin interface scope (first version: read-only)

`GET /` (dashboard: sources with document counts and last job, index size, counters, version), `/jobs` (recent import jobs), `/login`, `POST /login`, `POST /logout`, and JSON under `/api/v1/admin/` (`status`, `sources`, `jobs`), all behind authentication. It reads `state.db` read-only, so it is safe while an import runs. Starting and cancelling imports from the interface, running `check` from it, and editing configuration are deliberately left out of this version: they need a job runner inside the server process and a lock protocol with the CLI, and deserve their own decision.

### Logging and visibility

8. **Counters, always on, in memory:** requests by status class and route label, latency buckets, connections accepted, refused and timed out. Shown on the admin dashboard and in `status`. Nothing is written anywhere.
9. **Access log, off by default.** `access_log = "stderr"` or a file path under `[server]` and `[admin]` writes one line per request: UTC time, method, route label, status, duration in milliseconds, response bytes. It never records query strings, request targets, client addresses, user agents, cookies or credentials; the route is a fixed label such as `/search`, not the URL. Rotation is the operator's (logrotate with copytruncate works: each line is appended at the file's current end). The two listeners cannot share one log file.
10. **Not offered:** a full request log with queries and addresses. If relevance tuning later needs query data, that gets its own decision with a retention limit.

## Alternatives considered

Username and password as the only method (login form, cookies, CSRF and a stored user for a single-administrator tool: more surface, and no script access); Unix socket only (no browser); client certificates (heavy to deploy). A token only (no browser login) was the other half of the maintainer's choice.

## Consequences

- Credentials never appear in the TOML file, logs or process arguments (the password is read from the terminal or standard input, never from an argument).
- Sessions are lost on restart, and there is no revocation list beyond rotating credentials: rotating the secrets file invalidates all sessions the next time one is checked.
- Without a reverse proxy the admin interface should stay on loopback.
