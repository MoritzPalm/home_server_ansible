# Architecture Decision Records

Short records of decisions whose *reasoning* is not recoverable from the code.

A file belongs here when someone (including future you) would look at the
config and reasonably ask "why on earth is it done that way?" — Plex bypassing
the reverse proxy, Postgres pinned to 16 when 18 exists, the firewall rule that
names a container port rather than the published one.

Things that do **not** belong here: how something works (put that in a comment
next to it), or what the current state is (the code is the state).

## Rules

- **Numbered and immutable.** Once a record is Accepted, don't rewrite it. If
  the decision changes, write a new record and mark the old one `Superseded by
  ADR-XXXX`. The wrong turns are often the most useful part — ADR-0001 exists
  precisely because it reverses two earlier positions.
- **Short.** If it needs more than a page, the decision probably isn't isolated
  enough to be one record.
- **Record the rejected options.** "We considered X and rejected it because Y"
  prevents the same idea being re-litigated in six months.

## Format

Copy `template.md`. Based on Michael Nygard's original format.

## Index

| # | Title | Status |
|---|-------|--------|
| [0001](0001-cloudflare-tunnel-only-ingress.md) | Cloudflare Tunnel is the only ingress | Accepted |
| [0002](0002-plex-bypasses-traefik.md) | Plex is exposed directly, outside Traefik | Accepted |
| [0003](0003-forward-auth-vs-oidc.md) | Forward-auth only for apps with no login of their own | Accepted |
| [0004](0004-docker-user-firewall.md) | Container ingress policy lives in DOCKER-USER, not UFW | Accepted |
| [0005](0005-authentik-blueprints.md) | Authentik is configured by blueprints, not the admin UI | Accepted |
| [0006](0006-plex-fail2ban-in-docker-user.md) | Plex bans go in DOCKER-USER, ownership split with fail2ban | Accepted |
