# 0060: Optional rendering of script-built pages with an external program

Status: accepted

## Context

A growing number of sites send an empty page and build the text with JavaScript. A crawler that does not run scripts indexes nothing of them. Running a browser inside dksearch would add a very large dependency and a very large attack surface to a program that otherwise reads text.

## Decision

- An external program does the rendering, as for PDFs and media: `render_command` (an absolute path) is run with `render_args` and the address (no shell) and prints the page's HTML on standard output, the way `chromium --headless --dump-dom URL` does. dksearch reads that output as the page.
- It is used only for the sites listed in `render_hosts`, and only when both options are set. Nothing is rendered otherwise.
- It is bounded: `render_timeout_seconds` per page (the program is killed), the output cut at `max_page_bytes`, `render_max_pages` pages per run (the rest are fetched plainly).
- The polite rules come first: robots.txt, the delay and the backoff apply to a page before it is rendered.
- It is never a way round a block. A rendered page that is a bot check or an access block (known markers such as "Just a moment...", `cf-chl-`, "Verify you are human") is reported as blocked (403) and skipped.

## Consequences

The program runs the scripts of the sites listed and loads what they request; that includes addresses on the owner's own network. It is the owner's choice, for sites they trust, with a sandboxed or containerised browser recommended (the manual says so). The address a browser ends at after redirects is not known, so the page is taken to be the address asked for. Rendering is slow (seconds a page), hence the caps.
