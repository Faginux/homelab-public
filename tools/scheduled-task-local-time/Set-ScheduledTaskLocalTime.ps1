<#
.SYNOPSIS
    Make the time triggers of the homelab Scheduled Tasks follow the local time of ARCADE.

.DESCRIPTION
    New-ScheduledTaskTrigger -At writes the start time with a UTC offset, for example
    2026-09-30T08:20:00+01:00. Task Scheduler then uses this offset and ignores daylight
    saving time. Thus a task made in summer runs one hour early in winter. A start time
    without an offset follows the time zone and the daylight saving time of the computer
    (Microsoft Learn, ITrigger::put_StartBoundary).

    For each trigger with an offset, the script writes the same time without the offset.
    The time is the local time of the first start, on the date of the first start. Thus
    a task made at 09:20 in summer runs at 09:20 in summer and in winter.

    Dry run by default: the script shows the change and writes nothing.
    -Apply       writes the change and saves the old values in a JSON file.
    -RestoreFrom writes the old values of that JSON file again (rollback).

.EXAMPLE
    pwsh -NoProfile -File .\Set-ScheduledTaskLocalTime.ps1
.EXAMPLE
    pwsh -NoProfile -File .\Set-ScheduledTaskLocalTime.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string[]]$TaskName = @('QbitCompat-Check', 'Compose-Drift-Check', 'the-grid-BackupPull',
        'Glances-LhmUpdateCheck', 'Kometa-Nightly', 'TMM-Plex-Watcher'),

    [string]$BackupDir = (Join-Path $env:LOCALAPPDATA 'homelab\scheduled-task-local-time'),

    [string]$RestoreFrom,

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-TriggerStart {
    <# Write new start times into the triggers of one task. Each change is a hashtable with Trigger and Value. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Change
    )
    $task = Get-ScheduledTask -TaskName $Name
    $triggers = @($task.Triggers)
    foreach ($item in $Change) { $triggers[[int]$item.Trigger].StartBoundary = [string]$item.Value }
    # The bare user name is also the name of the computer, and Set-ScheduledTask refuses it
    # ("(22,8):UserId:"). Write the full name: it is the same user.
    if ($task.Principal.UserId -and $task.Principal.UserId -notmatch '\\') {
        $task.Principal.UserId = '{0}\{1}' -f $env:COMPUTERNAME, $task.Principal.UserId
    }
    Set-ScheduledTask -InputObject $task | Out-Null
}

# Rollback: write the old values of a backup file again.
if ($RestoreFrom) {
    $entries = @(Get-Content -LiteralPath $RestoreFrom -Raw | ConvertFrom-Json)
    foreach ($group in ($entries | Group-Object Task)) {
        $change = @($group.Group | ForEach-Object { @{ Trigger = $_.Trigger; Value = $_.Old } })
        if ($Apply) { Set-TriggerStart -Name $group.Name -Change $change }
        $group.Group | ForEach-Object { [pscustomobject]@{ Task = $_.Task; Trigger = $_.Trigger; Restore = $_.Old; Applied = [bool]$Apply } }
    }
    if (-not $Apply) { Write-Host 'Dry run: nothing written. Add -Apply to restore.' }
    return
}

$plan = foreach ($name in $TaskName) {
    $task = Get-ScheduledTask -TaskName $name
    $triggers = @($task.Triggers)
    for ($index = 0; $index -lt $triggers.Count; $index++) {
        $old = [string]$triggers[$index].StartBoundary
        # Only a start time with "Z" or "+HH:MM" / "-HH:MM" at the end follows UTC.
        if (-not $old -or $old -notmatch '(Z|[+-]\d{2}:\d{2})$') { continue }
        $new = [DateTimeOffset]::Parse($old, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime.ToString('s')
        [pscustomobject]@{ Task = $name; Trigger = $index; Old = $old; New = $new }
    }
}
$plan = @($plan)

if ($plan.Count -eq 0) {
    Write-Host 'No trigger with a UTC offset: nothing to do.'
    return
}
$plan | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if (-not $Apply) {
    Write-Host 'Dry run: nothing written. Add -Apply to write the change.'
    return
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$backupFile = Join-Path $BackupDir ('backup-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$plan | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $backupFile -Encoding utf8
Write-Host "Old values saved in $backupFile"

foreach ($group in ($plan | Group-Object Task)) {
    Set-TriggerStart -Name $group.Name -Change @($group.Group | ForEach-Object { @{ Trigger = $_.Trigger; Value = $_.New } })
}

# Read back: the start time and the next run of each task.
foreach ($name in ($plan.Task | Select-Object -Unique)) {
    $task = Get-ScheduledTask -TaskName $name
    [pscustomobject]@{
        Task          = $name
        StartBoundary = (@($task.Triggers) | ForEach-Object { $_.StartBoundary }) -join ' ; '
        NextRunTime   = (Get-ScheduledTaskInfo -TaskName $name).NextRunTime
    }
}
