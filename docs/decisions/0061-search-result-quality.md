# 0061: Result quality: pages not pictures, the reader's language, one site not a whole page

Status: accepted

## Context

Looking at real searches of the playground index showed three things that made results poor. Pictures indexed from pages (an inline SVG's alt text, with the page's address and words) outranked the pages they came from: a search for "css flexbox" returned eight pictures of one MDN page. A site with twenty translations filled a page with the same page in twenty languages. One site could take the whole first page.

## Decision

- An ordinary search leaves out `kind:image` documents; the Images button is how pictures are found, and a search that names a kind, a media type or an extension is left as it is.
- The browser's `Accept-Language` gives the languages the person reads. A page in another language has its score multiplied by 0.3 (`langprefer.foreign_factor`); nothing is hidden. The crawler now records the page's `<html lang>`; for pages stored without a language the first segment of the address is used (`/ja/`, `/zh-CN/`) from a list of languages that leaves out codes which are also ordinary words.
- `[search] per_domain` defaults to 3, and a search that names a domain is not limited.

## Consequences

Someone who searches for a local photo by name now needs the Images button or `kind:image`. A visitor whose browser sends no `Accept-Language` sees no change. The per-domain default can hide the fourth good result of a site; the person can raise it or name the domain.
