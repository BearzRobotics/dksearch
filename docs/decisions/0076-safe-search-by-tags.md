# 0076: Safe search by the tags of a page

Status: accepted

## Context

Safe search (ADRs 0048, 0049) hides whole domains. A site can have pages of both kinds, and a domain list never sees a new site. Pages now carry their own tags (ADR 0074), which say what a page is about. A tag is evidence, not proof: `#bikini` is a swimwear shop, `#nude` an art class, `#sex` a health page.

## Decision

- While safe search is on, a page is hidden when it has **one strong tag** (a word used almost only for adult material) or **two weak tags** (words with innocent uses) of an active category. One weak tag never hides a page.
- The categories are a TOML file (`src/assets/safe_tags.toml` is built in; `[safe_search] tags_file` replaces it): `[[category]]` with `name`, `level` (`moderate` or `strict`), `strong` and `weak`. `tag_filter` is `off`, `moderate` (the default: explicit content, fetish, adult services, graphic sexual violence) or `strict` (also suggestive and mature themes); `tags_off` skips categories by name. The admin panel has the mode in the safe-search card.
- Tags are compared in a compact form (lower case, letters and digits only), so "Rope Bunny", "rope_bunny" and "#RopeBunny" are one tag, whatever case a source stored. There is no pattern matching: a variant is listed as an alias, because a pattern hides innocent pages.
- Medical and educational tags (sex education, sexual and reproductive health, anatomy, figure drawing, artistic nudes, naturism, breastfeeding) are deliberately absent from the built-in list; a test keeps them out.
- It is SQL added to the search while safe search is on (`safetags.zig`, `Index.setSafeTags`), applied before ranking and paging like the domain ban, so a page is never short of results because blocked ones used the places. It adds to the domain lists; the PIN unlock and adult API keys bypass it as they do those.

## Consequences

It needs no new tables and no re-crawl, only a restart, but it sees only tags the crawler has stored, so pages crawled before ADR 0074 are judged by their domain alone. A tag nobody listed is not seen; the file is meant to be extended. Tag-based hiding is a filter, not a guarantee. It costs one indexed lookup of a page's tags per candidate while safe search is on.
