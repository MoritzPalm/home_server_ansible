# F2 — One application database corrupted

**Symptoms:** the app returns 500s, fails migrations on start, or is missing
records it should have.

---

## Stop and check this first

> **Stop the application before restoring.** The dumps are
> `pg_dump --clean --if-exists`, so they drop and recreate every object. A
> running app writing during the restore produces a half-old, half-new database
> that looks fine until it does not.

> **Restore Authentik first** if more than one database is affected. Vikunja,
> Tandoor, Paperless and Immich all authenticate against it, and they will fail
> in confusing ways while it is empty.

---

## Which database

| App | Container | Database | User |
|---|---|---|---|
| Authentik | `authentik_postgres` | `authentik` | `authentik` |
| Paperless | `paperless_db` | `paperless` | `paperless` |
| Vikunja | `vikunja_db` | `vikunja` | `vikunja` |
| Tandoor | `tandoor_db` | `recipes` | `djangodb` |
| Immich | `immich_postgres` | `immich` | `postgres` |

---

## Restore

```bash
export RESTIC_REPOSITORY=/mnt/backups/restic
export RESTIC_PASSWORD_FILE=/etc/restic/password

# 1. Pick a snapshot from before the corruption
restic snapshots --tag automated

# 2. Pull just the dumps out of it
restic restore <snapshot-id> --target /tmp/r \
  --include /srv/data/backup-staging/db
ls -la /tmp/r/srv/data/backup-staging/db

# 3. Stop the app (NOT the database)
docker stop <app-container>

# 4. Load the dump
gunzip -c /tmp/r/srv/data/backup-staging/db/<database>.sql.gz \
  | docker exec -i <db-container> psql -U <user> -d <database>

# 5. Start the app
docker start <app-container>
```

Watch step 4's output. `ERROR: ... does not exist` lines during the `DROP`
section are normal — that is what `--if-exists` handles. Errors during `CREATE`
or `COPY` are not, and mean the restore failed.

---

## Per-app notes

**Immich** — the dump references the `vectorchord` and `pgvectors` extensions and
will **not** load into stock PostgreSQL. The container image
(`ghcr.io/immich-app/postgres:14-vectorchord…`) is not optional here. After
restoring, the database references files on disk; if those are also missing,
restore the photo library first or Immich will show broken thumbnails.

**Authentik** — restoring invalidates every session, so everyone logs in again.
The OIDC provider definitions come back with the database, but the client
secrets must still match the ones in the apps' `.env` files. Those are
templated from the vault, so re-running the relevant role tags after the restore
guarantees both sides agree:

```bash
ansible-playbook playbooks/site.yml --tags identity,productivity,kitchen,paperless,media
```

**Paperless** — the database holds document *metadata*; the files themselves are
under `/mnt/storage/documents`. A database restore alone will show documents
whose files are missing if the pool was also affected.

**Tandoor / Vikunja** — no special handling.

---

## Verify

```bash
docker logs --tail 30 <app-container>       # clean start, no migration errors
docker inspect <app-container> --format '{{.State.Health.Status}}'
```

Log in and check a record you know should exist. For Paperless and Immich also
confirm a document or photo actually opens, which proves metadata and files
agree.

## Clean up

```bash
rm -rf /tmp/r
```
