# Deploying dksearch

This describes a plain Linux installation with systemd. dksearch has no installer, package or container image yet (the project does not use Docker); it is one binary, one configuration file and one data directory.

## Install

For a binary with no dependencies on the system's C library, build it static: `zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl` (or `aarch64-linux-musl`). The default build links the system's C library.

    zig build -Doptimize=ReleaseSafe
    sudo install -m 0755 zig-out/bin/dksearch /usr/local/bin/dksearch
    sudo useradd --system --home-dir /var/lib/dksearch --shell /usr/sbin/nologin dksearch
    sudo install -d -o root -g dksearch -m 0750 /etc/dksearch
    sudo install -m 0640 -g dksearch docs/deploy/dksearch.toml.example /etc/dksearch/dksearch.toml
    sudo cp docs/deploy/dksearch.service 'docs/deploy/dksearch-import@.service' /etc/systemd/system/
    sudo systemctl daemon-reload

Edit `/etc/dksearch/dksearch.toml` (set `storage.data_dir = "/var/lib/dksearch"`, add your sources), check it, then start:

    sudo -u dksearch dksearch check-config /etc/dksearch/dksearch.toml
    sudo systemctl enable --now dksearch

The unit's `StateDirectory=dksearch` creates `/var/lib/dksearch` owned by the service user, mode 0700. If a source reads files outside it, uncomment `ReadOnlyPaths=` in the units and name the directory (the sandbox hides the rest of the file system from the service).

## Import data

    sudo systemctl start dksearch-import@my-notes
    journalctl -u dksearch-import@my-notes

The instance name is the source name. Imports work while the server runs, resume after an interruption, and share a lock with the other write commands, so overlapping runs are refused instead of corrupting anything. For a schedule, add a timer for the instance (`OnCalendar=...`, `Unit=dksearch-import@my-notes.service`).

## Feeds

The `feeds` connector reads feed files from disk; it does not fetch them. A simple setup downloads feeds into a directory with a timer and imports after each download:

    # /etc/systemd/system/dksearch-feeds.service  (oneshot, run by a timer)
    [Service]
    Type=oneshot
    User=dksearch
    ExecStart=/bin/sh -c 'curl -fsS --max-time 60 -o /var/lib/dksearch/feeds/example.xml https://example.org/feed.xml && /usr/local/bin/dksearch import --config /etc/dksearch/dksearch.toml news'

Fetching is your policy to set: pick a polite interval, identify yourself in the `User-Agent` only if you are comfortable doing so, and respect each site's terms. The connector indexes whatever is in the directory, so remove a file to stop indexing a feed (and `dksearch import --prune news` to drop entries whose files are gone).

## Crawling

The `crawl` connector fetches the URLs in a seeds file. It is polite by default (robots.txt, one request per second per host, your own user agent) but it is your crawler: set a `user_agent` with a way for site owners to reach you, keep `delay_ms` generous, and respect each site's terms.

    [[source]]
    name = "web"
    kind = "crawl"
    user_agent = "mysearch/1.0 (+https://example.org/about)"
    seeds_file = "/etc/dksearch/seeds.txt"

The import unit template denies all network access (`PrivateNetwork=yes`), which suits the other connectors. Give a crawl source its own instance with a drop-in that allows the network:

    sudo systemctl edit dksearch-import@web.service
    # [Service]
    # PrivateNetwork=no
    # RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

HTTPS verifies against the Mozilla roots embedded in the program, so no certificate store is needed in the sandbox. The crawler does not block addresses on private networks for the sites you list; list only hosts you mean to index.

## Administration

Create a credential as the service user so the secrets file gets the right owner and mode:

    sudo -u dksearch dksearch admin-token --config /etc/dksearch/dksearch.toml      # prints the token once
    sudo -u dksearch dksearch admin-password --config /etc/dksearch/dksearch.toml   # for browser sign-in

Then restart the service. The administration interface listens on `127.0.0.1:8081` by default. From another machine, use an SSH tunnel (`ssh -L 8081:127.0.0.1:8081 server`) or a reverse proxy with TLS. Never expose it over plain HTTP outside loopback: the token and password would cross the network in clear text.

## Reverse proxy with TLS

dksearch does not terminate TLS or rate-limit; put a reverse proxy in front for a public site. The proxy sees client addresses, so its logging and retention are yours to configure.

Caddy, public search only:

    search.example.org {
        reverse_proxy 127.0.0.1:8080
        # Never forward the administration paths: they are on another port anyway.
    }

nginx:

    server {
        listen 443 ssl;
        server_name search.example.org;
        # ssl_certificate / ssl_certificate_key ...
        location / {
            proxy_pass http://127.0.0.1:8080;
            proxy_set_header Host $host;
        }
        # Optional rate limit (defined with limit_req_zone in the http block):
        # limit_req zone=search burst=20 nodelay;
    }

If you also publish the administration interface through a proxy, restrict it by source address or add proxy-level authentication, and set `admin.cookie_secure = true`.

## Backups

    sudo install -d -o dksearch -g dksearch -m 0700 /var/backups/dksearch
    sudo cp docs/deploy/dksearch-backup.service docs/deploy/dksearch-backup.timer /etc/systemd/system/
    sudo systemctl enable --now dksearch-backup.timer

Each run writes a new directory holding `state.db` and `content.db` (the only copies of what was imported; the index is rebuilt with `dksearch rebuild`). Nothing prunes old backups: delete old directories yourself, and copy backups to another machine. To restore, stop the service, move the damaged files out of `data_dir`, run `sudo -u dksearch dksearch restore --config /etc/dksearch/dksearch.toml /var/backups/dksearch/DIRECTORY` (it verifies the backup, copies it in and rebuilds the index), and start the service. Run `dksearch check` now and then, and after a restore.

## Updating

Stop the service, install the new binary, start it. Databases are upgraded when first opened, after a copy of the old file is saved next to it (`*.pre-vN`); a file written by a newer version is refused, not changed. If a release changes the index format, the program says to run `dksearch rebuild`.

## What the units do not do

They are a starting point, not an audited profile: review them for your system. What was tested: `dksearch serve` (search and administration requests, graceful stop on SIGTERM) and `dksearch check` ran correctly under the same `NoNewPrivileges`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies`, `SystemCallFilter=@system-service` with `~@privileged @resources`, `ProtectSystem=strict` and `PrivateTmp` settings, as a transient user service (`systemd-run --user`). The full units were checked with `systemd-analyze verify` but not installed and run as a system service, and no `import` was run under `PrivateNetwork=yes`. They do not set resource limits (add `MemoryMax=` and `TasksMax=` if you want them), and `dksearch-import@.service` uses `PrivateNetwork=yes` because imports never need the network.
