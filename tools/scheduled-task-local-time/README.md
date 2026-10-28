# scheduled-task-local-time

`Set-ScheduledTaskLocalTime.ps1` makes the time triggers of the homelab Scheduled Tasks of
ARCADE follow the local time (Europe/Rome, with summer and winter time).

## The problem

`New-ScheduledTaskTrigger -At` writes the start time with a UTC offset, for example
`2026-09-30T08:20:00+01:00`. With an offset (or `Z`), Task Scheduler always uses that time and
ignores the time zone and the daylight saving time of the computer. Without an offset
(`2026-09-30T09:20:00`), it uses the local time (Microsoft Learn, `ITrigger::put_StartBoundary`).

On 2026-10-25, the first day of winter time, the tasks ran one hour early. `the-grid-BackupPull` ran
at 04:40, in the Plex maintenance (03:00-05:00). Details: `PROBLEMI-E-SOLUZIONI.md` §13.7.

## What the script does

For each trigger with an offset, the script writes the same time without the offset. The time is
the local time of the first start, on the date of the first start. A task made at 09:20 in
summer thus runs at 09:20 all the year.

- Dry run by default: the script shows a table (`Old`, `New`) and writes nothing.
- `-Apply` saves the old values in `%LOCALAPPDATA%\homelab\scheduled-task-local-time\backup-<time>.json`,
  writes the change, then shows `StartBoundary` and `NextRunTime` of each task.
- `-RestoreFrom <file> -Apply` writes the old values again (rollback).
- A trigger without an offset does not change. A second run thus does nothing.
- The default list has the 6 homelab tasks with a time trigger: `QbitCompat-Check`,
  `Compose-Drift-Check`, `the-grid-BackupPull`, `Glances-LhmUpdateCheck`, `Kometa-Nightly` and
  `TMM-Plex-Watcher`. `-TaskName` sets a different list.

`Set-ScheduledTask -InputObject` refuses the bare user name `arcade`, because it is also the
name of the computer (error `(22,8):UserId:`). The script writes the full name
`ARCADE\arcade`. It is the same user.

```powershell
$s = 'S:\github\homelab\tools\scheduled-task-local-time\Set-ScheduledTaskLocalTime.ps1'
pwsh -NoProfile -File $s           # dry run
pwsh -NoProfile -File $s -Apply    # write
```

## For a new task

After `New-ScheduledTaskTrigger -At $start`, write the start time without the offset:

```powershell
$trigger.StartBoundary = $start.ToString('s')
```

`tools/disk-space-check/Register-DiskSpaceCheck.ps1` and
`tools/glances-lhm/Register-GlancesLhmUpdateCheck.ps1` do this.

## Applied on 2026-10-25

With the OK of Faginux, on the 6 tasks. The next runs read back: `QbitCompat-Check` 09:20,
`Compose-Drift-Check` 21:10, `the-grid-BackupPull` 05:40, `Kometa-Nightly` 00:30,
`Glances-LhmUpdateCheck` at :07 every 6 hours, `TMM-Plex-Watcher` every 2 minutes. The user,
the logon type (`Interactive`), the run level (`Limited`) and the actions did not change.
