<#
.SYNOPSIS
    Copy the configuration of Radarr, Sonarr, Prowlarr, qBittorrent and Plex to
    S:\Bakcup_Servarr+ (Scheduled Task Servarr-Backup).

.DESCRIPTION
    The script copies:
      - the backup zip files that Radarr, Sonarr and Prowlarr make themselves
        (C:\ProgramData\<app>\Backups)
      - the qBittorrent settings (%APPDATA%\qBittorrent) and its torrent state
        (%LOCALAPPDATA%\qBittorrent, without cache, logs and GeoDB)
      - the Plex data folder, without Cache, Codecs, Crash Reports, Diagnostics,
        Drivers, Logs, Updates and without the open database files. Plex writes
        its own database copies to S:\Plex_Backup (ButlerDatabaseBackupPath)
      - the Plex settings, an export of HKCU\Software\Plex, Inc.\Plex Media Server
        to a dated .reg file (the 14 most recent stay)

    The script NEVER deletes a file in the destination, except the old .reg files.
    It does not use robocopy /MIR or /PURGE: with an empty source (a new system
    before the restore) a mirror deletes the good backups.

    The script also checks the age of the newest arr zip and of the newest Plex
    database copy. It sends a Telegram message (shared "Ops" bot) only when there
    is a problem. The message repeats at each run while the problem stays.

    Compatible with Windows PowerShell 5.1: the new ISO runs it before
    PowerShell 7 is installed. Do not use ?:, ??, ?. or "`u{}".

    Tests:  -DryRun    robocopy /L (no copy), no .reg export, no deletion, no Telegram
            -NoSend    does all the work, but no Telegram
            -SendTest  sends a test message (checks the Telegram channel)
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoSend,
    [switch]$SendTest,

    [string]$Destination  = 'S:\Bakcup_Servarr+',
    [string]$PlexDbBackup = 'S:\Plex_Backup',

    # The newest arr zip can be this old. Radarr makes a scheduled backup each 7 days.
    [int]$ArrMaxAgeDays = 10,
    # Plex makes a database copy each 3 days, in its maintenance window.
    [int]$PlexDbMaxAgeDays = 5,
    [int]$KeepRegistryFiles = 14,

    [string]$TelegramConfig = 'S:\Scripts\Tmm\telegram.config.psd1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RunLog = Join-Path $Destination 'servarr-backup.ndjson'
$Header = '{0} ARCADE {1} backup Servarr' -f [char]::ConvertFromUtf32(0x1F5A5), [char]0x00B7
$Warn   = [char]::ConvertFromUtf32(0x26A0)

$plexData = Join-Path $env:LOCALAPPDATA 'Plex Media Server'
$qbitLocal = Join-Path $env:LOCALAPPDATA 'qBittorrent'

# Each item is one robocopy. ExcludeDirs are full paths: a bare name matches at any depth.
$Items = @(
    @{ Name = 'Radarr';   Source = 'C:\ProgramData\Radarr\Backups';   Target = 'Radarr\Backups';   Files = @('*.zip'); ExcludeDirs = @(); ExcludeFiles = @() }
    @{ Name = 'Sonarr';   Source = 'C:\ProgramData\Sonarr\Backups';   Target = 'Sonarr\Backups';   Files = @('*.zip'); ExcludeDirs = @(); ExcludeFiles = @() }
    @{ Name = 'Prowlarr'; Source = 'C:\ProgramData\Prowlarr\Backups'; Target = 'Prowlarr\Backups'; Files = @('*.zip'); ExcludeDirs = @(); ExcludeFiles = @() }
    @{ Name = 'qBittorrent-Roaming'; Source = (Join-Path $env:APPDATA 'qBittorrent'); Target = 'qBittorrent\Roaming'; Files = @('*.*')
       ExcludeDirs = @(); ExcludeFiles = @('lockfile') }
    @{ Name = 'qBittorrent-Local'; Source = $qbitLocal; Target = 'qBittorrent\Local'; Files = @('*.*')
       ExcludeDirs = @((Join-Path $qbitLocal 'cache'), (Join-Path $qbitLocal 'logs'), (Join-Path $qbitLocal 'GeoDB')); ExcludeFiles = @() }
    @{ Name = 'Plex'; Source = $plexData; Target = 'Plex'; Files = @('*.*')
       ExcludeDirs = @('Cache', 'Codecs', 'Crash Reports', 'Diagnostics', 'Drivers', 'Logs', 'Updates' | ForEach-Object { Join-Path $plexData $_ })
       # Open database files: a copy while Plex runs can be broken. S:\Plex_Backup has the good copies.
       ExcludeFiles = @('com.plexapp.plugins.library.db', 'com.plexapp.plugins.library.blobs.db', 'com.plexapp.dlna.db', '*.db-wal', '*.db-shm', '*.db-journal') }
)

