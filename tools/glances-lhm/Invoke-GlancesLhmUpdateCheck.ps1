<#
.SYNOPSIS
    Tell Faginux on Telegram when LibreHardwareMonitor changed and the copy of Glances is old.

.DESCRIPTION
    The service Glances loads its own copy of the LibreHardwareMonitor DLL files
    (C:\Program Files\GlancesLhm\lib, see README.md). Winget can update the package
    in the profile of Faginux, and the copy stays old.

    This script compares the DLL files of the package with the copy. If they differ,
    it waits WaitSeconds (the update must be finished), checks again, and sends one
    Telegram message. The message tells Faginux to run Set-GlancesLauncher.ps1. When
    the copy is equal to the package again, it sends a short "back to normal" message.

    The script only reads. It runs as a normal user, changes nothing in Program
    Files and does not restart a service. It sends one message for each change.
    Tests:  -NoSend   print the message, no Telegram, state unchanged
            -Force    send even if the message was sent for this change
#>
[CmdletBinding()]
param(
    [switch]$NoSend,
    [switch]$Force,

    # Wait this time after the first difference. Then check again.
    [int]$WaitSeconds = 120,

    [string]$SourceDir = (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe'),

    [string]$DeployedDir = (Join-Path $env:ProgramFiles 'GlancesLhm\lib'),

    [string]$DataDir = 'S:\docker-appdata\glances-lhm-check',

    # The shared "Ops" bot. -ApiBase and -TelegramConfig are for tests with a local fake server.
    [string]$TelegramConfig = 'S:\Scripts\Tmm\telegram.config.psd1',
    [string]$ApiBase = 'https://api.telegram.org'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateFile = Join-Path $DataDir 'state.json'
$RunLog = Join-Path $DataDir 'check.ndjson'
$HostLabel = "`u{1F5A5} ARCADE"
$ServiceLabel = "`u{1F321}`u{FE0F} Glances Tctl"
$SetScript = Join-Path $PSScriptRoot 'Set-GlancesLauncher.ps1'

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
    Add-Content -LiteralPath $RunLog -Value ([pscustomobject]$Entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
}

function Get-DllHash {
    <# Name and SHA256 of each DLL in the root of a directory. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)
    $hashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Dir -Filter '*.dll' -File) {
        $hashes[$file.Name.ToLowerInvariant()] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Get-Difference {
    <# The DLL files of the package that are new or different in the copy. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Source, [Parameter(Mandatory)][hashtable]$Deployed)
    $names = foreach ($name in ($Source.Keys | Sort-Object)) {
        if (-not $Deployed.ContainsKey($name) -or $Deployed[$name] -ne $Source[$name]) { $name }
    }
    return @($names)
}

function Get-LibraryVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)
    $path = Join-Path $Dir 'LibreHardwareMonitorLib.dll'
    if (-not (Test-Path -LiteralPath $path)) { return '?' }
    $info = (Get-Item -LiteralPath $path).VersionInfo
    $version = if ($info.ProductVersion) { $info.ProductVersion } else { $info.FileVersion }
    return ($version -split '\+')[0]
}

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# The launcher is not installed, or the package is gone: nothing to compare.
if (-not (Test-Path -LiteralPath $DeployedDir)) {
    Write-RunLog @{ result = 'not-deployed' }
    exit 0
}
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'LibreHardwareMonitorLib.dll'))) {
    Write-RunLog @{ result = 'source-missing' }
    exit 0
}

$state = if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } else { $null }
$notified = if ($state -and $state.PSObject.Properties['notified']) { [string]$state.notified } else { '' }

$source = Get-DllHash -Dir $SourceDir
$difference = @(Get-Difference -Source $source -Deployed (Get-DllHash -Dir $DeployedDir))

# The copy is equal to the package.
if ($difference.Count -eq 0) {
    if ($notified -and -not $NoSend) {
        $message = "`u{1F501} $HostLabel `u{00B7} $ServiceLabel`n`nLa copia di LibreHardwareMonitor usata da Glances è di nuovo uguale al pacchetto WinGet."
        $sent = Send-Telegram $message
        Write-RunLog @{ result = "back-to-normal:$sent" }
        if ($sent -eq 'ok') { Set-Content -LiteralPath $StateFile -Value (@{ notified = '' } | ConvertTo-Json -Compress) -Encoding UTF8 }
        exit $(if ($sent -eq 'ok') { 0 } else { 1 })
    }
    if ($NoSend) { '[NoSend] in sync' }
    else { Write-RunLog @{ result = 'in-sync' } }
    exit 0
}

# There is a difference. Compare it with the one that Faginux already knows.
$fingerprint = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($difference | ForEach-Object { "$_=$($source[$_])" }) -join ';'))) -Algorithm SHA256).Hash
if ($notified -eq $fingerprint -and -not $Force) {
    if (-not $NoSend) { Write-RunLog @{ result = 'already-notified' } }
    else { '[NoSend] already notified for this change' }
    exit 0
}

# Wait: a winget update writes the files for some seconds. Then check again.
if ($WaitSeconds -gt 0) { Start-Sleep -Seconds $WaitSeconds }
$again = Get-DllHash -Dir $SourceDir
$differenceAgain = @(Get-Difference -Source $again -Deployed (Get-DllHash -Dir $DeployedDir))
$fingerprintAgain = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($differenceAgain | ForEach-Object { "$_=$($again[$_])" }) -join ';'))) -Algorithm SHA256).Hash
if ($differenceAgain.Count -eq 0 -or $fingerprintAgain -ne $fingerprint) {
    if (-not $NoSend) { Write-RunLog @{ result = 'still-changing' } }
    else { '[NoSend] the files changed during the wait: no message' }
    exit 0
}
$newest = ($differenceAgain | ForEach-Object { (Get-Item -LiteralPath (Join-Path $SourceDir $_)).LastWriteTime } | Measure-Object -Maximum).Maximum
if (((Get-Date) - $newest).TotalSeconds -lt [math]::Min($WaitSeconds, 120) -and $WaitSeconds -gt 0) {
    if (-not $NoSend) { Write-RunLog @{ result = 'too-recent' } }
    else { '[NoSend] a file is too recent: no message' }
    exit 0
}

$oldVersion = Get-LibraryVersion -Dir $DeployedDir
$newVersion = Get-LibraryVersion -Dir $SourceDir
$versionText = if ($oldVersion -ne $newVersion) { "$oldVersion → $newVersion" } else { "stessa versione $newVersion" }
$fileText = if ($differenceAgain.Count -eq 1) { '1 DLL diversa' } else { "$($differenceAgain.Count) DLL diverse" }
$message = "`u{2B06}`u{FE0F} $HostLabel `u{00B7} $ServiceLabel`n`nLibreHardwareMonitor è cambiato ($versionText, $fileText dalla copia di Glances). Glances usa ancora la copia vecchia e continua a funzionare. Per aggiornarla, in una PowerShell admin:`npwsh -NoProfile -File $SetScript"

if ($NoSend) {
    "[NoSend]`n$message"
    exit 0
}

$sent = Send-Telegram $message
Write-RunLog @{ result = "sent:$sent"; files = $differenceAgain.Count; from = $oldVersion; to = $newVersion }
if ($sent -eq 'ok') {
    Set-Content -LiteralPath $StateFile -Value (@{ notified = $fingerprintAgain } | ConvertTo-Json -Compress) -Encoding UTF8
    exit 0
}
exit 1
