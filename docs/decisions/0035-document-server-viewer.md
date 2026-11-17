# 0035: Opening office files in a document server

Status: implemented; tested against OnlyOffice Docs 10 and Collabora Online 26.04 in a real browser.

## Context

Search results for office files showed extracted text only. People want to see the document as it looks. Writing a renderer for docx, xlsx, pptx and the OpenDocument formats is a project of its own; OnlyOffice and Collabora already do it, and people who run a document server already have one.

## Decision

- dksearch does not render or edit. `[docserver]` names a server the operator runs (`kind` `onlyoffice` or `collabora`, `url` for the browser, `public_url` for the server to reach dksearch).
- The viewer links to `/doc/ID/open`. It applies the normal scope checks, then redirects to Collabora (which fetches over WOPI) or serves a page that loads OnlyOffice's `api.js` and starts a read-only viewer pointed at the file.
- The server reads the file through `/wopi/files/ID` (CheckFileInfo: name, size, version, read-only) and `/wopi/files/ID/contents`, with an `access_token`: an HMAC-SHA256 over the document id and an expiry (one hour), signed with a secret made at start. A token is for one document and for reading only. These routes ignore API keys and the `Authorization` header (Collabora sends its token there too; it must not be mistaken for an API key), and answer 401 for anything but a valid token for that id.
- OnlyOffice's configuration is signed as a JWT (HS256) when `jwt_secret` is set, as its Docker image expects by default. The key of the document (its cache identity) includes the file's modified time so a changed file is shown fresh.
- The OnlyOffice page carries its own Content-Security-Policy (one policy: two would both apply): the inline script by hash, the document server's script, frame and connections, nothing else.
- Offered only for office extensions, only when the source serves originals, only when `[docserver]` is configured.

## Alternatives

- Serving the file with the API key in the URL: leaks a long-lived credential to a third party and into logs.
- A proxy that streams the editor through dksearch: more code, and the editors are heavy, websocket-based applications.
- Editing: needs write-back (WOPI PutFile / OnlyOffice callbacks) and locking; the index is built from files that people may not want changed. Not a goal.

## Consequences

- A token can be used by anyone who sees the address of the editor page for an hour; it reads one file. Short life and one-file scope are the mitigation.
- Restarting dksearch invalidates open links.
- The test setup needs host-reachable addresses, Collabora's WOPI host allow-list and OnlyOffice's private-address allowance; the manual says so.
