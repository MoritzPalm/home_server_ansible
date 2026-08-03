# ADR-0003: Forward-auth only for apps with no login of their own

- **Status:** Accepted
- **Date:** 2026-08-02

## Context

Authentik can protect an application two ways:

- **Forward-auth** — Traefik asks Authentik about every request; unauthenticated
  ones get a 302 to a login page. The app never learns who the user is.
- **OIDC** — the app integrates with Authentik as an identity provider, learns
  the user's identity, and keeps its own session.

Forward-auth only works in a **browser**. A native mobile client, CLI or API
token cannot follow the redirect, so applying it to an app with native clients
breaks them.

## Decision

Forward-auth is used **only** where the app has no authentication of its own and
is browser-only: **Homepage** and **Hevy Insights**. Both would otherwise be
open to anyone who knows the URL.

Everything else uses OIDC: **Vikunja**, **Tandoor**, **Immich**, and Paperless
when it is revived.

**Overseerr** deliberately uses neither. Its purpose is letting friends request
media; requiring an Authentik account to reach the request form defeats the
service, and forward-auth also breaks its Plex sign-in.

## Alternatives rejected

- **Forward-auth everywhere.** Would break the Immich, Vikunja and Tandoor
  mobile apps, and make Overseerr useless to anyone without an SSO account.
- **App-native auth everywhere, no SSO.** Leaves each login page as an
  independent target with no MFA, on services reachable from the internet.

## Consequences

- Two mechanisms to understand and maintain rather than one.
- Each OIDC app needs its redirect URIs registered exactly; `matching_mode:
  strict` means a wrong URI fails with an opaque `invalid_request`. Immich needs
  three, including the mobile scheme `app.immich:///oauth-callback`.
- Overseerr remains protected only by its own login plus CrowdSec and rate
  limiting. Accepted deliberately; revisit if it is ever abused.
- Local login stays enabled on every OIDC app, so a broken IdP does not lock
  anyone out of their own data.
