#Requires -Version 7.0
<#
  Invoke-QbitCompatCheck.ps1  -  v1.0  (2026-09-30).
  Daily compatibility check qBittorrent <-> qbit_manage, with a Telegram
  alert. The Scheduled Task QbitCompat-Check (09:20) starts it through
  Invoke-QbitCompatCheck.vbs (no console flash). Read only: it does not touch
  containers, compose files or qBittorrent.

  Why: qbit_manage refuses to start (exit 1) if qBittorrent is newer than the
  version that its library `qbittorrent-api` declares. On 2026-09-30
  qBittorrent went to 5.2.4 (released on 2026-09-28). The installer came from
  the site after the notice of the app. Upstream was still at 5.2.3.
  The winget pin does not cover that path. For this reason this check exists.

  It compares three versions.
    installed   qBittorrent exe (C:\Program Files\qBittorrent).
    latest      GitHub qbittorrent/qBittorrent, most recent stable release.
    supported   SUPPORTED_VERSIONS.json, master branch of qbit_manage. It follows
                the stable release. Renovate updates it automatically.

  It sends a Telegram alert ONLY when the scenario changes (state in $StateFile).
  It sends it only if there is something to do.
    Broken             installed > supported, without a bypass in the compose.
    CanRemoveBypass    bypass on, but upstream now supports the installed version.
    Hold               a version came out that is not supported yet. Do not update.
    SafeToUpdate       a version came out that is already supported. You can update.
  Silent: BypassActive (bypass on and upstream still behind: the known
  situation) and Ok. If GitHub does not answer for 3 days in a row, it sends
  an alert about the check itself.

  The bypass is QBT_SKIP_QB_VERSION_CHECK=true, found as a line that is not a
  comment in docker-compose.yml in this folder.

  Tests: -NoSend     prints the result, no Telegram, state not changed.
         -SelfTest   checks the table of cases, without network.
         -SendTest   sends a test message (checks the Telegram channel).
         -Force      sends the alert again also if the scenario did not change.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [switch]$NoSend,
    [switch]$SelfTest,
    [switch]$SendTest,
    [switch]$Force
)

$ComposeFile   = Join-Path $PSScriptRoot 'docker-compose.yml'
$DataDir       = 'S:\docker-appdata\qbit_manage\compat-check'
$StateFile     = Join-Path $DataDir 'state.json'
$RunLog        = Join-Path $DataDir 'compat-check.ndjson'
$TelegramCfg   = 'S:\Scripts\Tmm\telegram.config.psd1'
$QbitExe       = 'C:\Program Files\qBittorrent\qbittorrent.exe'
$SupportedUrl  = 'https://raw.githubusercontent.com/StuffAnThings/qbit_manage/master/SUPPORTED_VERSIONS.json'
$ReleaseUrl    = 'https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest'
$FailuresBeforeAlert = 3
$Header        = "`u{1F5A5} ARCADE `u{00B7} qbit_manage"

function ConvertTo-QbitVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param([string]$Text)
    if ($Text -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

function Get-InstalledQbitVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param()
    if (Test-Path -LiteralPath $QbitExe) {
        return ConvertTo-QbitVersion (Get-Item -LiteralPath $QbitExe).VersionInfo.ProductVersion
    }
    return $null
}

function Get-LatestQbitVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param()
    try {
        $r = Invoke-RestMethod -Uri $ReleaseUrl -TimeoutSec 20 -ErrorAction Stop `
            -Headers @{ 'User-Agent' = 'homelab-qbit-compat-check'; Accept = 'application/vnd.github+json' }
        if ($r.prerelease) { return $null }
        return ConvertTo-QbitVersion $r.tag_name      # for example "release-5.2.4"
    } catch { return $null }
}

function Get-SupportedQbitVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param()
    try {
        $r = Invoke-WebRequest -Uri $SupportedUrl -TimeoutSec 20 -ErrorAction Stop `
            -Headers @{ 'User-Agent' = 'homelab-qbit-compat-check' }
        return ConvertTo-QbitVersion ($r.Content | ConvertFrom-Json).master.qbit   # for example "v5.2.3"
    } catch { return $null }
}

