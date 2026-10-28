# disk-space-check

A Scheduled Task of ARCADE that sends a Telegram message when S: has too little free
space. S: holds the game library and the torrents of qBittorrent (since 2026-10-16). On
2026-10-25 S: had only 36 GB free, after the downloads of about 20 films on 2026-10-20.

## What it does

`Invoke-DiskSpaceCheck.ps1` reads the free space of S: and finds a level:

| Level | Condition | Message |
|---|---|---|
| ok | free space 220 GB or more, or the last level was ok and free space is 200 GB or more | `✅` when the level goes back to ok |
| warning | free space less than 200 GB | `⚠️` when the level goes from ok to warning |
| critical | free space less than 100 GB | `🚨` when the level goes to critical |

- The script sends one message for each change of level, not for each run.
- The return to ok needs 220 GB, not 200 GB. The difference of 20 GB stops a series of
  messages when the free space moves near 200 GB (a download starts, a torrent goes).
- A change from critical to warning sends no message. The next message is the return to ok.
- The warning and critical messages tell the size of the qBittorrent torrents on S:. The
  script reads them from the API on `localhost:8082` (read only, no credentials).
- The state (`state-S.json`) and the log (`check.ndjson`) are in
  `%LOCALAPPDATA%\homelab\disk-space-check`, on C:. On a full S:, a write to S: fails at
  the time when the message is necessary.
- The log has a line only for a change of level or a message. A run with no change writes
  nothing. To see if the task runs, read `LastRunTime` and `LastTaskResult` of the task.
- If Telegram fails, the state does not change. The next run tries again (30 minutes later).
- The script is on S:. If S: is not available, the task cannot start and `LastTaskResult`
  is not 0. The level `missing` works only for a drive that does not hold the script.

The bot is the shared "Ops" bot (`S:\Scripts\Tmm\telegram.config.psd1`), as for
`tools/glances-lhm`. The text of the messages is in Italian, in the uniform format.

## Why not Beszel or Glances

- Beszel: the agent runs on ARCADE, but its "Disk" limit is a percentage and it is the
  maximum of all the file systems (`PROBLEMI-E-SOLUZIONI.md` §12.6). 200 GB free on S: is 78.5%
  used, and D:, G: and H: are already above that. The hub is on the scope, which is in downgrade.
- Glances: the limits are percentages and Glances has no Telegram.

## Schedule

Scheduled Task `DiskSpace-Check`: every 30 minutes, at :23 and :53. The user is Faginux,
`Interactive` and `Limited`, like the other tasks. A run takes 0.5 s (measured on
2026-10-25, with the start of pwsh). The start time has no UTC offset, so the task follows
summer and winter time (`PROBLEMI-E-SOLUZIONI.md` §13.7). Read `CALENDARIO-OPERAZIONI.md`.

Why 30 minutes: a fast download can fill 100 GB in less than one hour. A shorter interval
gives no help, because Faginux cannot always answer in minutes.

## Install and test

```powershell
$dir = 'S:\github\homelab\tools\disk-space-check'
pwsh -NoProfile -File "$dir\Invoke-DiskSpaceCheck.ps1" -NoSend                          # level now, no Telegram
pwsh -NoProfile -File "$dir\Invoke-DiskSpaceCheck.ps1" -NoSend -WarningGB 300 -ClearGB 320  # see the warning text
pwsh -NoProfile -File "$dir\Register-DiskSpaceCheck.ps1" -WhatIf                        # see the task, no change
pwsh -NoProfile -File "$dir\Register-DiskSpaceCheck.ps1"                                # register or update the task
```

`-NoSend` prints the level and the message and does not change the state. `-Force` sends the
message of the current level, also if the script sent it before.

To change the limits, add `-WarningGB`, `-CriticalGB` and `-ClearGB` to the command line in
`Invoke-DiskSpaceCheck.vbs`. The rule is `CriticalGB < WarningGB <= ClearGB`.

## Remove

```powershell
Unregister-ScheduledTask -TaskName 'DiskSpace-Check' -Confirm:$false
Remove-Item -Recurse -LiteralPath (Join-Path $env:LOCALAPPDATA 'homelab\disk-space-check')
```

## Verified on 2026-10-25

- `-NoSend` with the real limits: 259 GB free, level ok, no message.
- `-NoSend` with test limits: the warning and critical texts, the torrent size (511 GB,
  20 torrents), the return text and the text for a drive that does not exist.
- The return to ok: with the last level warning and 259 GB free, the level stays warning when
  `ClearGB` is 270, and it goes to ok when `ClearGB` is 255. Critical to warning: no message.
- Task registered, one run started by hand: `LastTaskResult` 0, no state file (no change).
