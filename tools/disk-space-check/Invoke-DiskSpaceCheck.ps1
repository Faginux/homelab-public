<#
.SYNOPSIS
    Tell Faginux on Telegram when a disk of ARCADE has too little free space.

.DESCRIPTION
    The script reads the free space of one drive (default S:). It has three levels:
      ok        free space >= ClearGB, or the last level was ok and free >= WarningGB
      warning   free space < WarningGB
      critical  free space < CriticalGB
    It sends one message when the level goes from ok to warning, one when it goes to
    critical, and one when it goes back to ok. The return to ok needs ClearGB, not
    WarningGB: the difference stops a series of messages when the free space moves
    near the limit. A change from critical to warning sends no message.

    S: holds the torrents of qBittorrent. The message tells how many GB of torrents
    are on the drive (API on localhost:8082, read only, no credentials).

    The state and the log are on C: (DataDir), not on the drive that it checks:
    on a full drive the write fails at the time the message is necessary.

    The script only reads. It runs as a normal user and sends no more than one
    message for each change of level.
    Tests:  -NoSend   print the level and the message, no Telegram, state unchanged
            -Force    send the message of the current level, also if it was sent
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'S',

    [int]$WarningGB = 200,
    [int]$CriticalGB = 100,
    [int]$ClearGB = 220,

    [switch]$NoSend,
    [switch]$Force,

    [string]$DataDir = (Join-Path $env:LOCALAPPDATA 'homelab\disk-space-check'),

    [string]$QbitUrl = 'http://localhost:8082',

    # The shared "Ops" bot. -ApiBase and -TelegramConfig are for tests with a local fake server.
    [string]$TelegramConfig = 'S:\Scripts\Tmm\telegram.config.psd1',
    [string]$ApiBase = 'https://api.telegram.org'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ($CriticalGB -lt $WarningGB -and $WarningGB -le $ClearGB)) {
    throw "The limits must be CriticalGB < WarningGB <= ClearGB (now $CriticalGB, $WarningGB, $ClearGB)."
}

$DriveLetter = $DriveLetter.ToUpperInvariant()
$StateFile = Join-Path $DataDir "state-$DriveLetter.json"
$RunLog = Join-Path $DataDir 'check.ndjson'
$HostLabel = "`u{1F5A5} ARCADE"
$ServiceLabel = "`u{1F4BE} Spazio ${DriveLetter}:"

function Send-Telegram {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    if (-not (Test-Path -LiteralPath $TelegramConfig)) { return 'not-configured' }
    try {
        $telegram = Import-PowerShellDataFile -Path $TelegramConfig
        $body = @{ chat_id = $telegram.ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$ApiBase/bot$($telegram.BotToken)/sendMessage" `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 | Out-Null
        return 'ok'
    }
    catch {
        return 'error'
    }
}

function Write-RunLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)
    $Entry['time'] = (Get-Date).ToString('s')
    $Entry['drive'] = $DriveLetter
    Add-Content -LiteralPath $RunLog -Value ([pscustomobject]$Entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
}

function Get-TorrentSummary {
    <# Size and number of the qBittorrent torrents on the drive. $null if qBittorrent does not answer. #>
    [CmdletBinding()]
    param()
    try {
        $torrents = @(Invoke-RestMethod -Method Get -Uri "$QbitUrl/api/v2/torrents/info" -TimeoutSec 10 | ForEach-Object { $_ })
    }
    catch {
        return $null
    }
    $onDrive = @($torrents | Where-Object {
            $path = if ($_.PSObject.Properties['content_path'] -and $_.content_path) { $_.content_path } else { $_.save_path }
            $path -like "${DriveLetter}:*"
        })
    $bytes = ($onDrive | Measure-Object -Property size -Sum).Sum
    return [pscustomobject]@{ Count = $onDrive.Count; GB = [math]::Round([double]$bytes / 1GB) }
}

function Format-Number {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Value)
    return $Value.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('it-IT'))
}

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$state = if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } else { $null }
$lastLevel = if ($state -and $state.PSObject.Properties['level']) { [string]$state.level } else { 'ok' }

$drive = Get-PSDrive -Name $DriveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
if (-not $drive -or $null -eq $drive.Free) {
    $level = 'missing'
    $freeGB = $null
}
else {
    $freeGB = [math]::Floor($drive.Free / 1GB)
    $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB)
    $level = if ($freeGB -lt $CriticalGB) { 'critical' }
    elseif ($freeGB -lt $WarningGB) { 'warning' }
    elseif ($freeGB -lt $ClearGB -and $lastLevel -ne 'ok') { 'warning' }   # not back to ok before ClearGB
    else { 'ok' }
}

# Which change of level gets a message.
$notify = switch ("$lastLevel>$level") {
    'ok>warning' { $true }
    'ok>critical' { $true }
    'warning>critical' { $true }
    'missing>warning' { $true }
    'missing>critical' { $true }
    'warning>ok' { $true }
    'critical>ok' { $true }
    'missing>ok' { $true }
    default { $level -eq 'missing' -and $lastLevel -ne 'missing' }
}
if ($Force) { $notify = $true }

$message = $null
if ($notify) {
    $torrentText = ''
    if ($level -in 'warning', 'critical') {
        $summary = Get-TorrentSummary
        $torrentText = if ($null -eq $summary) { "`nqBittorrent non risponde: non so quanto spazio occupano i torrent." }
        else { "`nTorrent di qBittorrent su ${DriveLetter}: $(Format-Number $summary.GB) GB ($($summary.Count) torrent). Si cancellano da soli al loro limite di seed; per liberare prima, cancellali in qBittorrent con i file." }
    }
    $message = switch ($level) {
        'warning' { "`u{26A0}`u{FE0F} $HostLabel `u{00B7} $ServiceLabel`n`n${DriveLetter}: ha $(Format-Number $freeGB) GB liberi su $(Format-Number $totalGB) (soglia $WarningGB GB).$torrentText" }
        'critical' { "`u{1F6A8} $HostLabel `u{00B7} $ServiceLabel`n`n${DriveLetter}: ha solo $(Format-Number $freeGB) GB liberi su $(Format-Number $totalGB) (soglia critica $CriticalGB GB).$torrentText" }
        'ok' { "`u{2705} $HostLabel `u{00B7} $ServiceLabel`n`n${DriveLetter}: è tornato a $(Format-Number $freeGB) GB liberi (sopra $ClearGB GB)." }
        'missing' { "`u{26A0}`u{FE0F} $HostLabel `u{00B7} $ServiceLabel`n`nNon trovo il disco ${DriveLetter}: o non leggo il suo spazio libero." }
    }
}

if ($NoSend) {
    "[NoSend] free: $freeGB GB, level: $lastLevel -> $level, message: $([bool]$message)"
    if ($message) { $message }
    exit 0
}

if (-not $message) {
    if ($level -ne $lastLevel) {
        # A change without a message (critical to warning): keep the new level.
        Set-Content -LiteralPath $StateFile -Value (@{ level = $level } | ConvertTo-Json -Compress) -Encoding UTF8
        Write-RunLog @{ result = "level:$lastLevel>$level"; freeGB = $freeGB }
    }
    exit 0
}

$sent = Send-Telegram $message
Write-RunLog @{ result = "sent:$sent"; level = "$lastLevel>$level"; freeGB = $freeGB }
if ($sent -eq 'ok') {
    Set-Content -LiteralPath $StateFile -Value (@{ level = $level } | ConvertTo-Json -Compress) -Encoding UTF8
    exit 0
}
# The state does not change, so the next run tries again.
exit 1
