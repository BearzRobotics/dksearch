# Wikipedia connector fixtures

Invented articles in the MediaWiki export format; no text is copied from Wikipedia.

- `dump.xml`: the whole dump, uncompressed.
- `dump.xml.bz2`: the same, as three bzip2 streams back to back (a "multistream" dump):
  stream 1 = header + pages 101, 102; stream 2 = pages 103, 104; stream 3 = page 105 + closing tag.
  Made with `bzip2 -c -9` on each part and concatenated.

Pages: 101 article (templates, refs, links, table, references section); 102 redirect;
103 talk page (namespace 1); 104 article with entities; 105 article with non-ASCII title.