function Send-Telegram {
    param([Parameter(Mandatory)][string]$Text)
    if (-not (Test-Path -LiteralPath $TelegramConfig)) { return 'not-configured' }
    try {
        # PS 5.1 uses TLS 1.0 by default; api.telegram.org needs TLS 1.2.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $telegram = Import-PowerShellDataFile -Path $TelegramConfig
        $body = @{ chat_id = $telegram.ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($telegram.BotToken)/sendMessage" `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 | Out-Null
        return 'ok'
    }
    catch {
        return 'error'
    }
}

function Invoke-ItemCopy {
    param([Parameter(Mandatory)][hashtable]$Item)

    $result = [ordered]@{ name = $Item.Name; status = 'ok'; exit = $null; copiedFiles = 0; copiedBytes = 0 }
    if (-not (Test-Path -LiteralPath $Item.Source)) {
        $result.status = 'missing'
        return $result
    }

    $target = Join-Path $Destination $Item.Target
    $arguments = @($Item.Source, $target) + $Item.Files + @('/E', '/COPY:DAT', '/DCOPY:T', '/XJ', '/R:2', '/W:5', '/NP', '/NDL', '/NFL', '/NJH', '/BYTES')
    if ($Item.ExcludeDirs.Count)  { $arguments += '/XD'; $arguments += $Item.ExcludeDirs }
    if ($Item.ExcludeFiles.Count) { $arguments += '/XF'; $arguments += $Item.ExcludeFiles }
    if ($DryRun) { $arguments += '/L' }

    $output = & robocopy.exe @arguments
    $result.exit = $LASTEXITCODE
    # Robocopy: 0 to 7 is success (bit 0 = files copied, bit 1 = extra files in the target).
    if ($LASTEXITCODE -ge 8) { $result.status = 'error' }

    # Summary lines: "Files : <total> <copied> <skipped> ..." and "Bytes : ..."
    foreach ($line in $output) {
        if ($line -match '^\s*Files\s*:\s*(\d+)\s+(\d+)') { $result.copiedFiles = [long]$Matches[2] }
        if ($line -match '^\s*Bytes\s*:\s*(\d+)\s+(\d+)') { $result.copiedBytes = [long]$Matches[2] }
    }
    return $result
}

function Export-PlexRegistry {
    $result = [ordered]@{ name = 'Plex-Registry'; status = 'ok'; file = $null; removed = 0 }
    $key = 'HKCU\Software\Plex, Inc.\Plex Media Server'
    if (-not (Test-Path -LiteralPath ('Registry::HKEY_CURRENT_USER\Software\Plex, Inc.\Plex Media Server'))) {
        $result.status = 'missing'
        return $result
    }
    $folder = Join-Path $Destination 'Plex\registry'
    $file = Join-Path $folder ('plex-registry-{0}.reg' -f (Get-Date -Format 'yyyy-MM-dd'))
    $result.file = $file
    if ($DryRun) { $result.status = 'dry-run'; return $result }

    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    # The key holds the Plex token. The file stays on S:, like the other backups of this folder.
    & reg.exe export $key $file /y | Out-Null
    if ($LASTEXITCODE -ne 0) { $result.status = 'error'; return $result }

    # Keep the newest files. The date is in the name, so the name order is the date order.
    $old = Get-ChildItem -LiteralPath $folder -Filter 'plex-registry-*.reg' | Sort-Object Name -Descending | Select-Object -Skip $KeepRegistryFiles
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force; $result.removed++ }
    return $result
}

