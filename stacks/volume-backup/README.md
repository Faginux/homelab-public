# volume-backup — ARCADE

This stack creates backups of Docker volumes and bind mounts. It uses `offen/docker-volume-backup:v2`.

## Containers

| Name | Destination | Schedule | Retention |
|---|---|---|---|
| `dvb-local` | `S:\Bakcup_Servarr+\Docker Volumes` | Monday and Thursday at 02:15 | 29 days (8 archives) |
| `dvb-remote-the-grid` | the-grid via SSH (`/srv/backup/from-arcade`) | Sunday at 06:00 | 36 days (5 archives) |

The two containers have identical sources. Every offsite copy already contains the whole
`Docker yml` directory, and so all the composes.

A third container, `dvb-remote-scope`, copied the same data to the scope on Sunday at 05:00. It was
removed on 2026-10-11 (decision D7 in `PIANO-DECLASSAMENTO-scope.md`). The SSD of the scope had
corrupted archives. Today the scope is an experimental node.

## What is inside the archive

```
/backup/docker-yml          bind    all the compose files + stack configs still
                                    live on ARCADE (immich, maintenance,
                                    tdarr) and the history of the migrated ones
/backup/immich-db-dumps     bind    dump ufficiali pg_dumpall di Immich
/backup/docker-appdata      bind    configs of the stacks consolidated in the repo
                                    (tdarr, qbit_manage, cleanuparr, kometa,
                                    umtk), since 2026-10-02
```

**`docker-appdata` (since 2026-10-02)** is about 2.6 GB. An archive is from about 0.5 GB to about
2.45 GB. The "Original Posters" of Kometa (`kometa/config/overlays`) are 72% of it. They are kept
on purpose: they are needed to remove the overlays.

`cleanuparr` has the label `docker-volume-backup.stop-during-backup=true`. The reasons are SQLite
in WAL, and the QueueCleaner also runs at 02:15:00. The container stays stopped for about 1 minute.
`tdarr` does not have this label, because stopping it interrupts the transcodes. The restore uses
the consistent zips that Tdarr creates by itself in `server/Tdarr/Backups`, every night at 00:00.
They contain `DB2/SQL` and all the `*JSONDB`.

**The live DB `tdarr/server/Tdarr/DB2` is excluded since 2026-10-02.** The test round at 03:31
failed, because `database.db-shm` disappeared between the listing and the read. (dvb abandons the
whole archive after an `ENOENT`.) The loss is only the history `JobReports` (499 MB). The
exclusions are in the compose (`x-backup-exclude`), no longer in the `.env`.

The manual round of 2026-10-02 at 00:37 took **80 s** in total: 59 s for tar+gzip with cleanuparr
stopped, and 20 s for the copy. `Test-BackupContent.ps1` reported all OK.

⚠️ This data contains unencrypted secrets: `config.yml` of Kometa and qbit_manage, and the
config of umtk. `docker-yml` also contains the `.env` files. For this reason, the offsite copies are
encrypted since 2026-10-02 (described below).

## age encryption (since 2026-10-02)

- `dvb-remote-the-grid` has `AGE_PUBLIC_KEYS`, with the **same public
  key** as the backup of the-grid (`nodes/the-grid/backup/`). The private key is in Bitwarden, in
  the secure note **"age — backup dvb the-grid"**. Since 2026-10-02, it is also in offline copies outside
  the vault (details in `nodes/the-grid/backup/README.md`). If all the key copies are lost, the
  offsite backup copies are unreadable.
- The offsite archives have the name `arcade-volumes-<data>.tar.gz.age` and the header
  `age-encryption.org/v1`. the-grid receives them already encrypted. It cannot decrypt them.
- **`dvb-local` stays unencrypted on purpose.** It is on S:, the same disk as the data and the
  original `.env`, so encryption protects nothing more. In exchange, `Test-BackupContent.ps1` can
  still check the content of the local archive. For the remote archives, it checks only that the
  last archive is encrypted (header). This holds until `S:\Bakcup_Servarr+` is synchronized to a
  cloud. Then encrypt the local archive too.
- The retention compares only the prefix (`arcade-volumes-`). It prunes the old unencrypted
  `.tar.gz` files and the new `.age` files together.