function Test-BypassEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-Path -LiteralPath $ComposeFile)) { return $false }
    return [bool](Select-String -LiteralPath $ComposeFile -Quiet `
        -Pattern '^\s*-\s*QBT_SKIP_QB_VERSION_CHECK=true\s*(#.*)?$')
}

function Resolve-CompatVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version]$Installed,
        [Parameter(Mandatory)][version]$Latest,
        [Parameter(Mandatory)][version]$Supported,
        [Parameter(Mandatory)][bool]$Bypass
    )
    if ($Installed -gt $Supported) {
        if ($Bypass) {
            return [pscustomobject]@{ Case = 'BypassActive'; Notify = $false; Text = $null }
        }
        return [pscustomobject]@{ Case = 'Broken'; Notify = $true; Text =
            "`u{1F534} $Header`nqBittorrent $Installed supera il limite di qbit_manage ($Supported): il container si ferma con exit 1.`nOpzioni: aspettare upstream, oppure QBT_SKIP_QB_VERSION_CHECK=true in stacks/qbit_manage/docker-compose.yml." }
    }
    if ($Bypass) {
        return [pscustomobject]@{ Case = 'CanRemoveBypass'; Notify = $true; Text =
            "`u{2705} $Header`nUpstream ora supporta qBittorrent fino alla $Supported (installata: $Installed).`nPuoi togliere il bypass: rimuovi QBT_SKIP_QB_VERSION_CHECK da stacks/qbit_manage/docker-compose.yml (la restart policy e' gia' unless-stopped), poi docker compose pull e up -d (con conferma)." }
    }
    if ($Latest -gt $Supported) {
        return [pscustomobject]@{ Case = 'Hold'; Notify = $true; Text =
            "`u{26A0} $Header`nqBittorrent $Latest e' uscito ma qbit_manage supporta solo fino alla $Supported (installata: $Installed).`nNon aggiornare: il pin winget salta upgrade --all, ma non l'installer scaricato dal sito." }
    }
    if ($Latest -gt $Installed) {
        return [pscustomobject]@{ Case = 'SafeToUpdate'; Notify = $true; Text =
            "`u{2705} $Header`nqbit_manage supporta qBittorrent $Latest (installata: $Installed).`nPuoi aggiornare: winget upgrade --id qBittorrent.qBittorrent (il pin resta e salta solo upgrade --all)." }
    }
    return [pscustomobject]@{ Case = 'Ok'; Notify = $false; Text = $null }
}

