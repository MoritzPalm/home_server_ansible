# Secrets escrow

**Exactly one secret is irreplaceable: the ansible-vault password.**

Everything else derives from it. `inventories/host_vars/mserver/vault.yml` is
committed and pushed to `github.com/MoritzPalm/home_server_ansible`, which is a
**public** repository — so the encrypted vault can be fetched from anywhere, by
anyone, with no GitHub account and no credentials:

```
vault password  +  public repo  →  restic password  →  backups
```

Lose the vault password and the off-site backups are permanently unreadable. The
data still exists on the Storage Box; nobody, including you, can decrypt it.

## What the public repository means for the passphrase

Being public inverts the usual threat model. The encrypted file is downloadable
by anyone, permanently — forks and clones outlive any deletion — and can be
attacked offline with no rate limiting. `ansible-vault` 1.1 uses
PBKDF2-HMAC-SHA256 at 10,000 iterations, which is low by current standards.

That passphrase is the sole protection for **every** secret in the repository:
Authentik's signing key, every database password, the OIDC client secrets, the
Cloudflare tunnel credentials, the restic password.

It should be high-entropy — six or more Diceware words, or 20+ random
characters. If it is currently something short and memorable:

1. `ansible-vault rekey inventories/host_vars/mserver/vault.yml`
2. **Rotate the underlying secrets as well.** Rekeying does not help for a file
   already published under a weak passphrase: the old version stays in the git
   history and in every clone.

## What to store where

**Password manager** (anything not hosted on mserver):

| Item | Why |
|---|---|
| ansible-vault password | Mandatory. Nothing else can reconstruct it. |
| restic repository password | Optional redundancy — recovery then does not depend on the repository still existing |
| Storage Box user + SSH key | Same reasoning |

The second and third are convenience, not necessity: both are recoverable from
the public repository with the vault password alone.

**Physical copy of the vault password.** A card in a drawer, or with family. The
password manager is otherwise a single point of failure, usually sitting on the
same laptop you use every day.

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
