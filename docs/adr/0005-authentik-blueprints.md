# ADR-0005: Authentik is configured by blueprints, not the admin UI

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Authentik's groups, providers, applications and policy bindings are normally
created by clicking through the admin UI. That state lives only in its database
— invisible to git, unreviewable, and lost if the database is ever rebuilt.

Authentik ships a declarative alternative: **blueprints**, YAML files it
discovers in `/blueprints` and applies automatically on file write.

## Decision

All Authentik configuration is templated by Ansible into
`{{ config_path }}/authentik/blueprints`, mounted read-only at
`/blueprints/custom`. Rendering the file *is* the deployment — no API call and
no token involved. Secrets are injected with the blueprint `!Env` tag, so they
come from the vault and never appear in git.

Only two things stay manual, because they cannot be automated: enrolling a TOTP
device (requires scanning a QR code) and the initial admin bootstrap (handled by
`AUTHENTIK_BOOTSTRAP_*` on first start).

## Alternatives rejected

- **Admin UI.** Not reproducible, not reviewable, lost on a rebuild.
- **Ansible against the Authentik REST API.** Imperative, needs a long-lived
  API token, and reimplements what blueprints already do declaratively.
- **Terraform provider.** Capable, but introduces a second state-management
  tool alongside Ansible for one application's configuration.

## Consequences

- Mounted at `/blueprints/custom`, never over `/blueprints` — that would hide
  the image's own default blueprints and break the stock authentication flows.
- `!Env` reads the **container's** environment. Putting a secret only in the
  stack's `.env` feeds compose variable substitution, not the container, and the
  blueprint then fails with `client_secret: This field may not be null`.
- Blueprint validation errors are not surfaced in the UI beyond a status of
  `error`. The message is only visible via
  `docker exec authentik_worker ak apply_blueprint <path>`.
- Model fields must match the running version. They were verified against
  Authentik's own shipped blueprints in the container
  (`/blueprints/testing/oidc-conformance.yaml`) rather than from documentation.
  `grant_types` in particular is **required**: omitting it leaves the list empty
  and every authorization request fails with a bare `invalid_request`, with the
  real reason ("Invalid grant_type for provider") only in the server log.
