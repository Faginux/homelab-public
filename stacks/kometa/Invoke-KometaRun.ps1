#Requires -Version 7.0
<#
  Invoke-KometaRun.ps1  -  v1.3  (2026-09-28).
  The ONLY place from which Kometa starts automatically. It is an exception to
  the "Regola numero uno" (rule number one) that the operator authorized (refer
  to the CLAUDE.md of the repo). The Scheduled Tasks start it through
  Invoke-KometaRun.vbs (no console flash).
    - Kometa-Nightly  -> -Mode Full   full run (overlays + collections).
    - Kometa-Quick    -> -Mode Quick  only overlays on the libraries that the
                                      TMM->Plex watcher asks for in $RequestFile.
  A global mutex prevents two runs at the same time. A run that finds it taken
  exits immediately. The Quick request stays in the file and the watcher sends
  it again.
  Log: filtered output (no lines with token/apikey) in $RunLogDir, summary
  in kometa-runs.ndjson, Telegram only if the run fails.

  v1.1 - version: MAJOR $PinnedMajor locked, minor/patch automatic.
  Only in Full mode (or -UpdateOnly) it reads the highest tag v<major>.x.y
  from Docker Hub. If the tag is new, it does the pull and sends a Telegram
  alert. If the first Full run with the new version fails, it goes back to the
  previous version (rollback). It deletes the previous image only after a
  successful run. Quick always uses the current version, without network. If
  Docker Hub is not reachable, it stays on the current version.

  v1.2 (2026-09-27) - status badges of the series. Only in Full mode, before
  Kometa, it starts the TSSK job (stacks/umtk, `run --rm`). The job makes again
  from Sonarr the files config/tssk/*.yml that Kometa reads. The operator also
  extended the exception to "Regola numero uno" to this job. Before the run,
  it writes utc_offset in the UMTK config with the real offset of Europe/Rome
  (TSSK does not know daylight saving time). If TSSK fails: Telegram, and Kometa
  runs with the YAML files of the night before (dates one day old, nothing broken).

  v1.3 (2026-09-28) - cascading IT flag on TV series/Anime. Before Kometa it
  starts New-ItaOverlay.ps1 (only Plex API reads, no container, ~4 s). It does
  this in Full and in the Quick runs that touch TV series or Anime. Thus a newly
  imported episode updates "IT A" / "IT S.." immediately. If it fails: Telegram,
  and Kometa uses the files of the previous run.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Quick')][string]$Mode = 'Full',
    [switch]$UpdateOnly    # only check/pull of the version, no run (test)
)

$StackDir     = $PSScriptRoot
$RunLogDir    = 'S:\docker-appdata\kometa\run-logs'
$RequestFile  = Join-Path $RunLogDir 'quick-request.json'
$SummaryLog   = Join-Path $RunLogDir 'kometa-runs.ndjson'
$TelegramCfg  = 'S:\Scripts\Tmm\telegram.config.psd1'
$KeepRunLogs  = 45           # each night there are 2 logs now (tssk + full)
$MutexName    = 'Global\KometaRun'
$Image        = 'kometateam/kometa'
$PinnedMajor  = 2
$DefaultTag   = 'v2.5.2'     # the same as the default in docker-compose.yml
$VersionFile  = Join-Path $RunLogDir 'kometa-version.json'
$UmtkStackDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'umtk'
$UmtkConfig   = 'S:\docker-appdata\umtk\config\config.yml'

New-Item -ItemType Directory -Force -Path $RunLogDir | Out-Null

function Write-Summary([hashtable]$Entry) {
    $Entry['ts'] = (Get-Date).ToString('o')
    $Entry['mode'] = $Mode
    Add-Content -Path $SummaryLog -Value ([pscustomobject]$Entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
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

function Get-VersionState {
    if (Test-Path -LiteralPath $VersionFile) {
        try { $v = Get-Content -LiteralPath $VersionFile -Raw | ConvertFrom-Json; if ($v.current) { return $v } } catch { }
    }
    return [pscustomobject]@{ current = $DefaultTag; previous = $null; pendingValidation = $false }
}

function Save-VersionState($v) {
    $v | ConvertTo-Json | Set-Content -LiteralPath $VersionFile -Encoding UTF8
}

function Get-LatestPinnedTag {
    # highest tag v<major>.<minor>.<patch>. $null if Docker Hub does not answer
    try {
        $r = Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$Image/tags?page_size=100&ordering=last_updated" -TimeoutSec 20
        $tags = @($r.results.name | Where-Object { $_ -match "^v$PinnedMajor\.\d+\.\d+$" })
        if (-not $tags) { return $null }
        return ($tags | Sort-Object { [version]($_.TrimStart('v')) } -Descending | Select-Object -First 1)
    } catch { return $null }
}

function Update-KometaVersion {
    # returns the version state (updated if necessary)
    $v = Get-VersionState
    $latest = Get-LatestPinnedTag
    if (-not $latest) { Write-Summary @{ status = 'version-check-failed'; current = $v.current }; return $v }
    if ([version]($latest.TrimStart('v')) -le [version]($v.current.TrimStart('v'))) { return $v }

    & docker pull -q "${Image}:$latest" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Summary @{ status = 'pull-failed'; target = $latest; current = $v.current }; return $v }

    $new = [pscustomobject]@{ current = $latest; previous = $v.current; pendingValidation = $true }
    Save-VersionState $new
    $tgs = Send-Telegram ("`u{2B06} `u{1F5A5} ARCADE `u{00B7} `u{1F3AC} Kometa`nNuova versione: $($v.current) -> $latest (major $PinnedMajor bloccata).`nRelease notes: https://github.com/Kometa-Team/Kometa/releases/tag/$latest")
    Write-Summary @{ status = 'updated'; from = $v.current; to = $latest; telegramStatus = $tgs }
    return $new
}

function Invoke-TsskRefresh {
    # Makes the YAML files of the series status badges again. It never throws
    # exceptions: the result goes into the summary, and a failure does not stop Kometa.
    if (-not (Test-Path -LiteralPath $UmtkConfig)) { return @{ tsskStatus = 'not-configured' } }

    # utc_offset with the real offset of now (+2 CEST / +1 CET). A targeted
    # replacement of one line: the rest of the file (Sonarr API key) is not printed.
    # The key can be in quotes: the UMTK web UI, which also starts in the
    # single run, writes config.yml again with yaml.dump ('utc_offset': 2).
    try {
        $offset = [TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalHours
        $text = Get-Content -LiteralPath $UmtkConfig -Raw
        $new  = [regex]::Replace($text, "(?m)^('?)utc_offset\1:[^\r\n]*", ('${{1}}utc_offset${{1}}: {0:0.#}' -f $offset))
        if ($new -ne $text) { Set-Content -LiteralPath $UmtkConfig -Value $new -NoNewline -Encoding utf8NoBOM }
    } catch { }

    $tsskLog = Join-Path $RunLogDir ("{0}-tssk.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $t0 = Get-Date
    Push-Location -LiteralPath $UmtkStackDir
    try {
        & docker compose run --rm -T umtk 2>&1 |
            ForEach-Object { "$_" } |
            Where-Object { $_ -notmatch '(?i)token|api_?key' } |
            Set-Content -LiteralPath $tsskLog -Encoding UTF8
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    $dur = [int]((Get-Date) - $t0).TotalSeconds

    # UMTK exits with 0 also if Sonarr does not answer. It counts this as a warning:
    # "TSSK: OK (1 instance failed)", seen at the first test on 2026-09-27. Without
    # Sonarr it does not make the YAML files again, so for us it is a failure.
    if ($code -eq 0 -and (Select-String -LiteralPath $tsskLog -Pattern 'No Sonarr instances connected|instances? failed\)|TSSK: FAILED' -Quiet)) { $code = 2 }

    $tg = $null
    if ($code -ne 0) {
        $tg = Send-Telegram ("`u{26A0} `u{1F5A5} ARCADE `u{00B7} `u{1F3F7} TSSK`nFALLITO, exit $code dopo ${dur}s. Kometa gira con i YAML della notte prima.`nLog: $tsskLog")
    }
    return @{ tsskStatus = $(if ($code -eq 0) { 'ok' } else { 'error' }); tsskExitCode = $code; tsskDurationSec = $dur; tsskLog = $tsskLog; tsskTelegram = $tg }
}

function Invoke-ItaOverlay {
    # Makes config/overlays-custom/ita-*.yml again. A separate process: an error
    # of the script must not stop the launcher.
    $itaLog = Join-Path $RunLogDir ("{0}-ita.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $t0 = Get-Date
    & pwsh -NoProfile -File (Join-Path $StackDir 'New-ItaOverlay.ps1') 2>&1 |
        ForEach-Object { "$_" } | Where-Object { $_ -notmatch '(?i)token' } |
        Set-Content -LiteralPath $itaLog -Encoding UTF8
    $code = $LASTEXITCODE
    $dur = [int]((Get-Date) - $t0).TotalSeconds
    $tg = $null
    if ($code -ne 0) {
        $tg = Send-Telegram ("`u{26A0} `u{1F5A5} ARCADE `u{00B7} `u{1F1EE}`u{1F1F9} Bandiera IT`nFALLITA, exit $code. Kometa usa i file del giro prima.`nLog: $itaLog")
    }
    return @{ itaStatus = $(if ($code -eq 0) { 'ok' } else { 'error' }); itaDurationSec = $dur; itaLog = $itaLog; itaTelegram = $tg }
}

function Read-RequestedLibraries {
    if (-not (Test-Path -LiteralPath $RequestFile)) { return @() }
    try { return @((Get-Content -LiteralPath $RequestFile -Raw | ConvertFrom-Json).libraries | Where-Object { $_ }) }
    catch { return @() }
}

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { Write-Summary @{ status = 'skipped-busy' }; exit 0 }

    $ver = Get-VersionState
    if ($Mode -eq 'Full' -or $UpdateOnly) { $ver = Update-KometaVersion }
    if ($UpdateOnly) { "versione corrente: $($ver.current) | precedente: $($ver.previous) | da validare: $($ver.pendingValidation)"; exit 0 }
    $env:KOMETA_TAG = $ver.current

    $libraries = @()
    $tssk = $null
    $ita = $null
    if ($Mode -eq 'Quick') {
        $libraries = @(Read-RequestedLibraries | Sort-Object -Unique)
        if ($libraries.Count -eq 0) { Remove-Item -LiteralPath $RequestFile -ErrorAction SilentlyContinue; exit 0 }
        # the request is "taken": if the run fails, I put it back (below)
        Remove-Item -LiteralPath $RequestFile -ErrorAction SilentlyContinue
        $kometaArgs = @('--run-libraries', ($libraries -join '|'), '--overlays-only')
        if ($libraries | Where-Object { $_ -in 'Serie TV', 'Anime' }) { $ita = Invoke-ItaOverlay }
    } else {
        $kometaArgs = @('--run')
        $tssk = Invoke-TsskRefresh
        $ita = Invoke-ItaOverlay
    }

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runLog = Join-Path $RunLogDir "$stamp-$($Mode.ToLower()).log"
    $start  = Get-Date

    Push-Location -LiteralPath $StackDir
    try {
        & docker compose run --rm -T kometa @kometaArgs 2>&1 |
            ForEach-Object { "$_" } |
            Where-Object { $_ -notmatch '(?i)token|apikey' } |
            Set-Content -LiteralPath $runLog -Encoding UTF8
        $exitCode = $LASTEXITCODE
    } finally { Pop-Location }

    $logText  = Get-Content -LiteralPath $runLog -Raw -ErrorAction SilentlyContinue
    $applied  = ([regex]::Matches([string]$logText, 'Overlays Applied:')).Count
    $duration = [int]((Get-Date) - $start).TotalSeconds

    # Check of a version that the script just updated. Only a Full run checks it.
    $versionNote = ''
    if ($Mode -eq 'Full' -and $ver.pendingValidation) {
        if ($exitCode -eq 0) {
            if ($ver.previous) { & docker image rm "${Image}:$($ver.previous)" 2>&1 | Out-Null }
            Save-VersionState ([pscustomobject]@{ current = $ver.current; previous = $ver.previous; pendingValidation = $false })
        } else {
            Save-VersionState ([pscustomobject]@{ current = $ver.previous; previous = $null; pendingValidation = $false })
            $versionNote = "`nRollback automatico: $($ver.current) -> $($ver.previous) (primo run con la nuova versione fallito)."
        }
    }

    $telegram = $null
    if ($exitCode -ne 0) {
        if ($Mode -eq 'Quick') {
            $merged = @(@(Read-RequestedLibraries) + $libraries | Sort-Object -Unique)
            @{ libraries = $merged } | ConvertTo-Json | Set-Content -LiteralPath $RequestFile -Encoding UTF8
        }
        $telegram = Send-Telegram ("`u{1F534} `u{1F5A5} ARCADE `u{00B7} `u{1F3AC} Kometa ($Mode, $($ver.current))`nFALLITO, exit $exitCode dopo ${duration}s.`nLog: $runLog$versionNote")
    }

    $summary = @{
        status          = $(if ($exitCode -eq 0) { 'ok' } else { 'error' })
        exitCode        = $exitCode
        kometaTag       = $ver.current
        durationSec     = $duration
        libraries       = $libraries
        overlaysApplied = $applied
        runLog          = $runLog
        telegramStatus  = $telegram
    }
    if ($tssk) { foreach ($k in $tssk.Keys) { $summary[$k] = $tssk[$k] } }
    if ($ita)  { foreach ($k in $ita.Keys)  { $summary[$k] = $ita[$k] } }
    Write-Summary $summary

    Get-ChildItem -LiteralPath $RunLogDir -Filter '*.log' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepRunLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    exit $exitCode
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
