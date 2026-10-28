# the-grid-backup-pull — the backups of the-grid on ARCADE

Every morning, ARCADE **downloads** the encrypted archives that the-grid produces. This started on
2026-10-02 (`PIANO-DECLASSAMENTO-scope.md`, Part A). The download replaces, as the offsite copy of
the-grid, `dvb-remote-scope`. That service wrote to an scope that corrupts writes
(`PROBLEMI-E-SOLUZIONI.md` §11.5).

## Why pull and not push

With push, the-grid (the public edge) has a key that enters ARCADE. With pull, ARCADE enters
the-grid with a user that can only **read encrypted archives**.

A person who compromises the-grid gets nothing toward ARCADE. A person who steals the key of
ARCADE cannot enter from any other IP. That person can read only `.age` files.

The archives already exist (`dvb-local`). There is no second tar/gzip/age on the-grid.

## The parts

| Where | What | Versioned in |
|---|---|---|
| the-grid | user `v4pull`, `nologin`, password `*`, home `/var/lib/v4pull` (outside the chroot) | — (commands in `PIANO-DECLASSAMENTO-scope.md` A.1) |
| the-grid | `Match User v4pull`: chroot `/srv/backup`, `internal-sftp -R`, no TTY/forwarding | `nodes/the-grid/sshd/20-v4pull.conf` |
| the-grid | `authorized_keys` of root, `restrict,from="192.0.2.10,198.51.100.10"` | — |
| the-grid | `backup-sha256-manifest.timer` (03:40). It writes `<archivio>.sha256` next to each archive. | `nodes/the-grid/systemd/` |
| ARCADE | key `~/.ssh/id_ed25519_the-grid_pull`. It has no passphrase, because the job runs without supervision. | — |
| ARCADE | `Invoke-TheGridBackupPull.ps1` + `.vbs`, Scheduled Task `the-grid-BackupPull` (05:40) | This directory |

The fingerprint of the pull key is `SHA256:DRB2/aTt3uvAHLbNo9Xj5GexDE87Rxwa3D7F0ejX/I4`.

## What the script does

| Source on the-grid (chroot) | Destination on ARCADE | File |
|---|---|---|
| `/docker-volumes` | `S:\Bakcup_Servarr+\from-the-grid\docker-volumes` | `the-grid-volumes-*.tar.gz.age` |
| `/bitwarden-dumps`. This is from Part B. The script skips it until it exists. | `S:\Bakcup_Servarr+\bitwarden` | `bitwarden_vault_*.sql.gz` |

1. The script lists the remote files. It downloads only the files that are missing **and** already
   have the `.sha256`.
2. The script downloads each file as `.partial`. It renames the file only if the SHA-256 matches
   and the header is `age-encryption.org/v1` or the gzip magic. The `.sha256` stays next to the
   archive on ARCADE too.
3. The script keeps the archives for 36 days. the-grid keeps them for 29 days. The script **never
   deletes the most recent archive**.
4. The script sends a Telegram message only if something is wrong. It uses the shared bot. The
   configuration is in `S:\Scripts\Tmm\telegram.config.psd1`. Nobody reads this file on the
   screen. These cases send a message:
   - A download or a verification failed.
   - A remote archive still has no `.sha256` after more than 3 hours.
   - The most recent archive is older than 5 days (8 days for the Bitwarden dumps).
   - the-grid is unreachable.

   The script sends the message again on every round while the problem remains.
5. The script writes a log of every round in
   `S:\Bakcup_Servarr+\from-the-grid\the-grid-backup-pull.ndjson`.

Non-obvious choices:

- **The script downloads only `*.tar.gz.age`.** `/docker-volumes` still contains the unencrypted
  archives from before 2026-09-23 (inside `_secrets/`). The script never downloads them. The
  retention of the-grid deletes them by 2026-10-21.
- **The script reads the age of an archive from the file name**, not from the file date. `sftp get`
  does not keep the file date.
- **The script does not download again** an archive that is already outside the retention of
  ARCADE. This rule is for the case that the-grid keeps the archive longer one day.
- **The script uses the LAN first, then Tailscale.** On the fallback, the option
  `HostKeyAlias=192.0.2.20` verifies the connection against the host key that is already
  trusted for the LAN. This adds no new entry in `known_hosts`. The `ssh-keyscan` of Windows cannot
  even read this key (`PROBLEMI-E-SOLUZIONI.md` §4.8).
- **The `.sha256` proves only that the copy is identical.** The decryption shows whether the
  archive is restorable. For the procedure, read the section *Restore* in
  `nodes/the-grid/backup/README.md`. Use the file that is already on ARCADE instead of
  the `scp`.

## Test

```powershell
$s = 'S:\github\homelab\tools\the-grid-backup-pull\Invoke-TheGridBackupPull.ps1'
pwsh -NoProfile -File $s -SelfTest   # parses the names and the retention, no network
pwsh -NoProfile -File $s -DryRun     # lists and decides, no download, no delete, no alert
pwsh -NoProfile -File $s -NoSend     # real run without Telegram
pwsh -NoProfile -File $s -SendTest   # test message to the bot
```

## Scheduled Task

```powershell
$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '"S:\github\homelab\tools\the-grid-backup-pull\Invoke-TheGridBackupPull.vbs"'
$trigger  = New-ScheduledTaskTrigger -Daily -At '05:40'
$trigger.StartBoundary = ([datetime]::Today.AddHours(5).AddMinutes(40)).ToString('s')   # no UTC offset: follow summer and winter time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'the-grid-BackupPull' -Action $action -Trigger $trigger -Settings $settings -Description 'Pull dei backup cifrati di the-grid (PIANO-DECLASSAMENTO-scope.md, A.4)'
```

The task uses the user of Faginux, `Interactive` and `Limited`, like the other tasks. The task starts
at 05:40. This is after the Plex maintenance (until 05:00). Until 2026-10-11, it was also after
`dvb-remote-scope` on ARCADE (Sunday 05:00). That container does not exist now. The task is 20
minutes before `dvb-remote-the-grid` (Sunday 06:00). Read `CALENDARIO-OPERAZIONI.md` for details.

`New-ScheduledTaskTrigger -At` writes the start time with a UTC offset. With an offset, the task
does not follow winter time. On 2026-10-25 the task ran at 04:40, in the Plex maintenance. The
line `$trigger.StartBoundary = ...` writes the start time without the offset. The fix of the real task:
`tools/scheduled-task-local-time/Set-ScheduledTaskLocalTime.ps1` (2026-10-25).

## Verified on 2026-10-02

| Test | Result |
|---|---|
| Negative tests on the-grid | the-grid refused the shell (`This service allows sftp connections only.`). the-grid refused the key for the user `ops`. `put`, `mkdir` and `rm` gave `Permission denied`. `cd /..` stayed in `/`. |
| First real round | The script downloaded 4 archives, about 1.7 GB, in **11 s**. It verified all of them. |
| Second round | The round took 1 s. There was nothing to download. |
| Tailscale fallback | `pwd` succeeded with `HostKeyAlias`. |
| Restore (A.5) | The pull downloaded the archive of 2026-10-02. The archive was decrypted with the offline copy of the key. `tar -tzf` listed **3896 entries**, with no errors. |
