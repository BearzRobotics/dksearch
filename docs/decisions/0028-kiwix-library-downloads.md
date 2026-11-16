# 0028: Downloading ZIM files from the Kiwix library

Status: implemented.

## Context

ZIM files are the easiest way to get Wikipedia, Wiktionary, Stack Exchange sites and many books offline, but finding and fetching them by hand is awkward, and they range from a few megabytes to tens of gigabytes. The project is offline-first: the network is used only when the administrator asks.

## Decision

- `src/kiwix.zig` reads the library's OPDS catalogue (`https://library.kiwix.org/catalog/v2/entries`, an Atom feed) and a file's Metalink (`.meta4`), both with xml-zig (DTDs rejected), and downloads.
- Nothing is contacted until the administrator searches on the ZIM files page, and nothing is downloaded until they confirm a file (size and destination are shown).
- A download needs `[admin] zim_dir` (a folder the administrator names; the interface writes nowhere else) and `actions = true`. It is off otherwise.
- Only `https` addresses on `kiwix.org` are accepted for the Metalink; the mirrors named inside it may be anywhere, because the file is verified, not trusted.
- The Metalink must carry a SHA-256; without one the file is refused. The file is written to `NAME.zim.part`, hashed as it arrives, compared with the published SHA-256 and exact size, and only then renamed. A wrong checksum deletes the partial file. A file that exists is never overwritten.
- File names come from the catalogue, so they are checked: letters, digits, `.`, `-`, `_`, ending `.zim`, never a path.
- Interrupted downloads continue (HTTP Range; the part already fetched is re-hashed first). Nothing arriving for 60 seconds stops the job; cancelling stops it at once.
- The job is a `jobs` operation (`download`), one background task at a time, but it takes no writer lock because it does not touch the data files.
- The catalogue's size is rounded to KiB; the Metalink's exact size is the one verified.
- After a download the administrator adds a `zim` source for it (not automatic: choosing a name and options is theirs).

## Alternatives

- Torrent or BitTorrent downloads: more moving parts, no gain for a single file.
- Trusting the HTTPS connection alone: mirrors are third parties; the published checksum is cheap and is checked.
- Adding the source automatically: guesses names the administrator may not want.

## Consequences

- Needs the `-Dcrawler` build (it shares the HTTP client).
- Free disk space is not checked; the confirmation page says so. A full disk shows as a failed download with the part file kept.
