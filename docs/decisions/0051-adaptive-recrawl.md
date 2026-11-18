# 0051: Adaptive recrawl of pages

Status: implemented for pages at the depth limit. Extends ADR 0036.

## Decision

- The validators file (ADR 0036) also records, per page, a hash of the body, the page's own interval and when it is due. With `recrawl_adaptive = true`, a page at the depth limit that is not due is not requested; when it is due it is asked conditionally (304 means unchanged); a 200 is compared with the stored hash.
- The interval starts at a day, grows by a fifth for each unchanged check and shrinks by a fifth for each change, within `recrawl_min_hours` and `recrawl_max_days`.
- Pages with links to follow are always fetched in full, as before: skipping them would need their links kept, which is the size of the link graph (the alternative rejected in ADR 0036).
- The file format only gains fields at the end of each line; older files keep working.

## Consequences

- A recrawl asks only for pages that are due; the rest of a large site costs nothing. A page that changes every hour is checked about as often as the minimum interval; a page that never changes drifts to the maximum.
