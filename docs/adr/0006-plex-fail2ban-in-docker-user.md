# ADR-0006: Plex bans go in DOCKER-USER, with ownership split between Ansible and fail2ban

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

Plex is exposed directly and does not pass through Traefik (ADR-0002), so
CrowdSec — which reads Traefik's access log — cannot see a single request to it.
The one internet-facing port on this host therefore had no intrusion detection
at all, while every proxied service had two layers of it.

`fail2ban` is already installed and running an sshd jail (`roles/base`), so the
machinery exists. Three things stood in the way of simply adding a jail:

1. **Stock fail2ban actions write to INPUT.** Docker's published ports are DNAT'd
   and traverse FORWARD, never INPUT — the same trap that made the UFW
   default-deny useless for containers (ADR-0004). A stock jail would report
   bans in `fail2ban-client status` that it was not actually enforcing, which is
   worse than no jail, because it looks like coverage.
2. **`roles/firewall` flushes and rebuilds `DOCKER-USER` on every run.** A jump
   inserted into that chain by fail2ban would be deleted by the next playbook
   run, and every subsequent ban would be a silent no-op.
3. **Plex logs no authentication-failure string** at default verbosity. The only
   auth signal it emits is the HTTP status on its request-completion lines.

## Decision

Bans are written into a dedicated `f2b-plex` chain, reached by a jump from
`DOCKER-USER`, with ownership split:

- **`roles/firewall` owns** the chain's existence and the jump, which is the
  first rule of `DOCKER-USER`.
- **fail2ban owns** only the rules inside the chain, via a custom
  `docker-user.conf` action that deliberately does not create or remove the jump.

The filter matches `401` responses, paired with a high `maxretry` and an
`ignoreip` covering every network that legitimately produces them.

## Alternatives rejected

- **Stock `iptables-allports` action.** Writes to INPUT; bans would never apply
  to a containerised service. Rejected as actively misleading.
- **Letting fail2ban manage its own jump into `DOCKER-USER`.** Removed by the
  next playbook run. The two systems would silently fight, with fail2ban losing.
- **Banning in `raw`/`PREROUTING` instead.** Works, and avoids the conflict
  entirely — but splits container ingress policy across two chains and
  contradicts ADR-0004's "one place for this". Rejected on coherence, not
  correctness; it is the fallback if the split ownership proves fragile.
- **Putting Plex behind Traefik to get CrowdSec.** Rejected in ADR-0002 and not
  reopened here.
- **Matching only explicit auth-failure strings.** Plex does not emit them
  without raising log verbosity, which materially increases log volume on a
  server whose logs already rotate quickly.

## Consequences

- The jump is the **first** rule, ahead of the conntrack RETURN, so a ban drops
  traffic on connections already established rather than only new ones.
- **Flushing `DOCKER-USER` does not clear bans** — they live in a separate chain.
  This is the property that makes the split work: a playbook run re-adds the
  jump and live bans resume being consulted.
- **Restarting fail2ban does clear bans**, because `actionstop` flushes the
  chain. That happens only when one of its config files changes.
- **401s are normal traffic.** Clients routinely probe an endpoint before
  presenting a token, and one badly-configured internal consumer can emit a
  burst of them — multi-scrobbler did exactly that when its Plex token was
  invalidated. Hence `maxretry: 10` over 10 minutes, and the Docker bridge range
  in `ignoreip`. Lowering `maxretry` without re-reading the log will ban real
  users.
- Tailscale's CGNAT range is in `ignoreip` because every admin path into this box
  runs over it. Banning a tailnet address would remove the means of undoing it.
- This depends on the **real client IP** appearing in Plex's log rather than the
  Docker bridge gateway. Verified on this host; re-check after any change to
  Docker's `userland-proxy` setting, since that determines whether the source
  address survives.
- **The jail watches a symlink, not Plex's own log path.** fail2ban splits the
  last space-separated token off a `logpath` and treats it as a `head`/`tail`
  modifier without checking that it is one, so a path containing spaces — as
  Plex's does, in three directory names — makes the server refuse to start.
  That failure is not confined to this jail: fail2ban aborts configuration
  entirely, taking the sshd jail down with it, which is why the role asserts the
  symlink resolves before restarting the service.
- Coverage is Plex's port only. It is detection for one service, not a
  host-wide IDS.
