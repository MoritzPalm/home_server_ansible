# F4 — One pool disk died

**Symptoms:** `/mnt/storage` has lost capacity, files that existed are gone, or
`dmesg` shows I/O errors.

---

## Stop and check this first

> **There is no parity.** mergerfs is a union of two independent ext4
> filesystems — losing one disk loses exactly the files stored on it, and
> mergerfs may have placed any given file on either disk. You cannot infer what
> was lost from what remains.
>
> This is a deliberate choice (media is reacquirable). Photos and documents are
> protected off-site instead, so they are recoverable regardless of which disk
> held them.

> **The local restic repository lives on the pool** (`/mnt/backups`). If the
> failed disk held part of it, treat the local repo as unusable and restore from
> off-site. The next backup run re-initialises it.

---

## Diagnose

```bash
lsblk -o NAME,SIZE,SERIAL,MODEL,MOUNTPOINT
dmesg | grep -iE 'I/O error|ata[0-9]|failed command'
df -h /mnt/hdd1 /mnt/hdd2 /mnt/storage
sudo smartctl -a /dev/sdX | grep -iE 'result|reallocated|pending|health'
```

Identify which of `/mnt/hdd1` or `/mnt/hdd2` is affected and note its **serial**,
so you replace the right physical disk.

Work out roughly what was on it — mergerfs exposes the union, but each branch is
a normal filesystem you can list directly:

```bash
sudo find /mnt/hdd2/media -maxdepth 2 | head -50    # the surviving branch
```

---

## Recover

### 1. Replace and format

```bash
sudo mkfs.ext4 -L hdd1 /dev/sdX
sudo blkid /dev/sdX1          # note the NEW UUID
```

### 2. Update the inventory

Edit `inventories/host_vars/mserver/mserver.yml`:

```yaml
hdd_mounts:
  - { uuid: "<new-uuid>", path: "/mnt/hdd1", fstype: ext4 }
  - { uuid: "36453ee3-a0b3-4002-b0b9-b6212855cf64", path: "/mnt/hdd2", fstype: ext4 }
```

The storage role asserts these UUIDs exist and, on failure, prints every UUID
actually present — so if you skip this step the error tells you what to paste.

### 3. Remount the pool

```bash
ansible-playbook playbooks/site.yml --tags storage
df -h /mnt/storage        # full capacity back
```

### 4. Restore what cannot be reacquired

```bash
sudo restic-repo offsite snapshots --tag bulk
sudo restic-repo offsite restore latest --tag bulk --target / \
  --include /mnt/storage/media/photos \
  --include /mnt/storage/documents
```

Note that `restic restore` writes **everything** in the snapshot, not only what
is missing. If most files survived, restore to a scratch target and fill the
gaps instead, which avoids rewriting terabytes of intact data:

```bash
sudo restic-repo offsite restore latest --tag bulk --target /mnt/storage/restore-tmp
sudo rsync -a --ignore-existing /mnt/storage/restore-tmp/mnt/storage/ /mnt/storage/
sudo rm -rf /mnt/storage/restore-tmp
```

### 5. Reacquire media

Films, TV and music are not backed up. The *arr stack's history and indexers
live on the SSD and survived, so re-add the missing items from within
Sonarr/Radarr/Lidarr and let them download again.

---

## Verify

```bash
df -h /mnt/storage
sudo find /mnt/storage/media/photos ! -user 1000 | head    # expect empty
```

Then trigger rescans so the databases and files agree again:

- **Immich** → Administration → Jobs → *Storage Migration* / *Library Scan*
- **Paperless** → documents are re-indexed on start; check the count matches
- **Plex/Jellyfin** → scan libraries, expect missing items to disappear cleanly

Finally, confirm the backup job still works now the pool has changed:

```bash
sudo systemctl start home-server-backup.service
journalctl -u home-server-backup.service -n 30 --no-pager
```
