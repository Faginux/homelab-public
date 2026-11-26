# servarr-backup

Daily copy of the configuration of Radarr, Sonarr, Prowlarr, qBittorrent and Plex from
ARCADE to `S:\Bakcup_Servarr+`. The Scheduled Task `Servarr-Backup` runs it at 06:45.

Written on 2026-11-26. Before this tool, the copies in `S:\Bakcup_Servarr+` were from
2026-01-12, and no job made new ones. The backup zip files of the arr apps were only on C:.

## Files

| File | Use |
|---|---|
| `Invoke-ServarrBackup.ps1` | The copy, the age checks and the Telegram alert. Windows PowerShell 5.1 or 7. |
| `Invoke-ServarrBackup.vbs` | The launcher of the task. No console window. It starts the `.ps1` from its own folder with `powershell.exe`. |
| `Register-ServarrBackupTask.ps1` | Registers the task. `-Disabled` registers it turned off (new ISO). |

## What the script copies

| Item | Source | Target in `S:\Bakcup_Servarr+` |
|---|---|---|
| Radarr, Sonarr, Prowlarr | `C:\ProgramData\<app>\Backups\*.zip` (the backups that each app makes) | `<app>\Backups` |
| qBittorrent settings | `%APPDATA%\qBittorrent` (not `lockfile`) | `qBittorrent\Roaming` |
| qBittorrent torrent state | `%LOCALAPPDATA%\qBittorrent` (not `cache`, `logs`, `GeoDB`) | `qBittorrent\Local` |
| Plex data | `%LOCALAPPDATA%\Plex Media Server` (not `Cache`, `Codecs`, `Crash Reports`, `Diagnostics`, `Drivers`, `Logs`, `Updates`, not the open database files) | `Plex` |
| Plex settings | Registry key `HKCU\Software\Plex, Inc.\Plex Media Server` | `Plex\registry\plex-registry-<date>.reg` |

Plex writes its own database copies to `S:\Plex_Backup` (setting `ButlerDatabaseBackupPath`), each
3 days in its maintenance window. The script does not copy the open database: a copy while Plex
runs can be broken.

The `.reg` file holds the Plex token. It stays on S:, with the other backups of this folder.

## Rules

- The script never deletes a file in the target. The only exception: it keeps the 14 newest
  `.reg` files. It does not use `robocopy /MIR` or `/PURGE`. With an empty source (a new system
  before the restore), a mirror deletes the good backups.
- A missing source folder is a problem, and the script reports it.
- The script checks the age of the newest arr zip (limit 10 days, because Radarr makes a
  scheduled backup each 7 days) and of the newest Plex database copy in `S:\Plex_Backup`
  (limit 5 days).
- Telegram (shared "Ops" bot, `S:\Scripts\Tmm\telegram.config.psd1`): only when there is a
  problem. The message repeats at each run while the problem stays.
- Log: one JSON line for each run in `S:\Bakcup_Servarr+\servarr-backup.ndjson`.
- Exit code: 0 with no problem, 1 with a problem (`LastTaskResult` of the task).

## Schedule

Daily at 06:45, local time (`StartBoundary` with no UTC offset). Inventory of 2026-11-26
(`CALENDARIO-OPERAZIONI.md`): after the Plex maintenance (03:00 to 05:00, the database copy at
about 03:04), after `the-grid-BackupPull` (05:40) and after `dvb-remote-the-grid` (Sunday 06:00). The
minute is free: the TMM watcher uses even minutes, other tasks use :07, :23 and :53.

Measured on 2026-11-26 on ARCADE (S: is an NVMe SSD):

| Run | Copied | Time |
|---|---|---|
| First run | 26,490 files, 10.6 GB (Plex metadata) | 45.5 s |
| Next run, no change | 0 files | 13 s |
| Task start from Task Scheduler | 0 files | 12.9 s, `LastTaskResult` 0 |

## Install and tests

```powershell
# Register or update the task (as Faginux, limited rights, 06:45)
pwsh -NoProfile -File S:\github\homelab\tools\servarr-backup\Register-ServarrBackupTask.ps1

# Tests
powershell.exe -NoProfile -File .\Invoke-ServarrBackup.ps1 -DryRun     # robocopy /L, no copy, no Telegram, no log line
powershell.exe -NoProfile -File .\Invoke-ServarrBackup.ps1 -NoSend     # real copy, no Telegram
powershell.exe -NoProfile -File .\Invoke-ServarrBackup.ps1 -SendTest   # one test message

# Remove the task (the copies on S: stay)
Unregister-ScheduledTask -TaskName Servarr-Backup -Confirm:$false
```

## New ISO

The payload of the ISO gets this folder, and `bootstrap.ps1` registers the task with
`-Disabled`. On a new system, a run before the restore can write new empty settings (for example
a new `qBittorrent.ini`) over the good copies. Faginux turns the task on after the restore. Claude
does this part in the session of 2026-12-02 (tracker, `pc-e-media`, item "ISO: backups").
