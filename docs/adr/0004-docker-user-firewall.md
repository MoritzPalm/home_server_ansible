# ADR-0004: Container ingress policy lives in DOCKER-USER, not UFW

- **Status:** Accepted
- **Date:** 2026-07-30

## Context

`roles/base` enabled UFW with `policy: deny` and only `allow OpenSSH`. That
looked like a default-deny host — it was not. Docker inserts its own nat and
FORWARD rules and **bypasses UFW's INPUT chain entirely**, so every published
container port was reachable on all interfaces regardless of UFW.

An audit found ~35 ports published on `0.0.0.0`, including the whole arr stack,
Immich, Vikunja and Tandoor. Docker's `0.0.0.0` publish also binds `[::]`, so
they were exposed on the host's public IPv6 address too — the same vector the
Samba masking in `roles/base` had been added to close.

Whether they were reachable from the internet depended entirely on the
Fritz!Box's inbound IPv6 filtering. Measurement showed it was in fact blocking,
so the exposure was latent rather than live — one router setting away from real.

## Decision

Container ingress policy lives in the `DOCKER-USER` chain, managed by
`roles/firewall` for both IPv4 and IPv6, with a default DROP for the WAN
interface. Published ports are additionally bound to a specific address
(`${HOST_IP}` for tailnet-only, `${LAN_IP}` for LAN) rather than `0.0.0.0`,
which also removes the `[::]` bind.

## Alternatives rejected

- **UFW alone.** Does not apply to Docker-published ports. This was the
  pre-existing state and it did not work.
- **Bind addresses alone, no firewall.** Correct today, but one careless
  `ports:` entry re-opens everything. The DROP makes the failure mode
  closed-by-default.
- **`iptables=false` on the Docker daemon.** Means hand-managing all container
  NAT; disproportionate.

## Consequences

- Rules match **container** ports, not published ones: `DOCKER-USER` sits in
  FORWARD and sees packets after DNAT. Plex is `32400` there, not `32401`.
  Writing the published port produces a rule that looks right and never matches.
- On this host, LAN and internet traffic arrive on the **same** interface
  (it is behind NAT, there is no separate WAN NIC). The DROP is only safe
  because the `lan_subnet` RETURN precedes it. Reordering the rules cuts off
  the LAN.
- `DOCKER-USER` hangs off FORWARD, so none of this can lock out sshd or
  Tailscale, which are on INPUT. Worst case is an unreachable container.
- Docker recreates the chain on daemon restart; rules are persisted with
  `netfilter-persistent`, ordered after `docker.service`.
