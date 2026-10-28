<#
.SYNOPSIS
    Register the Scheduled Task that runs Invoke-DiskSpaceCheck.ps1 every 30 minutes.

.DESCRIPTION
    The task runs as Faginux with limited rights (the script only reads). It starts at
    00:23 and repeats every 30 minutes: at :23 and :53 of each hour. No other task of
    ARCADE starts at these minutes (checked on 2026-10-25): the TMM watcher runs
    on even minutes, qbit_manage on minutes that end in 7, the other tasks at :07,
    :20, :30, :40 and :10.

    The start time has no UTC offset, so the task follows summer and winter time
    (see tools/scheduled-task-local-time).
    Use -WhatIf to see the task without a change. Run it again to update the task.

.EXAMPLE
    pwsh -NoProfile -File .\Register-DiskSpaceCheck.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'DiskSpace-Check',

    # Write the full name: the bare name is also the name of the computer.
    [string]$UserName = 'ARCADE\arcade',

    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$FirstRun = '00:23',

    [int]$EveryMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Invoke-DiskSpaceCheck.vbs'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}

$firstStart = [datetime]::Today.Add([timespan]::Parse($FirstRun))
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $launcher)
$trigger = New-ScheduledTaskTrigger -Once -At $firstStart `
    -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
# New-ScheduledTaskTrigger writes a UTC offset. Without the offset the task follows the local time.
$trigger.StartBoundary = $firstStart.ToString('s')
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Write-Host "Task:     $TaskName"
Write-Host "User:     $UserName (limited)"
Write-Host "Schedule: from $FirstRun, every $EveryMinutes minutes (start $($trigger.StartBoundary))"
Write-Host "Action:   wscript.exe `"$launcher`""

if ($PSCmdlet.ShouldProcess($TaskName, 'Register the Scheduled Task')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Tell Faginux on Telegram when S: has less than 200 GB free (tools/disk-space-check).' `
        -Force | Out-Null
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "Registered. Next run: $($info.NextRunTime)"
}
