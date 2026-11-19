# 0053: Export file, sign-in with a key, and public mode

Status: accepted

## Context

The owner will host a public instance (dksearch.org) that must hold only what is crawled from the web, and later a home
server that holds everything and shows the public one collection. Copying a crawl between machines that are not
connected, seeing "everything" from a browser, and making sure a public server cannot hand out files were all missing.

## Decision

- `dksearch export` writes the documents of named sources as JSON lines in the shape of the peer export
  (`/api/v1/export`), without needing a network between the machines. A `dump` source with `format = "export"` reads it.
  Banned domains are left out; `file://` addresses are dropped on import; pages are named by address so re-imports
  update them.
- `/login` accepts an API key and stores it in a cookie, `/logout` removes it. The cookie's key is resolved exactly like
  a bearer key (collections, adult flag, rate limit); an invalid or node-bound key is ignored, so the browser is
  anonymous and not locked out. The key is a bearer secret: the cookie is HttpOnly, SameSite=Lax and, with
  `[access] cookie_secure`, Secure. Removing the key revokes every browser at once.
- `[server] public_mode` is a refusal at load time: no public collection named, a publicly searchable source that serves
  originals, or an administration address that is not loopback.

## Consequences

One server can serve a public view and a full one. A stolen cookie is a stolen key: it is as strong as the key, which
is why keys can have a rate limit and are revoked by name. The export file is plain text of everything exported; protect
it like the index.
