#Requires -Version 7.0
<#
  Set-ImmichMlQueue.ps1  -  v1.0  (2026-11-07)
  Pauses or resumes the machine learning queues of Immich, so that the ML jobs
  run at night only. Step M1b-B of PLAN-LOCAL-LLM.md: in the day, the local LLM
  gets the VRAM of the GPU.

  Queues: smartSearch, faceDetection, facialRecognition and videoConversion.
  The other queues stay active: thumbnailGeneration and metadataExtraction (a new
  photo shows at once), and duplicateDetection (it uses the database, not the GPU).

  -State Paused    pause the four queues
  -State Active    resume the four queues
  -State Auto      Paused from DayStart to DayEnd (local time), Active in the
                   other hours. The Scheduled Task uses Auto: each run gives the
                   correct state, also a late run or two runs in the wrong order.

  Dry run by default: the script reads the queues and shows the change. With
  -Apply it changes the queues, reads them again and writes one line to the run
  log. Telegram (in Italian): only when an -Apply run fails.

  Settings (outside the repo, with no secret in them):
    ~/.config/immich-queue-window/settings.psd1
    BaseUrl, ApiKeyFile, TelegramConfigPath, RunLog, DayStart, DayEnd
  The API key needs only the permissions queue.read and queue.update. The script
  sends the key in the header x-api-key and never prints it.

  Created with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Paused', 'Active', 'Auto')]
    [string]$State,

    [switch]$Apply,

    [string]$SettingsPath = (Join-Path $HOME '.config\immich-queue-window\settings.psd1')
)

$ErrorActionPreference = 'Stop'

$Queues = @('smartSearch', 'faceDetection', 'facialRecognition', 'videoConversion')
# At a boot, the task can start before Docker Desktop and Immich are up.
# A dry run tries one time only.
$MaxAttempts   = if ($Apply) { 3 } else { 1 }
$RetryDelaySec = 60
$HostLabel     = "`u{1F5A5} ARCADE"

function Get-QueueWindowSetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Settings file not found: $Path" }
    $settings = Import-PowerShellDataFile -Path $Path
    foreach ($name in 'BaseUrl', 'ApiKeyFile', 'RunLog', 'DayStart', 'DayEnd') {
        if (-not $settings[$name]) { throw "The settings file has no value for '$name'." }
    }
    $settings
}

function Resolve-TargetState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Requested,
        [Parameter(Mandatory)][timespan]$DayStart,
        [Parameter(Mandatory)][timespan]$DayEnd,
        [Parameter(Mandatory)][datetime]$Now
    )
    if ($Requested -ne 'Auto') { return $Requested }
    # One minute ahead: a trigger that starts a little early (22:29:59) still
    # gets the state of the new window.
    $time = $Now.AddMinutes(1).TimeOfDay
    if ($time -ge $DayStart -and $time -lt $DayEnd) { 'Paused' } else { 'Active' }
}

function Invoke-ImmichQueue {
    <#
    .SYNOPSIS
        GET /api/queues/{name}, or PUT with {"isPaused": ...} when IsPaused is set.
        Both return the queue: isPaused and statistics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$Name,
        [Nullable[bool]]$IsPaused
    )
    $request = @{
        Uri        = '{0}/api/queues/{1}' -f $BaseUrl.TrimEnd('/'), $Name
        Headers    = @{ 'x-api-key' = $ApiKey }
        TimeoutSec = 15
    }
    if ($null -ne $IsPaused) {
        $request.Method      = 'Put'
        $request.ContentType = 'application/json'
        $request.Body        = @{ isPaused = [bool]$IsPaused } | ConvertTo-Json -Compress
    }
    Invoke-RestMethod @request
}

function Send-TelegramFailure {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ConfigPath,
        [Parameter(Mandatory)][string]$Text
    )
    if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath)) { return 'not-configured' }
    try {
        $telegram = Import-PowerShellDataFile -Path $ConfigPath
        $body = @{ chat_id = $telegram.ChatId; text = $Text } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($telegram.BotToken)/sendMessage" `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15
        'ok'
    }
    catch {
        # Do not keep the error text: it can contain the URL, and the URL contains the bot token.
        'error'
    }
}

