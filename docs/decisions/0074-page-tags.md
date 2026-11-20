# 0074: The tags of a page are indexed

Status: accepted

## Context

Tags (the words a site or its authors attach to a page, a picture or a video) say what a page is about better than its text does, and image boards, galleries, blogs and video sites are made of them. The crawler kept only the visible text, and not all of that: links and spans that follow one another (`<a>digital art</a><a>artwork</a>`, the usual markup of a tag list) were glued into one word, "digital artartwork", so the tags that were on the page could not be searched one by one. Nothing else the page says about itself was read: no keywords, no description, no `data-tags`, no JSON-LD, no hashtags.

## Decision

- **Words are not glued:** a link or span that opens directly after another has closed starts a new word (`htmltext.toText`). One that opens after text does not (`a<span>b</span>c` stays "abc"), and emphasis never breaks a word.
- **Where tags come from** (`htmltext.scanWith`, `withHashtags`): the keywords metas (`keywords`, `news_keywords`, `parsely-tags`), `article:tag`, `og:video:tag`, `video:tag`; links marked `rel="tag"`; `data-tags` and `data-tag-name` attributes (image boards write a post's tags there); the `keywords` of a JSON-LD block; and the hashtags of the text (`#Linux`; camel case such as `#DigitalArt` also as "digital art"). A hashtag is not one inside a word (`C#`, `page.html#top`), a colour (`#fff`), a number, or a preprocessor word (`#include`).
- **Normalised and bounded:** lower case, underscores as spaces (`long_hair` is "long hair"), no empty or punctuation-only tags, at most 100 tags of 60 characters a page, JSON-LD blocks up to 128 KB, a description of at most 600 characters (`description`, `og:description`, JSON-LD).
- **Kept two ways** (`crawl.zig`): the page's text gets `Description: ...` (unless the text already says it) and `Tags: a, b, c` lines, so the words are found by an ordinary search; and each tag is a `tag` of the document, which the existing `tag:` search finds exactly. A picture keeps the tags of its own `data-tags` the same way. A page with nothing to read but its description and tags is indexed.

## Consequences

A search for `artwork` finds a page tagged "artwork" even if its text never says it, and `tag:nature` lists the pages tagged that. Pages stored before this have neither the separated words nor the tags: the crawler asks for pages with the validators it saved and skips those unchanged, so a recrawl that is to add tags starts from empty validators. The video itself is still not read: its tags, title and description (metas, JSON-LD) are. Hashtags can be noise on a page about something else; the 100-tag cap and the filters bound it.
