# A public dksearch on a small server

This is how to run `dksearch.org` (or any public instance) on a small virtual server, for example a DigitalOcean
droplet, while your home machine keeps everything private. The public instance holds only what is **crawled from the
web**. Your own folders, books, pictures, ZIM files, RAG and the document server stay at home.

What you end up with:

| | Home machine (the lab) | Public server |
| --- | --- | --- |
| Sources | files, books, pictures, ZIM, crawl | the crawl (and a copy of it) only |
| Who can use it | you | everyone sees the **web** collection; you, signed in with a key, see everything it has |
| Originals of files | `serve_originals` as you like | never (the file sources do not exist there) |
| Administration | on the machine | on the machine, through an SSH tunnel |

## 1. The server

A droplet with 2 GB of memory and 50 GB of disk is a comfortable start for a crawl of a few thousand sites (the
blocklists take about 160 MB, the index and content files grow with the crawl). Ubuntu 24.04 LTS, a non-root user with
`sudo`, SSH keys only, and the firewall allowing only 22, 80 and 443:

```
sudo ufw allow OpenSSH
sudo ufw allow 80,443/tcp
sudo ufw enable
```

Do not open 8080 or 8081: the proxy and an SSH tunnel are the only ways in.

## 2. dksearch

Install it as in [README.md](README.md) (the binary in `/usr/local/bin`, the `dksearch` user, `dksearch.service`).
Copy [public.toml.example](public.toml.example) to `/etc/dksearch/dksearch.toml` and adjust the names. Check it before
starting anything:

```
dksearch check-config /etc/dksearch/dksearch.toml
```

Copy over from home the files the crawl needs: `links.toml` (the seeds), `ban.toml` and `safesearch.toml`.

## 3. HTTPS with Caddy

dksearch does not do TLS. Caddy gets and renews the certificate by itself once `dksearch.org` points at the server
(an `A` record, and an `AAAA` record if the server has IPv6):

```
sudo apt install caddy
```

`/etc/caddy/Caddyfile`:

```
dksearch.org {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
    }
}
```

`sudo systemctl reload caddy`. Only the search listener is proxied; the administration interface is not.

## 4. Who sees what: public and "everything"

The configuration gives visitors the **web** collection only (`[access] anonymous_collections = ["web"]`). To see
everything the server holds, make a key and sign in with it:

```
dksearch api-key add me --all --config /etc/dksearch/dksearch.toml
```

It prints the key once (`dkk_...`). Open `https://dksearch.org/login`, paste it, and that browser has the key's view
for 30 days (a cookie; **Sign out** in the side panel of the search page ends it). A key made with `--adult` also skips
safe search. Removing the key (`dksearch api-key remove me`) ends every browser signed in with it.

On this server the web collection is all there is, so the key matters little. It is the same mechanism you will use on
the home server later, where the public sees the web collection and you, signed in, see the books, ZIM files and RAG too.
(See [home-server/README.md](home-server/README.md).)

## 5. Safe search and the PIN

Visitors get safe search by default: the domains in `safesearch.toml` are hidden. To let yourself see them without a key,
set a PIN with `dksearch safesearch-pin --config /etc/dksearch/dksearch.toml`; the search page then shows a PIN field
next to Filters. A domain in `ban.toml`, or on a Block List Project list that is switched on, is hidden from everyone,
the PIN and keys included.

You decide what a public server hosts. Adult sites are crawled and indexed like any other, hidden by safe search; check
your provider's acceptable-use terms before you put them on a public server, and leave out the `Adult` section of
`links.toml` on the public server if you prefer: `seeds_skip = "Tor, Adult"`.

## 6. Getting the first crawl there without waiting

A crawl of thousands of sites takes days, and a datacenter address is treated more strictly by some sites than a home
one. Make the crawl at home and copy it:

```
# at home: the documents of the crawl sources, with their texts, in one file (banned domains are left out)
dksearch export --config all.toml --source curated --source curated-adult --source curated-tor \
    --out web.dksearch.jsonl
zstd -T0 web.dksearch.jsonl                  # optional: the file is large text, it compresses well
rsync -avP web.dksearch.jsonl.zst you@dksearch.org:/var/lib/dksearch/seed/
```

```
# on the server
sudo chown -R dksearch:dksearch /var/lib/dksearch/seed
sudo -u dksearch dksearch import --config /etc/dksearch/dksearch.toml seed
```

`dksearch export` reads the index while the server runs. The file is written under a `.part` name and renamed when
finished. A `dump` source with `format = "export"` reads `.dksearch.jsonl` and `.dksearch.jsonl.zst` files; pages are
named by their address, so importing a newer export later updates the same pages instead of duplicating them.
Pictures found on pages travel too (they are small records, not the pictures). `.onion` pages come across as well, if
you export `curated-tor`: they are shown only if the server's ban list is loaded, which the configuration insists on.
Addresses of local files (`file://...`) are dropped on import: nothing of your own folders can come up as a web page.

Re-run the export and import whenever you want the public copy refreshed. The crawl on the server (`curated`, weekly)
then keeps pages current from there.

## 7. Keeping it running

* `systemctl enable --now dksearch` runs the search; [dksearch-import@.service](dksearch-import@.service) runs a crawl
  (`systemctl start dksearch-import@curated`); schedule it with a timer, or leave the source's `schedule = "weekly"`.
* [dksearch-backup.service](dksearch-backup.service) and its timer make daily snapshots.
* Update by replacing the binary and `systemctl restart dksearch`. Read the release notes for anything that needs
  `dksearch rebuild`.
* `access_log` is off by default and queries are never logged. If you turn the proxy's log on, that is your choice and
  your retention to manage.

## What not to put on this server

* A `files`, `zim`, `gutenberg` or `dump` source that points at your own material, and `serve_originals = true` on
  any source. They would let the public open your files. `public_mode = true` makes dksearch refuse to start with
  them (see the comments in `public.toml.example`).
* A `[docserver]` section.
* An administration address other than loopback.

## Limits to know about

* A hostname is checked for private addresses before the first request, but a DNS answer that changes in between
  (rebinding) is not stopped (a known limit, see the manual).
* The proxy sees visitors' addresses; dksearch itself does not rate-limit visitors. If the site is abused, add
  rate limiting in Caddy (the `rate_limit` module) or `ufw limit`, and put heavy regex searches behind a key.
