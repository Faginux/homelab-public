# backup — the-grid

The backup uses a container `offen/docker-volume-backup:v2`. It has the same shape as `volume-backup`
on ARCADE. `dvb-local` creates archives in `/srv/backup/docker-volumes` on Tuesday and Friday at
03:00. The retention is 29 days.

**The copy outside the node is on ARCADE.** This started on 2026-10-02. Every morning at 05:40,
ARCADE downloads the archives of `dvb-local`. It uses a read-only SFTP pull, verifies the archives
with SHA-256, and keeps them for 36 days. For details, read `tools/the-grid-backup-pull/README.md`.

For this reason, `/srv/backup/docker-volumes` also contains `<archivio>.sha256` files.
`backup-sha256-manifest.timer` writes them at 03:40 (`../systemd/README.md`).

Until 2026-10-02, there was a second service, `dvb-remote-scope`. It ran on Saturday at 05:00, used
SSH to `scope:~/backups/the-grid`, and had a retention of 36 days. The service was removed. The
reason: the scope corrupted writes due to undervoltage (`PROBLEMI-E-SOLUZIONI.md` §11.5,
`PIANO-DECLASSAMENTO-scope.md` A.6). The sections below that mention it are history.

## Prerequisites already done (2026-08-26)

- `/srv/docker` exists. The owner is `ops:ops` and the permissions are `755`.
- The key `~/.ssh/id_ed25519_dvb_scope` is on the-grid. It has no passphrase.
- The host key of the scope is in `known_hosts` of the-grid. The **fingerprint was compared** with the
  fingerprint that ARCADE already trusts, before the host key was accepted.
- The scope authorizes the key with the prefix `restrict`. The destination `~/backups/the-grid`
  exists.
- The path was verified end-to-end with `exec` and `sftp put`. The file was **read again** at the
  destination, and then deleted.

## Notifications — verified

The shoutrrr URL points to the same Telegram channel as watchtower. Since 2026-09-23, the URL is no
longer in the `.env`. dvb reads it from `/srv/docker/_secrets/backup/notification_urls`
(`NOTIFICATION_URLS_FILE`, 0400). The file has **no trailing newline**, because dvb does not strip
spaces. On the same day, a round of `dvb-remote-scope` at level `info` verified this again: the
message arrived.

`NOTIFICATION_LEVEL` is `error` on both services. A successful backup sends nothing. This is fine,
but it means that **silence does not prove that the channel works**.

For this reason, the test ran once at level `info`, without a change to the compose:

```bash
docker compose run --rm --entrypoint backup -e NOTIFICATION_LEVEL=info dvb-local
```

The message arrived. If you ever change the bot or the chat, repeat **this** check. A check that the
variable is inside the container proves nothing about delivery.

> `docker compose run --rm <servizio> backup` does **not** work. `backup` becomes an argument of the
> entrypoint, and the entrypoint is already the binary. The result is
> `panic: unknown command: backup`. Use `--entrypoint backup`.

## The `.env` is saved in `/srv/docker/_secrets/`

This is a copy of `nodes/the-grid/backup/.env`. The file permissions are `600` and the directory
permissions are `700`. The copy is here, and not elsewhere, for a precise reason. `/srv/docker` is a
**source of the backup**, so the copy goes into every archive: the local archives and the archives
on the scope. A backup in `~/qualcosa` survives a `git clean`. It does not survive the loss of the node.

A check verified that the copy really arrives in the archive, with the permissions intact:

```
-rw------- 1000/1000  370  /backup/srv-docker/_secrets/backup.env
```

Put the `.env` of the next stacks in the same directory.

## age encryption — since 2026-09-23

The archives contain secrets: `_secrets/`, and since Phase 1 of `PIANO-KOMODO-SECRETS-GATE.md` also
the secret files. Until 2026-09-22, the archives were unencrypted `tar.gz` files, on an scope that is
also the Bitwarden node. A person who compromised the scope got all the credentials of the fleet. Now:

- **Both** services have `AGE_PUBLIC_KEYS`, with the same public key. The key is in the compose. It
  is not a secret.
- The archives have the name `the-grid-volumes-<data>.tar.gz.age` and the header
  `age-encryption.org/v1`. The unencrypted `.tar.gz` exists only in `/tmp` of the container. dvb
  deletes it right after.
- the-grid **encrypts but cannot decrypt**. The private key is in Bitwarden, in the secure note
  **"age — backup dvb the-grid"**. Since 2026-10-02, the key is also **outside** the vault. The outside
  copies are an offline USB stick (unencrypted) and two copies encrypted with a passphrase
  (`age -p`, on a phone and on Google Drive). The passphrase is only on paper.
- The outside copies are needed because, after the migration of Bitwarden to the-grid, the vault itself is
  inside these archives. If every copy of the key is lost, the archives are unreadable, **even the
  local ones**. Both kinds of copy were verified on 2026-10-02. The USB stick was verified with A.5 of
  the plan (3896 entries). The test used the `age -p` copy to decrypt the same archive. The number of
  entries was the same.

