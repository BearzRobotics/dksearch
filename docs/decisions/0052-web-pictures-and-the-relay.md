# 0052: Pictures of the web, shown through a relay that stores nothing

Status: accepted

## Context

The Images button shows pictures as a gallery. Local pictures come from files (`images = true`). The owner also wants pictures found on crawled pages, without filling the disk with copies or thumbnails.

## Decision

- A crawl source with `index_images = true` records the pictures of each stored page (`<img>`, `data-src`, `og:image`; not inline `data:` addresses, not pictures marked under 100 pixels) as small documents of kind image: the text holds the picture's address, the page and the words the page gives it. The picture is not downloaded. At most `max_images_per_page` (12) per page, each address once per run. Pictures on hidden networks and on banned domains are left out. The document's address is the page, so the ban and safe-search lists decide by the page's domain.
- With `[images] remote = true` the gallery shows them through `/doc/ID/image`: the server fetches the address stored in the index (never one from the request), and passes the bytes on. Nothing is written to disk. Browsers may keep it for an hour (`private, max-age=3600`), so the visitor's browser never contacts the source site.
- The relay refuses private and local addresses, answers that are not `image/*`, pictures over `relay_max_mb` (8), redirects beyond 3 (each checked again), and more than `relay_concurrency` (6) at once (503 with Retry-After). Responses carry `nosniff`, a sandboxing CSP and `no-referrer`.
- An opt-in thumbnail cache is possible later and is not built.

## Consequences

Disk use is a few hundred bytes per picture. Showing a picture costs a fetch from the source each time the browser does not have it. DNS rebinding between the check and the fetch is not stopped (same known limit as the crawler).
