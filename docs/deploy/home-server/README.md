# Putting dksearch.org on your own server at home

The plan: a physical machine at home holds everything (ZIM files, your books, RAG, pictures, the crawl), and
`dksearch.org` points at it. Visitors see the public part (the **web** collection); you, signed in with a key, see all of
it. The question is how traffic from the internet reaches a machine in your house. There are three ways. Each has its own
guide, written so that you can choose when you get there:

| | [1. A droplet as the front door (WireGuard)](01-droplet-front-door-wireguard.md) | [2. Dynamic DNS](02-dynamic-dns.md) | [3. A static IP](03-static-ip.md) |
| --- | --- | --- | --- |
| Needs from your ISP | nothing: works behind CGNAT, with any connection that can reach the internet | a public IPv4 or IPv6 address (not CGNAT) and inbound ports 80 and 443 not blocked | a static address (usually a paid option) and inbound ports allowed |
| Ports opened at home | none | 80 and 443 | 80 and 443 |
| Your home address is | hidden (visitors see the droplet) | public (it is the DNS record) | public (fixed) |
| Where HTTPS ends | on the droplet | on the home machine | on the home machine |
| Costs | the smallest droplet each month | a DNS host with an API (often free) | the ISP's static-IP fee |
| If the home machine is off | the droplet can serve its own crawl-only copy | the site is down | the site is down |
| Moving house or changing ISP | change the tunnel's endpoint once | the updater follows | new address, change one DNS record |
| Complexity | most (two machines, a tunnel) | least | least, once you have the address |
| Main risk | the droplet is one more machine to keep updated | your home address is public, and bursts of traffic hit your home line | the same, and it never changes |

**What I would pick:** the first, because it needs nothing from your ISP, hides your address, and you already planned to
have the droplet. Use dynamic DNS or a static address if you would rather have one machine and no tunnel, and your
connection allows it. All three end with the same dksearch configuration on the home machine, below.

## The same configuration on the home machine, whichever way you choose

One instance serves two audiences. Everyone sees the **web** collection; a browser signed in with your key sees all.

```toml
[server]
address = "127.0.0.1"           # or the tunnel address, see guide 1
port = 8080

[admin]
address = "127.0.0.1"           # never anything else; reach it with an SSH tunnel
port = 8081

[access]
anonymous_collections = ["web"] # what visitors may search
cookie_secure = true            # the browser reaches the site over HTTPS

[[collection]]
name = "web"
description = "The crawled web"
sources = ["curated", "curated-adult"]

[[collection]]
name = "library"
description = "ZIM files, books and notes"
sources = ["knots", "chemistry", "folklore", "docs"]

[safe_search]
enabled = true                  # visitors get safe search; the PIN or an adult key lifts it
list = "safesearch.toml"
```

Then:

```
dksearch api-key add me --all           # the key that sees everything; shown once
dksearch safesearch-pin                 # the PIN that lifts safe search in a browser
```

Open `https://dksearch.org/login`, paste the key: that browser sees the library, the ZIM articles, the originals and the
RAG answers as well. Visitors and anyone not signed in get the **web** collection only. A document outside someone's
collections is answered as if it did not exist: in results, in the viewer, in the original file and in the pictures.

`public_mode = true` under `[server]` makes dksearch refuse to start if the configuration would give the public more than
intended: `[access] anonymous_collections` missing, a source the public can search with `serve_originals = true`, or an
administration address that is not loopback. Turn it on once the configuration is as you want it.

## Before you point the name at it, whichever way

* **Sign in works only over HTTPS** (the cookie is `Secure`). Test `/login` from outside your network.
* **The administration interface** stays on `127.0.0.1`. Use `ssh -L 8081:127.0.0.1:8081 you@home` (through the droplet
  or the name) when you need it.
* **Regular expressions and RAG answers** run code on every query. The regex filter is bounded by `[search]` limits; the
  local answer model (`[answers]`) is off for visitors unless their collections allow it, and it is slow and costly on a
  CPU: leave answers to signed-in use, or off.
* **Updates and backups:** a `dksearch-backup.timer` snapshot to another disk, and the machine's own updates. A box that
  is on the internet needs `unattended-upgrades` (or your routine) and a firewall that allows only what the guide says.
* **Power and heat:** a UPS and a fan you trust. A search engine that is down when you need it is the usual failure.
* **Your provider's terms:** many residential plans forbid running servers; read yours before you rely on it (the droplet
  way makes this question smaller: the traffic to your house is one encrypted tunnel).
* **Illegal or unwanted content:** the crawl will reach pages you would not choose. The ban lists, safe search and the
  Block List Project switches (administration, Safe search) are your tools; review what you index before it is public.
