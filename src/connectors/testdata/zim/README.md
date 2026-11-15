Invented ZIM fixture for the zim connector tests.

`make_sample.py` writes `sample.zim` (run `python3 make_sample.py > sample.zim`): format 5.0 with three clusters (xz, uncompressed, and a hand-made zstd frame of raw blocks), three HTML articles ("Lighthouse", "Harbour" with an empty title, "Zeppelin"), a plain-text page, a PNG, a redirect ("Light" to "Lighthouse") and metadata (Title, Language, Name). No text is copied from anywhere.
