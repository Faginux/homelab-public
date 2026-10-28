<#
.SYNOPSIS
    Register the Scheduled Task that runs Invoke-GlancesLhmUpdateCheck.ps1 every 6 hours.

.DESCRIPTION
    The task runs as Faginux with limited rights (the script only reads). It starts at
    00:07 and repeats every 6 hours: 00:07, 06:07, 12:07 and 18:07. No other task of
    ARCADE starts at these times (checked on 2026-10-15).
    Use -WhatIf to see the task without a change. Run it again to update the task.

.EXAMPLE
    pwsh -NoProfile -File .\Register-GlancesLhmUpdateCheck.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'Glances-LhmUpdateCheck',

    # Write the full name: the bare name is also the name of the computer.
    [string]$UserName = 'ARCADE\arcade',

    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$FirstRun = '00:07',

    [int]$EveryHours = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Invoke-GlancesLhmUpdateCheck.vbs'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found: $launcher"
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $launcher)
$firstStart = [datetime]::Today.Add([timespan]::Parse($FirstRun))
$trigger = New-ScheduledTaskTrigger -Once -At $firstStart `
    -RepetitionInterval (New-TimeSpan -Hours $EveryHours) -RepetitionDuration (New-TimeSpan -Days 3650)
# New-ScheduledTaskTrigger writes a UTC offset, and with it the task does not follow winter time
# (found on 2026-10-25). A start time without an offset follows the local time.
$trigger.StartBoundary = $firstStart.ToString('s')
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Write-Host "Task:     $TaskName"
Write-Host "User:     $UserName (limited)"
Write-Host "Schedule: from $FirstRun, every $EveryHours hours"
Write-Host "Action:   wscript.exe `"$launcher`""

if ($PSCmdlet.ShouldProcess($TaskName, 'Register the Scheduled Task')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Tell Faginux on Telegram when LibreHardwareMonitor changed and the copy of Glances is old (tools/glances-lhm).' `
        -Force | Out-Null
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "Registered. Next run: $($info.NextRunTime)"
}
