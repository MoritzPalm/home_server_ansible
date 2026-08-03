# Secrets escrow

Three secrets must exist **outside** mserver. Without them the off-site backups
are undecryptable and recovery from total loss is impossible.

This is the one part of the recovery design that nothing can enforce.

| Secret | Normally lives in | Why it is unrecoverable |
|---|---|---|
| **ansible-vault password** | your memory only | Decrypts the other two. Nothing stores it. |
| **restic repository password** | `vault_restic_password` in `vault.yml` | The repository is encrypted with it. restic has no recovery mode, no backdoor and no reset. |
| **Hetzner Storage Box credentials** | `vault_restic_offsite_env` in `vault.yml` | Without them the repository cannot be reached at all. |

## The circular dependency

The restic password and the Storage Box credentials are *in* the vault. The
vault password decrypts them. So:

```
vault password  →  vault.yml (on GitHub)  →  restic password  →  backups
```

If you have the vault password and can reach GitHub, you can recover everything.
**If you lose the vault password, the backups are permanently unreadable** — the
data still exists on the Storage Box and cannot be decrypted, by you or anyone.

## What to do

**Password manager** (Bitwarden, 1Password, iCloud Keychain — anything not
hosted on mserver):

- the ansible-vault password
- the restic repository password, copied out of the vault
- the Storage Box username and password/SSH key

Storing the latter two separately breaks the circular dependency: you can then
recover even if GitHub is unreachable or the vault file is damaged.

**Physical copy** for the vault password. A card in a drawer, or with family.
It protects against losing the password manager itself, which is otherwise a
single point of failure sitting on the same laptop you use every day.

## Extracting them

```bash
cd ansible
ansible-vault view inventories/host_vars/mserver/vault.yml \
  | grep -E 'restic|storagebox'
```

## Verifying the escrow works

Once a year, ideally alongside [00-drill](00-drill.md), prove the chain from the
copies rather than the originals:

1. On a machine that is **not** mserver, using only what is in the password
   manager:
   ```bash
   export RESTIC_REPOSITORY='sftp:uXXXXXX@uXXXXXX.your-storagebox.de:/backup'
   export RESTIC_PASSWORD='<from the password manager>'
   restic snapshots
   ```
2. If that lists snapshots, the escrow is real.

Do not skip this because the values "should" be right. A transcription error in
a password you never test is indistinguishable from having no backup at all,
and you find out at the worst possible moment.

## When to rotate

- **Vault password** — if it may have been exposed. Re-encrypt with
  `ansible-vault rekey` and update every copy.
- **restic password** — rotating means the existing repository stays on the old
  password. restic cannot re-encrypt in place; you would start a new repository
  and re-upload everything. Only do this if the password is actually compromised.
- **Storage Box credentials** — safe to rotate whenever; update
  `vault_restic_offsite_env` and re-run the `backup` tag.
