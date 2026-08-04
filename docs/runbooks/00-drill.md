# Backup drill

Run quarterly. Takes about 30 minutes, most of it waiting.

An untested backup is a hypothesis. Every step here exists because the failure
it catches is silent — a backup that has been quietly writing nothing for six
months looks exactly like one that works, right up until you need it.

Record the result at the bottom.

---

## 1. Is it running at all?

```bash
systemctl status home-server-backup.timer
systemctl list-timers home-server-backup.timer --no-pager
journalctl -u home-server-backup.service -n 40 --no-pager
```

The Prometheus alerts (`BackupMissing`, `BackupStale`, `BackupFailing`) should
have told you already. If they never fire, confirm they *can*:

```bash
curl -s http://100.78.131.48:9090/api/v1/query \
  --data-urlencode 'query=home_server_backup_last_run_timestamp_seconds' \
  | python3 -m json.tool | head -20
```

An empty result means node-exporter is not reading the textfile directory, and
the alerts are decorative.

## 2. Repository integrity

```bash
sudo restic-repo local check
sudo restic-repo offsite check --read-data-subset 5%
```

`check` alone verifies structure and metadata. `--read-data-subset 5%` actually
downloads and verifies pack contents — the only thing that detects silent
corruption. 5% each quarter covers the repository over five years, which is the
right trade against egress time.

## 3. Does the content match expectations?

```bash
sudo restic-repo local snapshots
sudo restic-repo local ls latest | grep -E 'sonarr\.db|radarr\.db|Preferences\.xml'
sudo restic-repo local ls latest | grep -c 'Plex Media Server/Media'   # expect 0
```

The last one matters: if the exclusions stopped working, the repository is
quietly storing tens of GB of regenerable artwork and the cost has grown for
nothing.

## 4. Restore something and open it

```bash
sudo restic-repo local restore latest --target /tmp/drill \
  --include /srv/data/backup-staging/db

gunzip -t /tmp/drill/srv/data/backup-staging/db/*.sql.gz && echo "dumps intact"
zcat /tmp/drill/srv/data/backup-staging/db/authentik.sql.gz | head -20
```

`gunzip -t` verifies the archives are complete; the `head` confirms it is real
SQL and not a zero-byte file from a failed `pg_dump`.

## 5. Prove the off-site copy is reachable *and decryptable from elsewhere*

Do this from your **laptop**, not mserver, using the credentials from your
password manager rather than the vault — this is what tests
[99-secrets-escrow](99-secrets-escrow.md):

```bash
export RESTIC_REPOSITORY='sftp:uXXXXXX@uXXXXXX.your-storagebox.de:/backup'
export RESTIC_PASSWORD='<from the password manager>'

restic snapshots
mkdir -p /tmp/browse && restic mount /tmp/browse
# in another shell: open a photo under /tmp/browse/snapshots/latest/
```

If this works, you can recover from a total loss. If it does not, nothing else
in this document matters.

## 6. Clean up

```bash
rm -rf /tmp/drill
umount /tmp/browse 2>/dev/null; rmdir /tmp/browse
```

---

## Log

| Date | Local check | Off-site check | Restore test | Escrow test | Notes |
|---|---|---|---|---|---|
| | | | | | |
