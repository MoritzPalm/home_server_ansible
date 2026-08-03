# ADR-0002: Plex is exposed directly, outside Traefik

- **Status:** Accepted
- **Date:** 2026-07-30

## Context

Every other public service is proxied by Traefik and, where possible, gated by
Authentik. Plex is the exception: it is the single inbound port on the host
(TCP 32401 -> container 32400).

Plex terminates its own TLS using a `*.<hash>.plex.direct` certificate issued
by plex.tv, negotiates remote access through plex.tv, and is widely documented
as fragile behind reverse proxies (WebSockets, header rewriting and the relay
handshake all break in different ways).

## Decision

Plex keeps its own forwarded port and is not proxied. Its discovery and
companion ports (1900/udp, 3005, 8324, 32469, 32410-32414/udp) are bound to the
LAN address only and are not forwarded.

Because it cannot be gated at the edge, the hardening is applied to the
container and the application instead: `cap_drop: ALL` with only the five
capabilities its entrypoint needs to drop privileges, `no-new-privileges`, an
isolated data layer for Immich (ADR-0001 network split), Plex's own
`Secure connections = Required`, and an empty "allowed without auth" network
list.

## Alternatives rejected

- **Put Plex behind Traefik.** It cannot gain SSO regardless — TVs, Rokus and
  the mobile apps cannot pass a forward-auth challenge — so the only gain would
  be CrowdSec and rate limiting. The usual fix for the resulting certificate
  mismatch is setting `Secure connections = Preferred`, which *downgrades*
  security by making TLS optional. Net negative.
- **Tailscale-only Plex.** Kills TV and streaming-stick clients, which cannot
  run Tailscale.
- **Plex Relay only.** Capped around 2 Mbps / 720p; not a usable substitute for
  direct play.

## Consequences

- Plex's open port is the entire attack surface for that service. CrowdSec
  cannot see it, because CrowdSec parses Traefik's access log and Plex traffic
  never reaches Traefik. A fail2ban jail on the Plex log is the only intrusion
  detection available on that path.
- Patch latency matters more here than anywhere else. The `update/review`
  Renovate tier means a Plex update only lands when someone notices the
  dashboard *and* re-runs the playbook — acceptable for a Tailscale-only
  service, questionable for an internet-facing one. **Open question.**
- UPnP must stay disabled on the router, or Plex will punch its own holes and
  quietly undo the minimal firewall ruleset.
