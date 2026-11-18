# 0044: Crawling Tor and I2P sites

Status: implemented for the crawler; serving as a hidden service is not built.

## Context

Sites on the Tor (`.onion`) and I2P (`.i2p`) networks are reachable only through a local proxy. The crawler uses Zig's HTTP client, which speaks to HTTP proxies but not to SOCKS5, the way Tor is normally reached.

## Decision

- **Both networks, opt-in per source**: `tor_socks` (a SOCKS5 address) and `i2p_proxy` (an HTTP proxy address), literal IP and port. Unset means the network's addresses are never contacted.
- **The proxy is the owner's**: dksearch does not start, install or configure Tor or I2P.
- **Names are never resolved here.** The SOCKS5 request carries the host as a domain name; the I2P proxy request carries the absolute address. The local resolver, and the private-address check, are skipped for these names, since there is nothing to resolve.
- **A small HTTP/1.1 client of its own** (`crawl/hidden.zig`) for these two transports: GET with identity encoding, content length, chunked bodies and a size limit; `http://` only (an onion or I2P address already authenticates and encrypts, and certificates for them are rare). Redirects are left to the crawler, which checks each hop as before.
- **Boundaries between networks**: a crawl that starts on a hidden site does not follow links to the open internet; links from ordinary sites into hidden networks are followed only with `hidden_links = true` and a proxy for that network.
- **Only version 3 onion names** are contacted (56 base32 characters, at most two subdomain labels): older and mistyped names would only cost a connection to Tor, and deep names are loops. Compared with the Ahmia crawler: it also accepts only v3 and limits subdomain depth; it ignores robots.txt and presents a browser's user agent, which this crawler does not.
- **Ban lists accept MD5 hashes** of domains (as Ahmia publishes its banned onion domains), so a published list can be used without naming the domains (ADR 0048).
- The crawler's other rules are unchanged (robots.txt, delay, user agent, limits).

## Alternatives

- An HTTP front for Tor (Privoxy): another program to install and configure.
- Sending the open-internet crawl through Tor as well: a different feature (hiding the crawler), not reaching hidden sites.
- Resolving names locally and checking them: leaks the name and cannot work.

## Consequences

- The crawler's user agent is visible to hidden sites; the manual says so.
- Hidden services are slow and often down; timeouts should be raised, and failures are counted like any network failure.
- Serving dksearch itself as an onion or I2P service is on the roadmap, not built.
