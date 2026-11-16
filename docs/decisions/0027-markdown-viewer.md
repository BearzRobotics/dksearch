# 0027: Showing documents: md-zig and an allow-list sanitizer

Status: implemented for Markdown; ZIM articles follow.

## Context

The viewer (`/doc/<id>`) showed only flat text. Markdown sources (notes, the project's own docs, the output of Docling and MinerU) read badly that way. Showing HTML from outside, even HTML produced from Markdown (which may contain raw HTML) or taken from a ZIM file, on a page of our own is the classic way to get script injected, so the rule is that nothing from a document reaches the page unless it passed an allow-list.

## Decision

- Vendor `md-zig` 0.6.0 (the maintainer's own CommonMark and GFM library; all 652 CommonMark examples pass) under `vendor/md-zig`, revision in `VENDORED_REVISION`, as a path dependency imported as `mdzig`.
- `src/htmlsafe.zig` is a linear-time allow-list sanitizer: known formatting tags only; no scripts, styles, frames, objects, forms, SVG or MathML; no `class` or `style` attributes (they could restyle or overlay the page), no event handlers; links only to `http`, `https` and `mailto` (entities and tabs inside a scheme are decoded first, so `jav&#x09;ascript:` is seen as what a browser would see); images only from an address the caller approves (an image whose address is refused leaves its alt text); output is balanced and cannot close the surrounding page; depth and output size are bounded. A caller-supplied hook rewrites or refuses each address and cannot smuggle a script scheme back in.
- `src/render.zig` renders Markdown through `md-zig` and then the sanitizer. Links to other sites stay; links relative to the file and all images are dropped (the page's CSP only allows images from this server, and a relative address means nothing in the viewer).
- The viewer shows Markdown formatted, with a link to the plain text, and the plain view links back.
- The page's content security policy is unchanged (`default-src 'none'`, no inline script), so a sanitizer mistake would still not run script.

## Alternatives

- Render in the browser with a JavaScript Markdown library: rejected, the public pages work without script (see the roadmap).
- Trust `md-zig`'s own output: its raw-HTML pass-through is correct for CommonMark but unsafe for untrusted files; the sanitizer is the safety layer.

## Consequences

- One more vendored library; about 0.6 MB of source.
- Markdown that needs images or relative links shows without them.

## References

- CommonMark 0.31.2, https://spec.commonmark.org/0.31.2/ ; OWASP XSS prevention rules for HTML contexts.
