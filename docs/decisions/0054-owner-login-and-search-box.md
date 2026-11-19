# 0054: Owner login on the search page, and the multi-line search box

Status: accepted

## Context

Signing in with an API key (ADR 0053) meant making a key on the command line and pasting it. The owner wants a Login button
on the search page that shows everything the server holds. They also want Enter to search and Shift+Enter to add a line.

## Decision

- One owner password, stored as an Argon2 hash in `owner-login.toml` (set with `dksearch owner-password` or on the Access
  page). `/login` accepts it, or an API key. A login is a cookie `dks_owner` carrying an expiry and an HMAC of it keyed by the
  stored hash: nothing is kept on the server, a restart does not log anyone out, and changing or removing the password ends every
  login. The owner's view is every source with safe search lifted. Wrong passwords: five a minute.
- The Login button sits at the top right of the search pages, only when a password or keys exist.
- The search box is an `<input>` that works without scripts. `search.js` (served from `/assets/`, allowed by the existing
  content-security policy) swaps it for a textarea: Enter submits, Shift+Enter is a line break, it grows with its text.

## Consequences

A cookie cannot be revoked before it expires except by changing the password. The password is as strong as the owner makes it
(8 to 128 characters; the throttle is the only brute-force defence, so a public instance should use a long one and HTTPS).
