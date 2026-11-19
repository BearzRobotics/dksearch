# 2. Dynamic DNS

Traffic goes: **visitor → dksearch.org → your home router (ports 80 and 443 forwarded) → the home machine**, where Caddy
ends HTTPS. Your ISP changes your address from time to time, so a small program on the home machine updates the DNS
record whenever it does. One machine, no tunnel, and no droplet; but your home address is public.

## Is this possible on your connection?

1. Find the address your **router** shows as its WAN/Internet address.
2. On any machine at home, run `curl -4 https://ifconfig.me` (and `curl -6 https://ifconfig.me` for IPv6).
3. If the router's address is **the same** as `ifconfig.me` and is not in `100.64.0.0/10`, `10.0.0.0/8`,
   `172.16.0.0/12` or `192.168.0.0/16`, you have a public address: this guide works. If it differs or is in those ranges,
   you are behind CGNAT (your ISP shares one address among customers) and nothing can reach you from outside: use
   [guide 1](01-droplet-front-door-wireguard.md) or ask the ISP for a public address.
4. Some ISPs block inbound 80/443 on residential plans. Test later from a phone off your Wi-Fi.

## 1. A DNS host with an API

The registrar that sold you `dksearch.org` may or may not offer an API. Cloudflare, DigitalOcean, Porkbun, Namecheap,
Gandi and others do (the registrar can be kept: only the name servers move, if you choose to host DNS elsewhere). The
example uses Cloudflare's API; the shape is the same for the others (one `PUT` to change the record).

Make a record `dksearch.org` of type `A` (and `AAAA` for IPv6), proxy **off** (a grey cloud: DNS only), TTL 60 seconds. Make
an API token limited to editing DNS for this zone only, and note the zone id and the record ids.

## 2. The updater: `/usr/local/bin/dksearch-ddns`

```sh
#!/bin/sh
# Update the A record of dksearch.org when the home address changes.
set -eu
TOKEN=$(cat /etc/dksearch/ddns.token)          # the limited API token, mode 0600
ZONE=<zone id>
RECORD=<record id of the A record>
NAME=dksearch.org
STATE=/var/lib/dksearch-ddns.last

NOW=$(curl -fsS -4 https://ifconfig.me)
[ "$NOW" = "$(cat "$STATE" 2>/dev/null || true)" ] && exit 0

curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$RECORD" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$NOW\",\"ttl\":60,\"proxied\":false}" >/dev/null
echo "$NOW" > "$STATE"
logger -t dksearch-ddns "address is now $NOW"
```

`chmod 755` it, and run it every few minutes with a timer. `/etc/systemd/system/dksearch-ddns.service`:

```
[Unit]
Description=Update the dksearch.org address
[Service]
Type=oneshot
ExecStart=/usr/local/bin/dksearch-ddns
```

`/etc/systemd/system/dksearch-ddns.timer`:

```
[Unit]
Description=Check the home address every 5 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

`sudo systemctl enable --now dksearch-ddns.timer`. (IPv6: repeat with `-6`, type `AAAA`, a second record.)

## 3. The router

Forward TCP 80 and 443 to the home machine's **fixed LAN address** (set a DHCP reservation for it). Do not forward 8080
or 8081. If your router has "NAT loopback"/"hairpin" off, `dksearch.org` will not open from inside your own network;
add `dksearch.org` to the home machine's `/etc/hosts` for that, or use a local DNS override.

## 4. Caddy and dksearch on the home machine

```
sudo apt install caddy
sudo ufw allow 80,443/tcp && sudo ufw allow OpenSSH && sudo ufw enable
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

dksearch listens on `127.0.0.1:8080` with `cookie_secure = true` (see [README.md](README.md)). Caddy gets the certificate
from Let's Encrypt over port 80 by itself, and renews it.

## 5. Check it

From a phone off your Wi-Fi: `https://dksearch.org/`, a search, `/login`. Then change nothing and wait for your ISP to
change the address (or force it by restarting the router): the name should follow within a few minutes. Look at
`journalctl -t dksearch-ddns`.

## What to know

* **Your home address is public**, and anyone can look it up. Scanners will find ports 80 and 443 within hours. Keep the
  machine updated (`unattended-upgrades`), open nothing else, and keep the administration interface on loopback.
* **Bursts of traffic** (a crawler, an enthusiastic mention) land on your home line. Ask Caddy to limit connections if it
  happens, or move to [guide 1](01-droplet-front-door-wireguard.md) and let the droplet take the first hit.
* **Downtime** is your downtime: power, the router, the ISP. DNS with a 60 second TTL recovers fast after the address
  changes, but not while the machine is off.
* **Terms of service:** a residential plan may forbid servers. Read yours.
* Cloudflare can proxy the name (an orange cloud) to hide your address and absorb attacks. Then Cloudflare terminates
  HTTPS and sees every request and answer in the clear. For a project built to keep queries private, decide that on
  purpose.