`BACKUP_PRUNING_PREFIX` does not change. The prefix is the same, and only the suffix changes. The
unencrypted archives from before 2026-09-23 stay readable until the retention prunes them (29 days
locally, 36 days on the scope).

**Verified on 2026-09-23** `[Certo]`: a test backup (382 MB, age header) was downloaded to
ARCADE and decrypted with the key from Bitwarden. Then `tar -tzf` read the whole archive. It
listed 3814 entries, including `_secrets/backup.env` and `paperless/db/PG_VERSION`.

### Test backup without stopping anyone

```bash
docker compose run --rm --entrypoint backup \
  -e BACKUP_STOP_DURING_BACKUP_LABEL=nessuno-test dvb-local
```

`BACKUP_STOP_DURING_BACKUP_LABEL` is the **value** of the label that dvb searches for. If no container
has this value, dvb stops nothing. It copies the SQLite files while the containers are running. This
is fine for a test. For an archive that you keep as a real backup, remove the override.

### Restore (from ARCADE, PowerShell, `age` via `winget install --id FiloSottile.age --exact`)

```powershell
$dir = Join-Path $env:TEMP 'restore-dvb'
New-Item -ItemType Directory -Force $dir | Out-Null
$f = 'the-grid-volumes-<data>.tar.gz.age'
scp "the-grid:/srv/backup/docker-volumes/$f" $dir\     # or from the scope: ~/backups/the-grid/

Read-Host 'Ora copia la nota da Bitwarden, poi premi Invio' | Out-Null; $k = Get-Clipboard; if ($k -match '^AGE-SECRET-KEY-1') { $k | age -d -i - -o "$dir\restore.tar.gz" "$dir\$f"; "exit: $LASTEXITCODE" } else { 'Negli appunti non c''e'' la chiave age: niente di fatto' }; Remove-Variable k

tar -tzf "$dir\restore.tar.gz" | Measure-Object -Line   # reads the complete stream: it proves the integrity
```

- **Why the command has `Read-Host`:** If you copy the commands from somewhere, the copy
  **replaces the key in the clipboard**. Then age receives the commands instead of the key
  (`error at line 2: unknown identity type`). This happened at the first try, on 2026-09-23. First
  start the command. **Then** copy the key.
- `-i -` makes age read the key from stdin. The key is never written to the disk.
- At the end, run `Remove-Item -Recurse -Force $dir`. The decrypted `.tar.gz` contains everything
  **unencrypted**. Also delete the entry from the clipboard history (Win+V).

### Still unencrypted

~~The archive of ARCADE on the scope contains 13 `.env` files unencrypted.~~ **Resolved on
2026-10-02.** The offsite copies of ARCADE (scope and the-grid) have the name
`arcade-volumes-*.tar.gz.age`. They use this same public key (`stacks/volume-backup/README.md`).

The restore procedure is the procedure above. Only the file changes. On the scope, the file is in
`~/backups/arcade/`. On the-grid, it is in `/srv/backup/from-arcade/`.

## When a new stack arrives

The bind that already exists covers the data under `/srv/docker/<stack>/` automatically. It does
**not** cover the **named volumes**. Add each named volume by hand to **both** services. Also add the
`volumes:` section with `external: true` at the bottom of the compose. Without `external`, Compose
creates new volumes with the project prefix. The result is empty archives that look successful.

Apply the label `docker-volume-backup.stop-during-backup=true` to the containers with SQLite
(Tautulli, Seerr, DockHand). `BACKUP_STOP_DURING_BACKUP_LABEL` is already active on both services.
But without the label on the container, dvb stops nothing, and it copies the DB while the container
is running.

## Bitwarden (since 2026-10-04)

The data is in `/srv/docker/bitwarden/{data,mysql}`. The bind that already exists covers it. There is
no volume to add. Both containers have the label `stop-during-backup`, because MariaDB must not be
copied while it is running. `dvb-local` stops them for about 30 s on Tuesday and Friday at 03:00.

The first archive with Bitwarden is from 2026-10-06 at 08:59. The round at 03:00 failed because of
the `access.log` of Caddy (`PROBLEMI-E-SOLUZIONI.md` §13.4).

There is also a weekly **logical dump**, independent of dvb.
`nodes/the-grid/bitwarden/backup-bitwarden.sh` (cron Sunday 02:45) writes
`bitwarden_vault_*.sql.gz` in `/srv/backup/bitwarden-dumps`. The owner is `ops:v4pull`, the
directory permissions are 2750, the file permissions are 640, and the retention is 4. ARCADE
downloads the dump with the pull at 05:40 (`tools/the-grid-backup-pull`, source `bitwarden-dumps`),
together with the `.sha256` of the 03:40 manifest. The dump is **not** encrypted. The elements of the
vault are already encrypted on the client, but the email and the metadata are not.
