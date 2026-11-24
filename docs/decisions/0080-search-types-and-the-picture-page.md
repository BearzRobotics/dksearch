# 0080. Search types, the picture page and a gallery that fills

- Status: Accepted (2026-11-21 to 2026-11-23), as asked by the owner in the working session
- Date: 2026-11-23

## Context

The Images button was one of several ways to narrow a search, and it was forgotten as soon as the box was used again. A picture's page showed buttons that repeated what the details under it said. The gallery showed a row or two when the index held plenty of pictures. Turning safe search on or off reloaded the page and dropped the search.

## Decisions

1. **Search types.** Under the box sit All, Images, Video, Docs, Sheets and Slides, small icon-and-label buttons with the chosen one marked (`type=images`, `video`, `docs`, `sheets`, `slides`; the older `images=1` is `type=images`). Enter and the pager keep the type, and so does the search box on a picture's own page. A type adds a filter: Images `kind:image`; Video `meta.type:video` (the page type a site declares, since the crawler fetches pages, not video files); Docs `ext:pdf,doc,docx,odt,rtf,epub`; Sheets `ext:xls,xlsx,ods,csv,tsv`; Slides `ext:ppt,pptx,odp,key`. `ext:` takes a comma list (up to 16 extensions); the same field twice is "either".
2. **A type with an empty box lists everything of that type**, newest first, with the pager. A filter alone was already a valid search; the page now sends it.
3. **The picture page** shows the original picture (through the relay, or from the file served by the server for local files) with the details under it: the picture file, the page it was found on, the site (a link to more pictures of it), format, size, author, language, source, dates, tags and the words of the picture. The buttons that repeated this were removed.
4. **The gallery fills the page.** It is not held to `per_domain` results a site, and it does not fold records that share a page's text. A picture shown twice is folded by the address of the picture file, the first line of its stored text (`Image: ADDRESS`), read for the forty results of a page; if the text cannot be read, by page, words and stored size. `group=0` shows every record.
5. **Safe search returns to the search.** The lock and unlock forms carry a `back` value (the current search address, accepted only if it starts with `/search?`, is at most 2,000 characters and has no control characters) and redirect to it.
6. **A result you opened changes colour** (`--visited`), in results and gallery captions; a browser lets a visited link change only its colour.

## Not done

Video files of a crawl (the crawler fetches pages; `video` finds pages that declare themselves videos, and local files of kind `video` are not matched), reading PDFs and office files in the crawler (Docs, Sheets and Slides are empty until it does), and duration and resolution on results.
