# 1. A droplet as the front door (WireGuard)

Traffic goes: **visitor → dksearch.org (the droplet's address) → Caddy on the droplet (HTTPS) → a WireGuard tunnel →
dksearch on your home machine**. The home machine opens no ports: it dials the tunnel out to the droplet, and keeps it
alive. This works behind CGNAT, hides your home address, and survives your home address changing.

```
 visitor ──HTTPS──▶ droplet (public IP, Caddy)
                        │  WireGuard (UDP 51820)
                        ▼
                    home machine (10.8.0.2): dksearch on 10.8.0.2:8080
```

## What you need

* A droplet (the smallest is enough: it only forwards). Ubuntu 24.04. The name `dksearch.org` pointing at it (`A`, and
  `AAAA` if it has IPv6).
* The home machine with a connection that can reach the droplet on UDP 51820 (nearly any can).
* Tunnel addresses: `10.8.0.1` for the droplet, `10.8.0.2` for home (pick another range if `10.8.0.0/24` is in use).

## 1. WireGuard keys (on each machine)

```
sudo apt install wireguard
umask 077
wg genkey | tee private.key | wg pubkey > public.key
```

Keep each `private.key` on its own machine only. Copy the **public** keys across.

## 2. The droplet: `/etc/wireguard/wg0.conf`

```
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <the droplet's private key>

[Peer]
# the home machine
PublicKey = <the home machine's public key>
AllowedIPs = 10.8.0.2/32
```

```
sudo ufw allow 51820/udp
sudo systemctl enable --now wg-quick@wg0
```

`AllowedIPs = 10.8.0.2/32` means the droplet only accepts traffic from the home machine's tunnel address, and sends
only that address through the tunnel.

## 3. The home machine: `/etc/wireguard/wg0.conf`

```
[Interface]
Address = 10.8.0.2/24
PrivateKey = <the home machine's private key>

[Peer]
# the droplet
PublicKey = <the droplet's public key>
Endpoint = <the droplet's public IP>:51820
AllowedIPs = 10.8.0.1/32
PersistentKeepalive = 25
```

```
sudo systemctl enable --now wg-quick@wg0
sudo wg show           # "latest handshake" should be a few seconds ago
ping -c1 10.8.0.1
```

`PersistentKeepalive = 25` keeps the tunnel open through your router's NAT. Only the droplet's address goes through the
tunnel (`AllowedIPs = 10.8.0.1/32`): the rest of the home machine's traffic does not.

## 4. dksearch at home listens on the tunnel address

In its configuration (see [README.md](README.md) for the rest):

```toml
[server]
address = "10.8.0.2"       # only the tunnel: the home network cannot reach it, the droplet can
port = 8080
[access]
cookie_secure = true
```

Allow only the droplet to reach it, at the home machine's firewall:

```
sudo ufw allow in on wg0 from 10.8.0.1 to any port 8080 proto tcp
```

The administration interface stays on `127.0.0.1:8081`.

## 5. The droplet: Caddy

```
sudo apt install caddy
```

`/etc/caddy/Caddyfile`:

```
dksearch.org {
    encode zstd gzip
    reverse_proxy 10.8.0.2:8080
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
    }
}
```

`sudo systemctl reload caddy`, and `https://dksearch.org/` shows your home search. Sign in at `/login`.

## 6. Optional: the droplet answers when home is off

If the droplet also runs its own crawl-only dksearch (see [../public-instance.md](../public-instance.md)) on
`127.0.0.1:8080`, Caddy can send visitors there whenever the home machine is down:

```
dksearch.org {
    encode zstd gzip
    reverse_proxy 10.8.0.2:8080 127.0.0.1:8080 {
        lb_policy first            # the home machine while it is healthy, the droplet's copy otherwise
        health_uri /api/v1/health
        health_interval 10s
        health_timeout 3s
        fail_duration 30s
    }
}
```

While the droplet's copy answers, visitors see only the web collection (its crawl, refreshed with
`dksearch export`/`import` as often as you like), and your own key does not work there: keys belong to an instance.
Sign-in comes back when home does.

## 7. Check it, and keep it healthy

* From a phone off your Wi-Fi: `https://dksearch.org/`, a search, `/login`, then a search that only the library answers.
* `sudo wg show` on both sides. A handshake older than a few minutes means the tunnel is down: the home machine could
  not reach `<droplet>:51820` (a firewall, or the droplet's address changed).
* The droplet is a machine to keep updated (`unattended-upgrades`), with SSH keys only and `ufw` allowing 22, 80, 443 and
  51820/udp.
* What an attacker who owns the droplet gets: the ability to read what visitors send (the proxy sees it in clear) and to
  reach port 8080 of your home machine over the tunnel, which is the public search anyway. Not your files, the
  administration interface, or other ports. That is why the tunnel allows one address and the home firewall one port.

## Costs and limits

* The smallest droplet each month, and its bandwidth allowance (pictures shown through the relay and ZIM articles count).
* Speed is your home upload speed. A 20 Mbit/s uplink is plenty for text, noticeable for pictures.
* One extra moving part. Keep the keys and the two configuration files in your backups.
