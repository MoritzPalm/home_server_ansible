# Disaster recovery: mserver is gone

Recovering data when the server is dead, stolen or burnt. Assumes the Hetzner
Storage Box off-site repository is intact.

Nothing here needs mserver. Every step runs from a laptop.

## 0. What you must have off the machine

Recovery is impossible without these, and all three live in places that die with
the server unless you deliberately copied them elsewhere. Keep them in a
password manager, and ideally on paper somewhere physical.

| Secret | Normally lives in |
|---|---|
| restic repository password | `vault_restic_password` in `inventories/host_vars/mserver/vault.yml` |
| Storage Box user + SSH key or password | `vault_restic_offsite_env` in the same file |
| **ansible-vault password** | your head — it decrypts the two above |

The Ansible and compose repositories are on GitHub, so the *configuration*
survives independently. Only these secrets are irreplaceable.

If you have the vault password and network access, recover the other two with:

```bash
git clone git@github.com:MoritzPalm/home_server_ansible.git
cd home_server_ansible
ansible-vault view inventories/host_vars/mserver/vault.yml | grep -E 'restic'
```

## 1. Get at the data (minutes)

Install restic on any machine — `brew install restic`, `apt install restic`.

```bash
export RESTIC_REPOSITORY="sftp:u123456@u123456.your-storagebox.de:/backup"
export RESTIC_PASSWORD='...'

restic snapshots                 # confirm the repository is readable
restic snapshots --tag bulk      # photo/document snapshots
restic snapshots --tag automated # databases + configuration
```

SSH must be able to reach the Storage Box: restic's sftp backend shells out to
the system `ssh`, so add the key first (`ssh-add`, or a `~/.ssh/config` entry
for the storage box host).

### Urgent access to a few files — do not restore everything

```bash
mkdir /tmp/backup && restic mount /tmp/backup
```

The whole repository appears as a browsable filesystem under
`/tmp/backup/snapshots/latest/`. Files stream on demand, so a single document is
available in seconds without downloading 300 GB. Needs FUSE (macOS: macFUSE).

Ctrl-C to unmount.

### Selective restore

```bash
restic restore latest --target /tmp/restore \
  --include /mnt/storage/documents
```

## 2. Timings, so expectations are right

Hetzner does not throttle and charges nothing for traffic, so this is bounded by
your own downlink:

| Library | 100 Mbit | 250 Mbit | 1 Gbit |
|---|---|---|---|
| 300 GB | ~7 h | ~3 h | ~45 min |
| 1 TB | ~24 h | ~10 h | ~2.5 h |

If the data is needed online *now* rather than locally, restore onto a Hetzner
cloud VM in the same datacentre instead — internal transfer is far faster than
pulling it home, and a temporary Immich or Paperless instance can serve from
there while the real server is rebuilt.

## 3. Rebuilding the server

If only the pool died and the machine still runs, skip to step 4.

**Order matters.** Each step depends on the previous one, and getting it wrong
mostly shows up as confusing authentication failures much later.

### 3.1 Bootstrap

Mint a **fresh Tailscale auth key** first — the vaulted one expires after 90
days — and update `vault_tailscale_authkey`. Then install Ubuntu 24.04 (same
hostname) and, from your laptop against the LAN address:

```bash
ansible-playbook playbooks/bootstrap.yml \
  -e bootstrap_ip=192.168.178.35 -e bootstrap_ssh_user=<installer-account>
```

Remove the dead node from the Tailscale admin panel first, or the new machine
joins as `mserver-1` and the assertion at the end of the bootstrap will tell you
so.

### 3.2 Storage

New disks have new UUIDs. Update `hdd_mounts` in
`inventories/host_vars/mserver/mserver.yml` before running anything else; the
storage role prints every UUID it can see when the assertion fails.

```bash
ansible-playbook playbooks/site.yml --tags storage
```

### 3.3 Everything else

```bash
ansible-playbook playbooks/site.yml
```

Reconstructs every stack, network, firewall rule, Traefik router and Authentik
blueprint from git. Applications come up **empty**.

### 3.4 Restore, in this order

1. **Authentik's database** — everything else authenticates against it
2. The remaining databases (§4)
3. `/srv/data/configs` (§4a)
4. Photos and documents (§5)

### 3.5 State that is in neither git nor the backups

| What | Action |
|---|---|
| **Cloudflare tunnel** | `credentials.json` is in the vault, but the tunnel object may not exist. Recreate it if needed and update `vault_cloudflared_tunnel_id`. |
| **Cloudflare DNS** | `cloudflared tunnel route dns <tunnel> <host>` for all eight hostnames — proxied CNAMEs, not A records |
| **Fritz!Box** | Re-add the forward: external TCP 32401 → `192.168.178.35:32400`. Confirm UPnP is still disabled. |
| **Plex** | Re-claim; see §6 |
| **Tailscale** | Remove the dead node, mint a fresh key |

### 4a. Restoring configuration

```bash
sudo -E restic restore latest --target / --include /srv/data/configs
```

Brings back what Ansible cannot reproduce: *arr indexers and API keys, quality
profiles, download history, Plex watch history and playlists, Overseerr
requests, qBittorrent seeding state.

`/srv/compose` needs no restore — the `docker` role re-clones it from GitHub.
`.env` files are regenerated by Ansible, not restored.

## 4. Restoring databases

Dumps are gzipped `pg_dump --clean --if-exists` output, one per database, under
`/srv/data/backup-staging/db` in the snapshot.

```bash
restic restore latest --target /tmp/r --include /srv/data/backup-staging/db
ls /tmp/r/srv/data/backup-staging/db
```

With the target stack running but the application container stopped:

```bash
gunzip -c /tmp/r/srv/data/backup-staging/db/paperless.sql.gz \
  | docker exec -i paperless_db psql -U paperless -d paperless
```

Repeat per database: `authentik`, `paperless`, `vikunja`, `recipes`, `immich`.

**immich must be restored into the same image** — the dump references the
vectorchord and pgvectors extensions and will not load into stock PostgreSQL.

**authentik first, if you want SSO back before anything else.** Vikunja,
Tandoor, Paperless and Immich all authenticate against it.

## 5. Restoring photos and documents

```bash
restic restore latest --tag bulk --target / \
  --include /mnt/storage/media/photos \
  --include /mnt/storage/documents
```

Restoring to `/` writes the original absolute paths. Check free space first, and
that ownership ends up as uid 1000 — Immich and Paperless both run as that uid
and will not read root-owned files.

Then trigger a library rescan in Immich so it re-indexes what the database
already references.

## 6. Plex

A rebuilt server is signed out of plex.tv, and Plex without its token answers
401 to everything while still serving the web app — so it looks broken in a
confusing way.

```bash
docker exec plex cat "/config/Library/Application Support/Plex Media Server/Preferences.xml" \
  | tr ' ' '\n' | grep PlexOnlineToken
```

If empty, get a claim token from <https://plex.tv/claim>. **It expires in 4
minutes**, so have this ready before you fetch it:

```bash
cd /srv/compose/media
sudo sed -i 's/^PLEX_CLAIM=.*/PLEX_CLAIM=claim-xxxxxxxx/' .env
docker compose -f media.yml up -d plex
```

Plex runs with `Secure connections = Required`, so verify over HTTPS — plain
HTTP is refused and looks like an outage:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://100.78.131.48:32400/identity
```

Also regenerate `vault_plex_token` afterwards: the old one is invalid and
multi-scrobbler uses it.

## 7. Verify

Full procedure in [00-drill.md](00-drill.md). Run it now, not during an
incident — an untested backup is a hypothesis.