function Send-Telegram([string]$Text) {
    if (-not (Test-Path -LiteralPath $TelegramCfg)) { return 'not-configured' }
    try {
        $tg = Import-PowerShellDataFile -Path $TelegramCfg
        $body = @{ chat_id = $tg.ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($tg.BotToken)/sendMessage" `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 | Out-Null
        return 'ok'
    } catch { return 'error' }
}

function Get-CheckState {
    if (Test-Path -LiteralPath $StateFile) {
        try { return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ lastKey = $null; failures = 0 }
}

function Save-CheckState($State) {
    $State | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Write-RunLog([hashtable]$Entry) {
    $Entry['ts'] = (Get-Date).ToString('o')
    Add-Content -LiteralPath $RunLog -Value ([pscustomobject]$Entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
}

# --- -SelfTest: table of cases, without network ------------------------------
if ($SelfTest) {
    $cases = @(
        # installed, latest, supported, bypass, expected case
        @('5.2.4', '5.2.4', '5.2.3', $true,  'BypassActive'),     # today (2026-09-30)
        @('5.2.4', '5.2.4', '5.2.3', $false, 'Broken'),           # bypass removed by mistake
        @('5.2.4', '5.2.4', '5.2.4', $true,  'CanRemoveBypass'),  # upstream caught up
        @('5.2.4', '5.3.0', '5.2.4', $false, 'Hold'),             # release not supported yet
        @('5.2.3', '5.2.4', '5.2.4', $false, 'SafeToUpdate'),     # supported release
        @('5.2.4', '5.2.4', '5.2.4', $false, 'Ok')                # all aligned
    )
    $failed = 0
    foreach ($c in $cases) {
        $v = Resolve-CompatVerdict -Installed $c[0] -Latest $c[1] -Supported $c[2] -Bypass $c[3]
        $ok = $v.Case -eq $c[4]
        if (-not $ok) { $failed++ }
        '{0,-4} inst {1} ult {2} supp {3} bypass {4,-5} -> {5}{6}' -f `
            ($ok ? 'OK' : 'FAIL'), $c[0], $c[1], $c[2], $c[3], $v.Case, ($ok ? '' : " (atteso $($c[4]))")
    }
    exit ([int]($failed -gt 0))
}

# --- -SendTest: checks only the Telegram channel ----------------------------
if ($SendTest) {
    $st = Send-Telegram "`u{1F9EA} $Header`nTest del controllo di compatibilita' qBittorrent: se leggi questo, l'avviso funziona. Nessuna azione richiesta."
    "telegram: $st"
    exit ([int]($st -ne 'ok'))
}

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$state = Get-CheckState
$failures = [int]$state.failures

$installed = Get-InstalledQbitVersion
$latest    = Get-LatestQbitVersion
$supported = Get-SupportedQbitVersion
$bypass    = Test-BypassEnabled

# --- source not reachable: count the failures, alert only at the threshold ---
if (-not $installed -or -not $latest -or -not $supported) {
    $missing = @(
        if (-not $installed) { 'versione installata' }
        if (-not $latest)    { 'ultima release qBittorrent' }
        if (-not $supported) { 'SUPPORTED_VERSIONS.json' }
    ) -join ', '
    $failures++
    $tgs = $null
    if ($failures -eq $FailuresBeforeAlert -and -not $NoSend) {
        $tgs = Send-Telegram "`u{26A0} $Header`nIl controllo di compatibilita' non riesce a leggere ($missing) da $failures giorni.`nControlla lo Scheduled Task QbitCompat-Check e il log in $RunLog."
    }
    if (-not $NoSend) {
        Save-CheckState ([pscustomobject]@{ lastKey = $state.lastKey; failures = $failures })
        Write-RunLog @{ status = 'fetch-failed'; missing = $missing; failures = $failures; telegramStatus = $tgs }
    }
    Write-Warning "Lettura fallita: $missing (fallimenti di fila: $failures)"
    exit 1
}

$verdict = Resolve-CompatVerdict -Installed $installed -Latest $latest -Supported $supported -Bypass $bypass
$key = '{0}|{1}|{2}|{3}' -f $verdict.Case, $installed, $latest, $supported
$wouldSend = $verdict.Notify -and ($Force -or $key -ne $state.lastKey)

$tgs = 'not-needed'
if ($wouldSend) { $tgs = $NoSend ? 'skipped-NoSend' : (Send-Telegram $verdict.Text) }

if (-not $NoSend) {
    # if Telegram fails, I do not save the key: the next day it tries again
    $newKey = ($tgs -eq 'error' -or $tgs -eq 'not-configured') ? $state.lastKey : $key
    Save-CheckState ([pscustomobject]@{ lastKey = $newKey; failures = 0 })
    Write-RunLog @{
        status = 'checked'; installed = "$installed"; latest = "$latest"; supported = "$supported"
        bypass = $bypass; case = $verdict.Case; telegramStatus = $tgs
    }
}

[pscustomobject]@{
    Installed = $installed; Latest = $latest; Supported = $supported; Bypass = $bypass
    Case = $verdict.Case; WouldSend = $wouldSend; Telegram = $tgs; Message = $verdict.Text
}
exit ([int]($tgs -eq 'error'))
