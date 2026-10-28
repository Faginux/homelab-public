#Requires -Version 7.0
<#
  Invoke-ComposeDriftCheck.ps1  -  v1.0  (2026-10-14)
  Daily check on ARCADE: it reports on Telegram the containers that are not
  equal to the compose files of the repo. It is the V4 copy of
  nodes/the-grid/systemd/docker-compose-drift-check.sh (the-grid, 21:00), with
  the same rules and the same lines in the message.

  Why: a commit that changes image, labels, environment, ports or volumes does
  not apply until the container is recreated (PROBLEMI-E-SOLUZIONI.md §2.12).
  Komodo deploys the stacks of V4 from the repo, so the repo and the containers
  must agree (PIANO-KOMODO-SECRETS-GATE.md, 2b.3 D).

  For each stack in stacks/ (except the jobs in $SkipStacks):
    ERRORE                 compose config or the dry-run fails
    SENZA CONTAINER        a service of the compose has no container
    DRIFT                  the config-hash of the container is not the hash of the compose
    IMMAGINE NON APPLICATA the local image of the tag is not the image in use
    RICREEREBBE            hash and image are equal, but "up -d" recreates it
                           (stale image label, networks or volumes)

  The script sends a message only when the list changes, also when it becomes
  empty again. It saves the state only after a successful send.
  Read only: it recreates nothing. "docker compose config" runs only with
  --hash, which prints "service hash" and no value.

  Tests:  -NoSend              print the message, no Telegram, state unchanged
          -StacksDir <path>    check another folder (test with a copy)
          -Force               send even if the list did not change

  Created with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [switch]$NoSend,
    [switch]$Force,
    [string]$StacksDir = 'S:\github\homelab\stacks'
)

# kometa and umtk are "docker compose run --rm" jobs: they have no container
# between two runs (CLAUDE.md, rule number one exception).
$SkipStacks  = @('kometa', 'umtk')
$DataDir     = 'S:\docker-appdata\compose-drift-check'
$StateFile   = Join-Path $DataDir 'last.txt'
$RunLog      = Join-Path $DataDir 'drift-check.ndjson'
$TelegramCfg = 'S:\Scripts\Tmm\telegram.config.psd1'
$HostLabel   = "`u{1F5A5} ARCADE"

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

function Write-RunLog([hashtable]$Entry) {
    $Entry['ts'] = (Get-Date).ToString('o')
    Add-Content -LiteralPath $RunLog -Value ([pscustomobject]$Entry | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
}

function Get-StackDrift([string]$Dir) {
    $stack = Split-Path $Dir -Leaf
    $lines = [System.Collections.Generic.List[string]]::new()
    Push-Location $Dir
    try {
        $hashes = docker compose config --hash '*' 2>$null
        if ($LASTEXITCODE -ne 0) {
            $lines.Add("ERRORE: $stack -> 'docker compose config' fallisce, compose o .env da controllare")
            return $lines
        }
        $containers = @{}
        foreach ($l in (docker compose ps -a --format '{{.Service}} {{.Name}}' 2>$null)) {
            $svc, $name = $l -split ' ', 2
            if ($svc) { $containers[$svc] = $name }
        }
        # --dry-run runs the same reconciliation as a real "up -d", with no write
        # to the daemon, and prints only "Container <name> <action>".
        $dryRun = docker compose --dry-run up -d 2>&1
        if ($LASTEXITCODE -ne 0) {
            $lines.Add("ERRORE: $stack -> 'docker compose --dry-run up -d' fallisce, da controllare a mano")
            return $lines
        }
        $recreate = @($dryRun | ForEach-Object { $f = "$_".Trim() -split '\s+'; if ($f.Count -ge 3 -and $f[0] -eq 'Container' -and $f[2] -eq 'Recreate') { $f[1] } })
        foreach ($h in $hashes) {
            $svc, $hash = "$h".Trim() -split ' ', 2
            if (-not $svc) { continue }
            $c = $containers[$svc]
            if (-not $c) {
                $lines.Add("SENZA CONTAINER: $stack/$svc -> nel repo ma non creato (cd $Dir; docker compose up -d)")
                continue
            }
            $running = docker inspect $c --format '{{index .Config.Labels "com.docker.compose.config-hash"}}' 2>$null
            # A different hash counts only if the dry-run also recreates the
            # container. With "network_mode: service:X", "config --hash" hashes the
            # static config, but "up" saves the hash after it resolves the network
            # to "container:<id>". Then the hashes differ and compose still says
            # Running (tdarr-node, 2026-10-14).
            if ($hash -ne $running -and $recreate -contains $c) {
                $lines.Add("DRIFT: $stack/$svc ($c) -> compose cambiato, container non ricreato (cd $Dir; docker compose up -d)")
                continue
            }
            # Same config but another local image for the tag: pull done, up not done.
            $cfgImage = docker inspect $c --format '{{.Config.Image}}' 2>$null
            $localId  = docker image inspect $cfgImage --format '{{.Id}}' 2>$null
            $inUse    = docker inspect $c --format '{{.Image}}' 2>$null
            if ($localId -and $localId -ne $inUse) {
                $lines.Add("IMMAGINE NON APPLICATA: $stack/$svc ($c) -> $cfgImage scaricata ma non in uso (cd $Dir; docker compose up -d)")
                continue
            }
            if ($recreate -contains $c) {
                $lines.Add("RICREEREBBE: $stack/$svc ($c) -> config e immagine uguali, ma il prossimo up lo ricrea (label immagine, reti o volumi: cd $Dir; docker compose --dry-run up -d)")
            }
        }
    }
    finally { Pop-Location }
    return $lines
}

# Do not run against a stopped Docker Desktop: every stack would give ERRORE.
# The watchdog on the scope already reports V4 down (Periphery offline).
docker version --format '{{.Server.Version}}' *> $null
if ($LASTEXITCODE -ne 0) { exit 0 }

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$started = Get-Date
$found = foreach ($dir in Get-ChildItem -LiteralPath $StacksDir -Directory) {
    if ($SkipStacks -contains $dir.Name) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'docker-compose.yml'))) { continue }
    Get-StackDrift $dir.FullName
}
$current  = (@($found) | Sort-Object) -join "`n"
$previous = if (Test-Path -LiteralPath $StateFile) { (Get-Content -LiteralPath $StateFile -Raw) ?? '' } else { '' }
$seconds  = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

if ($current -eq $previous.TrimEnd("`r", "`n") -and -not $Force) {
    if (-not $NoSend) { Write-RunLog @{ result = 'unchanged'; lines = @($found).Count; seconds = $seconds } }
    if ($NoSend) { "[NoSend] no change ($(@($found).Count) lines, $seconds s)"; if ($current) { $current } }
    exit 0
}

if ($current) {
    $message = "`u{1F534} $HostLabel `u{00B7} `u{1F9ED} Drift compose`n`n$current`n`nI container non corrispondono al compose del repo su ARCADE. Prima di lanciare up -d verifica cosa cambierebbe: PROBLEMI-E-SOLUZIONI.md §2.12."
} else {
    $message = "`u{1F501} $HostLabel `u{00B7} `u{1F9ED} Drift compose`n`nTutti i container corrispondono di nuovo ai compose del repo."
}

if ($NoSend) {
    "[NoSend] ($seconds s)`n$message"
    exit 0
}

$sent = Send-Telegram $message
Write-RunLog @{ result = "sent:$sent"; lines = @($found).Count; seconds = $seconds }
if ($sent -eq 'ok') {
    Set-Content -LiteralPath $StateFile -Value $current -Encoding UTF8 -NoNewline
    exit 0
}
exit 1
