<#
.SYNOPSIS
    Register the Scheduled Task that runs Set-ImmichMlQueue.ps1 -State Auto -Apply
    at 07:30 and at 22:30.

.DESCRIPTION
    The task runs as Faginux with limited rights. At 07:30 it pauses the ML queues of
    Immich, at 22:30 it resumes them (PLAN-LOCAL-LLM.md, M1b-B). The script uses
    -State Auto, so a late run (StartWhenAvailable, after a boot) also gives the
    correct state. No other task of ARCADE starts near these times (inventory of
    the three hosts on 2026-11-07, CALENDARIO-OPERAZIONI.md).

    The start times have no UTC offset, so the task follows summer and winter time
    (see tools/scheduled-task-local-time).
    Use -WhatIf to see the task without a change. Run it again to update the task.

.EXAMPLE
    pwsh -NoProfile -File .\Register-ImmichMlQueueWindow.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'Immich-MlQueueWindow',

    # Write the full name: the bare name is also the name of the computer.
    [string]$UserName = 'ARCADE\arcade',

    # Keep these times equal to DayStart and DayEnd in the settings file.
    [ValidatePattern('^\d{2}:\d{2}$')]
    [string[]]$RunAt = @('07:30', '22:30')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Set-ImmichMlQueue.vbs'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $launcher)
$triggers = foreach ($time in $RunAt) {
    $start = [datetime]::Today.Add([timespan]::Parse($time))
    $trigger = New-ScheduledTaskTrigger -Daily -At $start
    # New-ScheduledTaskTrigger writes a UTC offset. Without the offset the task follows the local time.
    $trigger.StartBoundary = $start.ToString('s')
    $trigger
}
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
# 5 minutes: the script tries 3 times, with 60 s between the tries.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

"Task:     $TaskName"
"User:     $UserName (limited)"
# Member access, not ForEach-Object: with -WhatIf, ForEach-Object asks ShouldProcess for each value.
"Schedule: daily at $($RunAt -join ' and ') (start $($triggers.StartBoundary -join ', '))"
"Action:   wscript.exe `"$launcher`""

if ($PSCmdlet.ShouldProcess($TaskName, 'Register the Scheduled Task')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
        -Settings $settings -Force `
        -Description 'Pause the ML queues of Immich in the day, resume them at night (tools/immich-queue-window).' |
        Out-Null
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    "Registered. Next run: $($info.NextRunTime)"
}
