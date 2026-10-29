# Runbooks

Procedures for when something is broken. Each file is self-contained — no
following links to another runbook while something is down.

## What broke?

| Symptom | Runbook |
|---|---|
| One app 404s or is unreachable, everything else fine | [01-container-failure](01-container-failure.md) |
| One app errors, shows missing data, or fails migrations | [02-database-restore](02-database-restore.md) |
| Machine will not boot, or the root filesystem is gone | [03-ssd-failure](03-ssd-failure.md) |
| `/mnt/storage` is short of space, I/O errors in `dmesg` | [04-disk-failure](04-disk-failure.md) |
| Pool gone, or the machine is gone entirely | [disaster-recovery](disaster-recovery.md) |
| I just need one file, right now, from anywhere | [disaster-recovery § 1](disaster-recovery.md) |

## Before you need them

- [99-secrets-escrow](99-secrets-escrow.md) — the ansible-vault password is the
  one irreplaceable secret, and the only thing protecting a publicly readable
  vault. Everything else derives from it.
- [00-drill](00-drill.md) — quarterly verification. An untested backup is a
  hypothesis.

## Two facts that shape all of this

**The SSD and the pool are independent failure domains.**

| | Holds |
|---|---|
| SSD (`/`) | `/srv/data/configs`, `/srv/data/db`, `/srv/compose`, the OS |
| Pool (`/mnt/storage`) | media, photos, documents, **and `/mnt/backups`** |

The local restic repository lives on the pool, so **losing the SSD — the most
likely serious failure — restores with no download at all**. The off-site
repository covers losing the pool.

**Compose files come from GitHub, not from this machine.** `/srv/compose` is
force-cloned by the `docker` role. Any recovery that involves changed compose
files must commit and push first, and must include the `docker` tag in the
playbook run.

## What is deliberately not backed up

Everything meant to survive must appear in `backup_paths`, `backup_databases`
or `backup_bulk_paths` in `roles/backup/defaults/main.yml`. A new stack whose
state lives outside `/srv/data/configs` needs an entry there, or it is in this
table by accident.

| | Why | After a loss |
|---|---|---|
| Films, TV, music, books under `/mnt/storage/media` | Reacquirable, and most of the pool | The *arr history and indexers are in the config snapshot; re-add from there |
| Postgres data directories under `/srv/data/db` | A file copy of a running cluster is not reliably restorable | `pg_dump` output is in every `automated` snapshot — [02-database-restore](02-database-restore.md) |
| Prometheus and Loki data | Metrics and logs, 15-day retention | Start empty |
| soulsync's `music_library.db` | 1.5 GB scan of the music library, rewritten nightly | Rescan from its UI; its encryption key and listening history *are* backed up |
| Grafana plugins | Re-downloaded at start | — |
| `/srv/compose` and every `.env` | Regenerated from GitHub and the vault | `ansible-playbook playbooks/site.yml` |
| Uptime Kuma on the Pi (`/srv/data/db/uptime-kuma`) | On the Pi, where the backup role does not run | Monitors and the Discord route are recreated by `pi.yml`; uptime history is lost |
