# ADR-0001: Cloudflare Tunnel is the only ingress

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

Public services need to be reachable from the internet. The host sits behind a
Fritz!Box on a residential connection with a **dynamic** IPv4 (observed changing
three times unannounced during this work: 130.185.16.42 -> 80.209.194.169 ->
80.209.192.145) and an IPv6 prefix that rotates roughly every 16 minutes.

The original plan was a hybrid: a Cloudflare Tunnel for low-bandwidth apps, plus
a directly forwarded :443 for Immich alone, because Cloudflare's free plan caps
proxied request bodies at 100 MB and Immich appears to upload whole files in one
request (its own reverse-proxy docs recommend `client_max_body_size 50000M`,
which only makes sense for unchunked uploads).

That hybrid was then questioned: does the 100 MB cap actually matter? It only
matters for individual files above 100 MB, and this library contains almost no
videos that large.

## Decision

Everything public goes through the outbound-only Cloudflare Tunnel. **No
inbound port is forwarded for HTTP at all.** Immich included.

Files above 100 MB are uploaded over Tailscale instead — Immich stays published
on the tailnet at `${HOST_IP}:2283` precisely as that escape hatch.

## Alternatives rejected

- **Hybrid tunnel + direct :443 for Immich.** Costs a permanently open port,
  loses Cloudflare's WAF and IP hiding for that hostname, and requires DDNS to
  chase a rotating address — all to serve a file size that barely occurs here.
- **Direct :443 for everything, no tunnel.** Same downsides, applied to every
  service, and exposes the origin IP in public DNS.
- **Tailscale for everyone.** Most secure, but every family member must install
  and maintain a VPN client, and it cannot serve a browser link to someone
  casually.

## Consequences

- Uploads over 100 MB fail through the tunnel. The failure is a *rejected
  upload*, not data loss, and the Tailscale path still works.
- Cloudflare is now a hard dependency for all public access. If Cloudflare's
  edge is degraded, the services are unreachable from outside — this already
  happened once during setup, when api.cloudflare.com returned 521/523 from the
  Munich PoP for about an hour.
- The DDNS container was removed: with no A/AAAA record to maintain, it had
  nothing to do, and it held a DNS-edit token permanently.
- `traefik`'s `websecure` entrypoint remains published, but bound to the LAN
  and tailnet addresses only. It serves internal `*.int` hostnames.
- **Revisit if:** the photo library starts accumulating large videos, or
  Cloudflare's body limit changes. Reversing this means putting Immich's router
  back on `websecure`, re-adding 443 to `wan_allowed_container_ports`, and
  restoring DDNS.
