<#
.SYNOPSIS
    Register the Scheduled Task Servarr-Backup (daily copy of the Servarr
    configuration to S:\Bakcup_Servarr+).

.DESCRIPTION
    The task runs Invoke-ServarrBackup.vbs as Faginux, with limited rights, at
    06:45 each day. The time comes from the inventory of 2026-11-26
    (CALENDARIO-OPERAZIONI.md): after the Plex maintenance (03:00 to 05:00), after
    the-grid-BackupPull (05:40) and after dvb-remote-the-grid (Sunday 06:00).

    The start time has no UTC offset, so the task follows summer and winter time
    (see tools/scheduled-task-local-time).

    -Disabled registers the task turned off. The bootstrap of the new ISO uses it:
    on a new system a run before the restore can write new empty settings over
    the good backups. Faginux turns the task on after the restore.

    Compatible with Windows PowerShell 5.1 (the bootstrap of the ISO).
    Use -WhatIf to see the task without a change. Run it again to update the task.

.EXAMPLE
    pwsh -NoProfile -File .\Register-ServarrBackupTask.ps1 -WhatIf
.EXAMPLE
    powershell.exe -NoProfile -File .\Register-ServarrBackupTask.ps1 -UserName 'ARCADE\ops' -Disabled
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'Servarr-Backup',

    # Write the full name: the bare name is also the name of the computer.
    [string]$UserName = ('{0}\{1}' -f $env:COMPUTERNAME, $env:USERNAME),

    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$RunAt = '06:45',

    [switch]$Disabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Invoke-ServarrBackup.vbs'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $launcher)
$start = [datetime]::Today.Add([timespan]::Parse($RunAt))
$trigger = New-ScheduledTaskTrigger -Daily -At $start
# New-ScheduledTaskTrigger writes a UTC offset. Without the offset the task follows the local time.
$trigger.StartBoundary = $start.ToString('s')
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
# 2 hours: the first run copies about 11 GB of Plex data. The next runs copy only the changes.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
if ($Disabled) { $settings.Enabled = $false }

"Task:     $TaskName"
"User:     $UserName (limited)"
"Schedule: daily at $RunAt (start $($trigger.StartBoundary))"
"Action:   wscript.exe `"$launcher`""
"Enabled:  $(-not $Disabled)"

if ($PSCmdlet.ShouldProcess($TaskName, 'Register the Scheduled Task')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force `
        -Description 'Copia la configurazione di Radarr, Sonarr, Prowlarr, qBittorrent e Plex in S:\Bakcup_Servarr+ (tools/servarr-backup).' |
        Out-Null
    $task = Get-ScheduledTask -TaskName $TaskName
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    "Registered. State: $($task.State). Next run: $($info.NextRunTime)"
}
