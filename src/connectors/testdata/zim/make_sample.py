#!/usr/bin/env python3
"""Builds sample.zim: a tiny valid ZIM (format 5.0) with invented content.

Three clusters: 0 is xz-compressed, 1 uncompressed, 2 zstd (a hand-made frame
of raw blocks, which every zstd decoder must accept). Entries: three HTML
articles, a plain-text page, a PNG, a redirect and metadata.
"""
import struct, lzma, sys, hashlib

def zstd_raw_frame(data: bytes) -> bytes:
    assert 256 <= len(data) <= 65791 or len(data) < 256
    out = b"\x28\xb5\x2f\xfd"
    if len(data) < 256:
        out += bytes([0x20, len(data)])           # single segment, 1-byte content size
    else:
        out += bytes([0x60]) + struct.pack("<H", len(data) - 256)
    # one raw block, last
    out += struct.pack("<I", (len(data) << 3) | 1)[:3] + data
    return out

def cluster_blob(blobs, compression):
    n = len(blobs)
    offs = []
    pos = 4 * (n + 1)
    for b in blobs:
        offs.append(pos); pos += len(b)
    offs.append(pos)
    raw = b"".join(struct.pack("<I", o) for o in offs) + b"".join(blobs)
    if compression == 1:
        return bytes([1]) + raw
    if compression == 4:
        return bytes([4]) + lzma.compress(raw, format=lzma.FORMAT_XZ)
    if compression == 5:
        return bytes([5]) + zstd_raw_frame(raw)
    raise ValueError

mimes = ["text/html", "text/plain", "image/png"]
html = lambda t, body: ("<!DOCTYPE html><html><head><title>%s</title><style>p{}</style><script>var x='ignored';</script></head><body>%s</body></html>" % (t, body)).encode()
art = {
    "Lighthouse": html("Lighthouse", "<h1>Lighthouse</h1><p>A lighthouse is a tower with a bright lamp that guides ships. Keepers once trimmed the wick &amp; polished the lens.</p>"),
    "Harbour": html("Harbour", "<p>A harbour shelters boats from the sea. Fishing vessels unload cod here at dawn.</p>"),
    "Zeppelin": html("Zeppelin", "<p>The zeppelin was a rigid airship. Café menus aboard offered coffee.</p>"),
}
plain = b"Plain notes about tides and moon phases. Spring tides follow the new moon."
png = b"\x89PNG\r\n\x1a\n" + b"not really an image"

# (ns, url, title, mime, cluster, blob) content entries; redirects separately
content = [
    ("C", "Lighthouse", "Lighthouse", 0, 0, 0, art["Lighthouse"]),
    ("C", "Harbour", "", 0, 0, 1, art["Harbour"]),               # empty title: the URL stands in
    ("C", "Zeppelin", "Zeppelin (airship)", 0, 0, 2, art["Zeppelin"]),
    ("C", "notes.txt", "Tide notes", 1, 1, 0, plain),
    ("C", "logo.png", "Logo", 2, 1, 1, png),
    ("M", "Title", "", 1, 2, 0, b"Sample Sea Library"),
    ("M", "Language", "", 1, 2, 1, b"eng"),
    ("M", "Name", "", 1, 2, 2, b"sample_sea"),
]
redirects = [("C", "Light", "Light", ("C", "Lighthouse"))]

clusters_blobs = {0: [], 1: [], 2: []}
for ns, url, title, mime, cl, blob, data in content:
    assert len(clusters_blobs[cl]) == blob, (url, cl, blob)
    clusters_blobs[cl].append(data)
comp = {0: 4, 1: 1, 2: 5}
cluster_bytes = [cluster_blob(clusters_blobs[i], comp[i]) for i in range(3)]

# directory entries, sorted by namespace then url
rows = []
for ns, url, title, mime, cl, blob, data in content:
    rows.append((ns, url, ("content", mime, cl, blob, title)))
for ns, url, title, target in redirects:
    rows.append((ns, url, ("redirect", target, title)))
rows.sort(key=lambda r: (r[0], r[1]))
index_of = {(r[0], r[1]): i for i, r in enumerate(rows)}

def dirent(row):
    ns, url, info = row
    if info[0] == "content":
        _, mime, cl, blob, title = info
        return struct.pack("<HBBIII", mime, 0, ord(ns), 0, cl, blob) + url.encode() + b"\0" + title.encode() + b"\0"
    _, target, title = info
    return struct.pack("<HBBII", 0xFFFF, 0, ord(ns), 0, index_of[target]) + url.encode() + b"\0" + title.encode() + b"\0"

dirents = [dirent(r) for r in rows]
mime_list = b"".join(m.encode() + b"\0" for m in mimes) + b"\0"

HEADER = 80
mime_pos = HEADER
url_ptr_pos = mime_pos + len(mime_list)
title_ptr_pos = url_ptr_pos + 8 * len(rows)
cluster_ptr_pos = title_ptr_pos + 4 * len(rows)
dir_pos = cluster_ptr_pos + 8 * len(cluster_bytes)
ent_off = []
p = dir_pos
for d in dirents:
    ent_off.append(p); p += len(d)
clusters_pos = p
cl_off = []
for cb in cluster_bytes:
    cl_off.append(p); p += len(cb)
checksum_pos = p

header = struct.pack("<IHH16sIIQQQQIIQ",
    0x044D495A, 5, 0, b"sample-zim-0001!"[:16], len(rows), len(cluster_bytes),
    url_ptr_pos, title_ptr_pos, cluster_ptr_pos, mime_pos, 0, 0xFFFFFFFF, checksum_pos)
assert len(header) == HEADER, len(header)
body = header + mime_list
body += b"".join(struct.pack("<Q", o) for o in ent_off)
body += b"".join(struct.pack("<I", i) for i in range(len(rows)))
body += b"".join(struct.pack("<Q", o) for o in cl_off)
body += b"".join(dirents) + b"".join(cluster_bytes)
body += hashlib.md5(body).digest()
sys.stdout.buffer.write(body)