function ConvertTo-StateName([bool]$IsPaused) { if ($IsPaused) { 'Paused' } else { 'Active' } }

$started    = Get-Date
$settings   = Get-QueueWindowSetting -Path $SettingsPath
$target     = Resolve-TargetState -Requested $State -DayStart ([timespan]$settings.DayStart) `
    -DayEnd ([timespan]$settings.DayEnd) -Now $started
$wantPaused = $target -eq 'Paused'
$apiKey     = (Get-Content -LiteralPath $settings.ApiKeyFile -Raw).Trim()
if (-not $apiKey) { throw "The API key file is empty: $($settings.ApiKeyFile)" }

$rows    = @()
$failure = $null
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
        $rows = foreach ($name in $Queues) {
            $before = Invoke-ImmichQueue -BaseUrl $settings.BaseUrl -ApiKey $apiKey -Name $name
            $after  = $before
            $action = 'none'
            if ([bool]$before.isPaused -ne $wantPaused) {
                if ($Apply) {
                    $null  = Invoke-ImmichQueue -BaseUrl $settings.BaseUrl -ApiKey $apiKey -Name $name -IsPaused $wantPaused
                    # Read the queue again: the PUT answer alone does not prove the new state.
                    $after = Invoke-ImmichQueue -BaseUrl $settings.BaseUrl -ApiKey $apiKey -Name $name
                    if ([bool]$after.isPaused -ne $wantPaused) {
                        throw "Queue ${name}: the state is still $(ConvertTo-StateName $after.isPaused) after the change."
                    }
                    $action = 'changed'
                }
                else { $action = 'would change' }
            }
            [pscustomobject]@{
                Queue   = $name
                Before  = ConvertTo-StateName $before.isPaused
                After   = ConvertTo-StateName $after.isPaused
                Action  = $action
                # In a paused queue, new jobs wait in the "paused" count, not in "waiting".
                Held    = $after.statistics.paused
                Waiting = $after.statistics.waiting
                Active  = $after.statistics.active
                Delayed = $after.statistics.delayed
                Failed  = $after.statistics.failed
            }
        }
        $failure = $null
        break
    }
    catch {
        $failure = ($_.Exception.Message -replace '\s+', ' ').Trim()
        if ($failure.Length -gt 200) { $failure = $failure.Substring(0, 200) }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $RetryDelaySec }
    }
}

$seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

if (-not $Apply) {
    if ($failure) { throw "Dry run failed: $failure" }
    $rows
    return
}

$telegram = 'not-sent'
if ($failure) {
    $verb = if ($wantPaused) { 'mettere in pausa' } else { 'riattivare' }
    $text = "`u{1F534} $HostLabel `u{00B7} `u{1F9E0} Code ML Immich`n`n" +
        "Non riesco a $verb le code ML di Immich ($MaxAttempts tentativi).`nErrore: $failure`n`n" +
        "Finché resta così, i job ML possono girare di giorno o restare fermi di notte. " +
        "Controlla Immich, poi rilancia: Set-ImmichMlQueue.ps1 -State Auto -Apply"
    $telegram = Send-TelegramFailure -ConfigPath $settings.TelegramConfigPath -Text $text
}

$logDir = Split-Path -Parent $settings.RunLog
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$entry = [ordered]@{
    ts        = (Get-Date).ToString('o')
    requested = $State
    target    = $target
    result    = if ($failure) { 'error' } else { 'ok' }
    attempts  = [math]::Min($attempt, $MaxAttempts)
    seconds   = $seconds
    queues    = @($rows | Select-Object Queue, Before, After, Held, Waiting, Active, Delayed, Failed)
    error     = $failure
    telegram  = $telegram
}
Add-Content -LiteralPath $settings.RunLog -Value ($entry | ConvertTo-Json -Compress -Depth 4) -Encoding utf8

if ($failure) {
    Write-Error "Set-ImmichMlQueue failed: $failure" -ErrorAction Continue
    exit 1
}
$rows
exit 0