function Get-NewestFileAge {
    param([string[]]$Folders, [string]$Filter)
    $newest = $null
    foreach ($folder in $Folders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $file = Get-ChildItem -LiteralPath $folder -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($file -and (($null -eq $newest) -or ($file.LastWriteTime -gt $newest))) { $newest = $file.LastWriteTime }
    }
    if ($null -eq $newest) { return $null }
    return [math]::Round(((Get-Date) - $newest).TotalDays, 1)
}

# --- -SendTest: checks only the Telegram channel ---------------------------
if ($SendTest) {
    $status = Send-Telegram ("{0} {1}`nTest del backup Servarr: se leggi questo, l'avviso funziona. Nessuna azione richiesta." -f [char]::ConvertFromUtf32(0x1F9EA), $Header)
    "telegram: $status"
    exit ([int]($status -ne 'ok'))
}

# --- Work -------------------------------------------------------------------
$start = Get-Date
if (-not (Test-Path -LiteralPath $Destination)) { throw "Destination not found: $Destination" }

$results = @()
foreach ($item in $Items) { $results += [pscustomobject](Invoke-ItemCopy -Item $item) }
$registry = [pscustomobject](Export-PlexRegistry)

# Problems are the text of the Telegram message, so they are in Italian.
$problems = @()
foreach ($r in $results) {
    if ($r.status -eq 'missing') { $problems += "$($r.name): cartella sorgente assente" }
    if ($r.status -eq 'error')   { $problems += "$($r.name): robocopy fallito (exit $($r.exit))" }
}
if ($registry.status -eq 'missing') { $problems += 'Plex: chiave di registro assente' }
if ($registry.status -eq 'error')   { $problems += 'Plex: export del registro fallito' }

$arrAge = Get-NewestFileAge -Folders @('C:\ProgramData\Radarr\Backups', 'C:\ProgramData\Sonarr\Backups', 'C:\ProgramData\Prowlarr\Backups') -Filter '*.zip'
foreach ($app in 'Radarr', 'Sonarr', 'Prowlarr') {
    $age = Get-NewestFileAge -Folders @("C:\ProgramData\$app\Backups") -Filter '*.zip'
    if (($null -ne $age) -and ($age -gt $ArrMaxAgeDays)) { $problems += "${app}: ultimo backup di $age giorni fa (limite $ArrMaxAgeDays)" }
}
$plexAge = Get-NewestFileAge -Folders @($PlexDbBackup) -Filter 'com.plexapp.plugins.library.db-*'
if ($null -eq $plexAge) { $problems += "Plex: nessuna copia del database in $PlexDbBackup" }
elseif ($plexAge -gt $PlexDbMaxAgeDays) { $problems += "Plex: ultima copia del database di $plexAge giorni fa (limite $PlexDbMaxAgeDays)" }

$telegram = 'not-needed'
if ($problems.Count) {
    $text = "$Warn $Header`n" + ($problems -join "`n") + "`nLog: $RunLog"
    if ($DryRun -or $NoSend) { $telegram = 'skipped' } else { $telegram = Send-Telegram -Text $text }
}

$seconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
$entry = [ordered]@{
    time       = $start.ToString('s')
    dryRun     = [bool]$DryRun
    seconds    = $seconds
    items      = $results
    registry   = $registry
    arrAgeDays = $arrAge
    plexDbAgeDays = $plexAge
    problems   = $problems
    telegram   = $telegram
}
if (-not $DryRun) {
    Add-Content -LiteralPath $RunLog -Value ($entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
}

# Console summary (English): useful for a manual run.
foreach ($r in $results) {
    '{0,-20} {1,-8} exit={2,-3} files={3,-6} MB={4:N1}' -f $r.name, $r.status, $r.exit, $r.copiedFiles, ($r.copiedBytes / 1MB)
}
'{0,-20} {1,-8} {2}' -f $registry.name, $registry.status, $registry.file
"newest arr zip: $arrAge days, newest Plex db copy: $plexAge days"
"problems: $($problems.Count), telegram: $telegram, seconds: $seconds"
exit ([int]($problems.Count -gt 0))
