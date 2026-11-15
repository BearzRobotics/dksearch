# Feeds connector fixtures

Invented feeds; no text is copied from any real site.

- `rss.xml`: RSS 2.0 with CDATA descriptions, `content:encoded`, categories, `dc:creator`, an entry with no body (the title becomes the text) and an entry with neither id nor link (refused).
- `atom.xml`: Atom 1.0 in French, with `link rel=alternate` and `enclosure`, HTML-escaped, XHTML and plain-text content, a feed-level author and UTC offsets.
