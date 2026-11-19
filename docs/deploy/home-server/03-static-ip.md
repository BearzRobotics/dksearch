# 3. A static IP

Traffic goes: **visitor → dksearch.org → your fixed address → your router (ports 80 and 443) → the home machine**, where
Caddy ends HTTPS. It is the same as [dynamic DNS](02-dynamic-dns.md), without the updater: the address never changes, so
the DNS record is made once.

## 1. Get the address

* Ask your ISP for a **static IPv4 address** (often a business plan or an add-on). Ask whether inbound ports 80 and 443
  are open, whether the plan allows servers, and whether you get a block (`/29`, `/28`) or one address. One is enough.
* If your ISP cannot, a **dedicated server or a colocation slot** in a data centre gives you a fixed address, power and
  a real uplink; you put the same machine there instead of at home. That is the "physical box" in a place built for it, and
  worth pricing against the ISP's fee, a UPS and your upload speed.
* **IPv6:** many ISPs give a stable prefix. A `AAAA` record for the machine's global address works as well, if inbound
  traffic is allowed (check the router's IPv6 firewall).

## 2. DNS, once

At the registrar, or wherever the name's DNS lives: an `A` record `dksearch.org` → the static address (and `AAAA` for IPv6).
A TTL of an hour is fine. `www` as a `CNAME` to `dksearch.org` if you want it.

## 3. The router and the machine

* A DHCP reservation (or a fixed LAN address) for the home machine.
* Forward TCP 80 and 443 to it. Do **not** forward 8080 or 8081.
* Better: put the machine in a **separate network** (a VLAN or the router's DMZ/guest network, with a rule allowing it to
  reach the internet and nothing on your LAN). A web server on your home network is the first thing an attacker would
  use to reach your other machines; a separate network makes it only a web server.
* `sudo ufw allow OpenSSH && sudo ufw allow 80,443/tcp && sudo ufw enable`.

## 4. Caddy and dksearch on the home machine

As in [guide 2](02-dynamic-dns.md#4-caddy-and-dksearch-on-the-home-machine): Caddy proxies `dksearch.org` to
`127.0.0.1:8080`, dksearch has `cookie_secure = true`, and the administration interface stays on `127.0.0.1:8081` (reach it
with an SSH tunnel). Caddy gets the Let's Encrypt certificate over port 80 and renews it.

## 5. Check it

From a phone off your Wi-Fi: `https://dksearch.org/`, a search, `/login`. Then `sudo ss -tlnp` on the machine: only
22, 80, 443 on the outside, 8080 and 8081 on `127.0.0.1`.

## What to know

* The address is **public and permanent**: anyone can see where `dksearch.org` lives, and scanners will find it. Keep the
  machine updated, open nothing else, and watch `journalctl -u caddy` and `-u dksearch`.
* **Bursts of traffic** hit your line; and a denial of service against a fixed address is easy to aim. If that happens,
  a proxy in front (Cloudflare, or your own droplet as in [guide 1](01-droplet-front-door-wireguard.md), which can be
  added later without changing anything on the machine but its listening address) takes the load. A third-party proxy
  sees the traffic in the clear: decide that on purpose.
* **Power and uptime** are yours: a UPS, a machine that boots by itself after a cut, and a way in (the ISP's router, or
  SSH from the droplet if you have one) when it does not.
* **Moving or changing ISP** changes the address: change the one DNS record, with the TTL lowered a day before.
* **Terms of service:** a residential plan may forbid servers. A business plan usually allows them.