- **Test round of 2026-10-02 at 03:53** (`docker exec dvb-remote-scope backup`, container removed on 2026-10-11): the round took
  **3.5 min** in total. The steps took: tar 29 s with cleanuparr stopped, encryption 4 s, upload
  3 min. The `.age` archive was 2.4 GB. `Test-BackupContent.ps1 -CheckRemote` verified the header.
- **The test restore on 2026-10-02 was successful.** It used the the-grid archive (manual round at
  04:26, 48 s). The hash was identical to the expected hash. The archive was decrypted with the key from Bitwarden.
  `tar` returned exit 0 and listed 2711 entries.
- The archive on the scope from 03:53 **does not decrypt**. The scope corrupted writes because of
  undervoltage (`PROBLEMI-E-SOLUZIONI.md` §11.5, `STATO-scope.md` 7.8). The reliable offsite copy is
  the copy on the-grid.
- ⚠️ Run `Test-BackupContent.ps1` from **PowerShell**, not from Git Bash. In Git Bash, `tar.exe`
  resolves to the GNU tar of Git. This tar reads `S:\…` as a remote `host:path`, and it gives a
  false "corrupted gzip" message.
- **To restore** an offsite archive, use the same procedure as for the-grid
  (`nodes/the-grid/backup/README.md`, section *Restore*). Only the name of the file changes.
  The decrypted `.tar.gz` contains the secrets. Remove the directory at the end of the work.

**These items are NOT in the backup, on purpose:**

- The Immich photo library (B:\immich-library).
- The volume `immich_immich-pgdata`. The official dumps replace it.
- `immich_immich-model-cache`.
- Anonymous volumes.

**REMOVED on 2026-09-05 and 2026-09-13:** caddy-data/config, crowdsec-data/config,
paperless-pgdata/redisdata, hermes-home/workspace and caddy-conf (bind `S:/caddy`). Caddy,
CrowdSec, Paperless and Hermes were removed or migrated to the-grid. `nodes/the-grid/backup/`
covers their live data (bind on `/srv/docker`). This stack does not cover them. For the detail of
each removal, read the dated comments in `docker-compose.yml`.

## Deploy

```powershell
cd "S:\github\homelab\stacks\volume-backup"
docker compose config --quiet  # checks the parsing of the paths with spaces (NEVER without --quiet: it prints the token of the bot)
docker compose up -d dvb-local # only the local one until SSH is ready
docker logs -f dvb-local
```

## Manual test

```powershell
docker exec dvb-local backup
```

Check the content without extracting the archive:

```powershell
$ultimo = Get-ChildItem "S:\Bakcup_Servarr+\Docker Volumes\arcade-volumes-*.tar.gz" |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
tar -tzf $ultimo.FullName | Select-Object -First 40
```

## Restore

The archive is a normal `tar.gz`. You need no proprietary tool.

**Docker volume.** No Docker volume is among the sources of this stack at the moment. The
procedure stays valid if someone adds a volume in the future. Read the comment
"SOURCES TO ADD" at the bottom of `docker-compose.yml`. Use this procedure to restore a
Docker volume:

```powershell
# 1. stop the container that uses the volume
docker stop CONTAINERNAME

# 2. extract the content into the volume
docker run --rm `
  -v VOLUMENAME:/restore `
  -v "S:\Bakcup_Servarr+\Docker Volumes:/archive:ro" `
  alpine sh -c "cd /restore && tar -xzf /archive/FILENAME.tar.gz --strip-components=2 backup/SOURCENAME"

# 3. restart
docker start CONTAINERNAME
```

**Bind mount:** extract the tar.gz. Then copy the subdirectory `backup/<nome>` onto the original path.

**Immich DB:** Do NOT restore it from the volume. Use the official dump, with the procedure at
https://docs.immich.app (Administration → Maintenance → Restore database backup). You can also use
`psql` from the CLI.

## Notes

- The two containers are separate on purpose. They are two distinct failure domains.
- `BACKUP_PRUNING_PREFIX` is mandatory. Without it, the pruning removes any old file in the
  destination directory.
- `.gitignore` lists the `.env` files and the `ssh/` directory. They contain bot tokens and private keys.
- Every remote SSH key (today only the-grid) is dedicated. The recipient authorizes it with the prefix
  `restrict` (no pty, no port forwarding, no X11, no agent forwarding). This follows the principle
  of least privilege. The fleet uses the same pattern for all the automatic backup keys.
