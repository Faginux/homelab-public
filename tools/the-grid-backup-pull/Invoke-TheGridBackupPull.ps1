#Requires -Version 7.0
<#
  Invoke-TheGridBackupPull.ps1  -  v1.0  (2026-10-02)
  Brings the backups that the-grid makes to ARCADE. ARCADE downloads them (pull).
  the-grid has no key to connect to this host (PIANO-DECLASSAMENTO-scope.md, Part A, D1).
  The Scheduled Task the-grid-BackupPull starts it through Invoke-TheGridBackupPull.vbs.

  On the-grid (refer to README.md in this folder):
    - user v4pull, SFTP only and read only (internal-sftp -R), chroot /srv/backup.
    - backup-sha256-manifest.timer writes <archive>.sha256 next to each archive.

  For each source:
    1. list the remote files.
    2. download only the files that are missing and that already have the .sha256.
       Download them first as .partial.
    3. rename only if the SHA-256 and the file header (age / gzip) are correct.
       If not, delete the .partial and report it.
    4. retention: delete the files older than $RetentionDays days, NEVER the most
       recent. This protects against a the-grid that stops to make backups.
    5. send a Telegram alert if something failed. Also send it if a remote archive
       has no .sha256 for more than $ManifestGraceHours hours, or if the most recent
       archive is too old.
       The alerts repeat at each run while the problem stays. It is a backup.

  The age of an archive comes from its NAME (the timestamp that the producer
  writes), not from the file date. sftp get does not keep the dates, and a copy
  keeps the name.

  Tests: -DryRun     lists and decides, but does not download, delete or send
                     Telegram.
         -NoSend     does all the work, but without Telegram.
         -SelfTest   checks the name parsing and the retention choice, without network.
         -SendTest   sends a test message (checks the Telegram channel).

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoSend,
    [switch]$SelfTest,
    [switch]$SendTest
)

$Sftp               = Join-Path $env:WINDIR 'System32\OpenSSH\sftp.exe'
$KeyFile            = Join-Path $HOME '.ssh\id_ed25519_the-grid_pull'
$RemoteUser         = 'v4pull'
# LAN first, Tailscale if the LAN does not answer. HostKeyAlias: SSH checks the Tailscale
# connection against the host key that it already trusts for the LAN IP (the same host).
$Hosts              = @('192.0.2.20', '198.51.100.20')
$HostKeyAlias       = '192.0.2.20'
$RetentionDays      = 36
$ManifestGraceHours = 3
$LogFile            = 'S:\Bakcup_Servarr+\from-the-grid\the-grid-backup-pull.ndjson'
$TelegramCfg        = 'S:\Scripts\Tmm\telegram.config.psd1'
$Header             = "`u{1F5A5} ARCADE `u{00B7} pull backup the-grid"

$Sources = @(
    [pscustomobject]@{
        Name       = 'docker-volumes'
        Remote     = '/docker-volumes'
        Local      = 'S:\Bakcup_Servarr+\from-the-grid\docker-volumes'
        Pattern    = 'the-grid-volumes-*.tar.gz.age'   # never the plain .tar.gz files from before age
        Kind       = 'age'
        MaxAgeDays = 5      # dvb-local Tue+Fri: the longest gap is 4 days
        Optional   = $false
    }
    [pscustomobject]@{
        Name       = 'bitwarden-dumps'
        Remote     = '/bitwarden-dumps'
        Local      = 'S:\Bakcup_Servarr+\bitwarden'
        Pattern    = 'bitwarden_vault_*.sql.gz'
        Kind       = 'gzip'
        MaxAgeDays = 8      # weekly dump
        Optional   = $true  # the folder on the-grid comes with Part B
    }
)

function Get-ArchiveTimestamp {
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][string]$Name)
    $inv = [cultureinfo]::InvariantCulture
    # the-grid-volumes-2026-10-02T03-00-00.tar.gz.age
    if ($Name -match '(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})') {
        return [datetime]::ParseExact("$($Matches[1]) $($Matches[2]):$($Matches[3]):$($Matches[4])", 'yyyy-MM-dd HH:mm:ss', $inv)
    }
    # bitwarden_vault_20260927_030001.sql.gz
    if ($Name -match '_(\d{8})_(\d{6})\.') {
        return [datetime]::ParseExact("$($Matches[1])$($Matches[2])", 'yyyyMMddHHmmss', $inv)
    }
    return $null
}

function Select-PruneCandidate {
    # From a list of names, returns the names to delete: older than the limit,
    # but never the most recent. Names without a timestamp that it can read: never deleted.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$Names,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$Days
    )
    $dated = @($Names | ForEach-Object {
        $ts = Get-ArchiveTimestamp $_
        if ($ts) { [pscustomobject]@{ Name = $_; Ts = $ts } }
    } | Sort-Object Ts -Descending)
    if ($dated.Count -le 1) { return }
    $cutoff = $Now.AddDays(-$Days)
    $dated | Select-Object -Skip 1 | Where-Object { $_.Ts -lt $cutoff } | ForEach-Object { $_.Name }
}

function Test-FileMagic {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind)
    $buf = [byte[]]::new(21)
    $fs = [IO.File]::OpenRead($Path)
    try { $n = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    switch ($Kind) {
        'age'  { return $n -eq 21 -and [Text.Encoding]::ASCII.GetString($buf) -eq 'age-encryption.org/v1' }
        'gzip' { return $n -ge 2 -and $buf[0] -eq 0x1F -and $buf[1] -eq 0x8B }
    }
    return $false
}

function Invoke-SftpBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetHost, [Parameter(Mandatory)][string[]]$Command)
    $batch = New-TemporaryFile
    try {
        [IO.File]::WriteAllLines($batch.FullName, $Command)
        $out = & $Sftp -q -b $batch.FullName -i $KeyFile `
            -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes `
            -o "HostKeyAlias=$HostKeyAlias" -o ConnectTimeout=20 -o ServerAliveInterval=15 `
            "$RemoteUser@$TargetHost" 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($out | ForEach-Object { "$_" } | Where-Object { $_ -and $_ -notmatch '^sftp>' })
        }
    } finally {
        Remove-Item -LiteralPath $batch.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Find-ReachableHost {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($h in $Hosts) {
        if ((Invoke-SftpBatch -TargetHost $h -Command 'pwd').ExitCode -eq 0) { return $h }
    }
    return $null
}

function Read-Sha256Manifest {
    # "<hash>  <name>": the name must be the name of the archive. If not, the manifest is for a different file.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedName)
    $line = (Get-Content -LiteralPath $Path -TotalCount 1).Trim()
    if ($line -match '^([0-9a-f]{64}) [ *](.+)$' -and $Matches[2] -eq $ExpectedName) { return $Matches[1] }
    return $null
}

function Invoke-SourcePull {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$TargetHost, [Parameter(Mandatory)][datetime]$Now)

    $result = [pscustomobject]@{
        Source = $Source.Name; Status = 'ok'; Downloaded = @(); Pruned = @()
        Problems = [Collections.Generic.List[string]]::new(); Newest = $null
    }

    $list = Invoke-SftpBatch -TargetHost $TargetHost -Command @("cd `"$($Source.Remote)`"", 'ls -1')
    if ($list.ExitCode -ne 0) {
        if ($Source.Optional -and ($list.Output -match 'No such file')) {
            $result.Status = 'skipped'
            return $result
        }
        $result.Status = 'error'
        $result.Problems.Add("elenco di $($Source.Remote) fallito: $($list.Output | Select-Object -Last 1)")
        return $result
    }
    $remote = @($list.Output | ForEach-Object { $_.Trim() })
    $wildcard = [Management.Automation.WildcardPattern]::new($Source.Pattern)
    $archives = @($remote | Where-Object { $wildcard.IsMatch($_) })

    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $Source.Local | Out-Null }
    # .partial files from an interrupted run: start again from zero
    if (Test-Path -LiteralPath $Source.Local) {
        Get-ChildItem -LiteralPath $Source.Local -Filter '*.partial' -File |
            ForEach-Object { if (-not $DryRun) { Remove-Item -LiteralPath $_.FullName -Force } }
    }

    $cutoff = $Now.AddDays(-$RetentionDays)
    foreach ($name in $archives) {
        $ts = Get-ArchiveTimestamp $name
        $final = Join-Path $Source.Local $name
        if (Test-Path -LiteralPath $final) { continue }
        # Already out of the V4 retention: do not download it again (the-grid can keep it longer).
        if ($ts -and $ts -lt $cutoff) { continue }
        if ($remote -notcontains "$name.sha256") {
            if ($ts -and ($Now - $ts).TotalHours -gt $ManifestGraceHours) {
                $result.Problems.Add("$name senza .sha256 su the-grid da oltre $ManifestGraceHours h (backup-sha256-manifest.timer?)")
            }
            continue
        }
        if ($DryRun) {
            $result.Downloaded += "$name (dry-run)"
            continue
        }

        $partial = "$final.partial"
        $partialSum = "$final.sha256.partial"
        $lcd = $Source.Local -replace '\\', '/'
        $get = Invoke-SftpBatch -TargetHost $TargetHost -Command @(
            "lcd `"$lcd`"", "cd `"$($Source.Remote)`"",
            "get `"$name.sha256`" `"$name.sha256.partial`"",
            "get `"$name`" `"$name.partial`""
        )
        if ($get.ExitCode -ne 0) {
            $result.Problems.Add("download di $name fallito: $($get.Output | Select-Object -Last 1)")
            Remove-Item -LiteralPath $partial, $partialSum -Force -ErrorAction SilentlyContinue
            continue
        }
        $expected = Read-Sha256Manifest -Path $partialSum -ExpectedName $name
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $expected) {
            $result.Problems.Add("$name.sha256 illeggibile o riferito a un altro file")
        } elseif ($actual -ne $expected) {
            $result.Problems.Add("$name : SHA-256 diverso da the-grid (atteso $($expected.Substring(0,16))…, ottenuto $($actual.Substring(0,16))…)")
        } elseif (-not (Test-FileMagic -Path $partial -Kind $Source.Kind)) {
            $result.Problems.Add("$name : intestazione non $($Source.Kind)")
        } else {
            Move-Item -LiteralPath $partialSum -Destination "$final.sha256" -Force
            Move-Item -LiteralPath $partial -Destination $final -Force
            $result.Downloaded += $name
            continue
        }
        Remove-Item -LiteralPath $partial, $partialSum -Force -ErrorAction SilentlyContinue
    }

    # Retention and freshness, on the files that are really on V4
    $local = @()
    if (Test-Path -LiteralPath $Source.Local) {
        $local = @(Get-ChildItem -LiteralPath $Source.Local -Filter $Source.Pattern -File | ForEach-Object Name)
    }
    foreach ($old in (Select-PruneCandidate -Names $local -Now $Now -Days $RetentionDays)) {
        if (-not $DryRun) {
            Remove-Item -LiteralPath (Join-Path $Source.Local $old), (Join-Path $Source.Local "$old.sha256") -Force -ErrorAction SilentlyContinue
        }
        $result.Pruned += $DryRun ? "$old (dry-run)" : $old
    }
    $newest = $local | ForEach-Object { Get-ArchiveTimestamp $_ } | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
    $result.Newest = $newest
    if (-not $newest) {
        $result.Problems.Add('nessun archivio su V4')
    } elseif (($Now - $newest).TotalDays -gt $Source.MaxAgeDays) {
        $result.Problems.Add("archivio piu' recente del $($newest.ToString('dd/MM HH:mm')): oltre $($Source.MaxAgeDays) giorni fa, the-grid ha smesso di produrne?")
    }
    if ($result.Problems.Count) { $result.Status = 'problem' }
    return $result
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

function Write-RunLog([hashtable]$Entry) {
    $Entry['ts'] = (Get-Date).ToString('o')
    $dir = Split-Path -Parent $LogFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Add-Content -LiteralPath $LogFile -Value ([pscustomobject]$Entry | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
}

# --- -SelfTest: name parsing and retention, without network ------------------
if ($SelfTest) {
    $failed = 0
    $now = [datetime]'2026-11-10 06:00'
    $checks = @(
        @('the-grid-volumes-2026-10-02T03-00-00.tar.gz.age', [datetime]'2026-10-02 03:00:00'),
        @('bitwarden_vault_20260927_030001.sql.gz',              [datetime]'2026-09-27 03:00:01'),
        @('qualcosa-senza-data.tar.gz.age',                      $null)
    )
    foreach ($c in $checks) {
        $got = Get-ArchiveTimestamp $c[0]
        $ok = ($got -eq $c[1])
        if (-not $ok) { $failed++ }
        '{0,-4} timestamp {1} -> {2}' -f ($ok ? 'OK' : 'FAIL'), $c[0], $got
    }
    $names = @(
        'the-grid-volumes-2026-09-25T03-00-00.tar.gz.age',  # 46 days: delete
        'the-grid-volumes-2026-10-02T03-00-00.tar.gz.age',  # 39 days: delete
        'the-grid-volumes-2026-10-06T03-00-00.tar.gz.age',  # 35 days: keep
        'the-grid-volumes-2026-11-06T03-00-00.tar.gz.age'   # recent: keep
    )
    $cases = @(
        @{ Label = 'normale';             Names = $names;                        Expected = @($names[0], $names[1]) },
        @{ Label = 'the-grid fermo da mesi';   Names = @($names[0], $names[1]);       Expected = @($names[0]) },
        @{ Label = 'un solo archivio';    Names = @($names[0]);                  Expected = @() },
        @{ Label = 'nome senza data';     Names = @('senza-data.tar.gz.age');    Expected = @() }
    )
    foreach ($c in $cases) {
        $got = @(Select-PruneCandidate -Names $c.Names -Now $now -Days 36)
        # the order is not important, the files are
        $ok = ((($got | Sort-Object) -join '|') -eq ((@($c.Expected) | Sort-Object) -join '|'))
        if (-not $ok) { $failed++ }
        '{0,-4} retention {1}: {2} da cancellare' -f ($ok ? 'OK' : 'FAIL'), $c.Label, $got.Count
    }
    exit ([int]($failed -gt 0))
}

# --- -SendTest: checks only the Telegram channel ----------------------------
if ($SendTest) {
    $st = Send-Telegram "`u{1F9EA} $Header`nTest del pull dei backup di the-grid: se leggi questo, l'avviso funziona. Nessuna azione richiesta."
    "telegram: $st"
    exit ([int]($st -ne 'ok'))
}

$started = Get-Date
$now = $started
$targetHost = Find-ReachableHost
$results = @()
if (-not $targetHost) {
    $results += [pscustomobject]@{
        Source = '*'; Status = 'error'; Downloaded = @(); Pruned = @()
        Problems = @("the-grid non raggiungibile ne' via LAN ne' via Tailscale come $RemoteUser"); Newest = $null
    }
} else {
    foreach ($s in $Sources) { $results += Invoke-SourcePull -Source $s -TargetHost $targetHost -Now $now }
}

$problems = @($results | ForEach-Object { $src = $_.Source; $_.Problems | ForEach-Object { "$src`: $_" } })
$tgs = 'not-needed'
if ($problems.Count) {
    $text = "`u{26A0} $Header`n" + ($problems -join "`n") + "`nLog: $LogFile"
    $tgs = ($DryRun -or $NoSend) ? 'skipped' : (Send-Telegram $text)
}

$elapsed = [int]((Get-Date) - $started).TotalSeconds
if (-not $DryRun) {
    Write-RunLog @{
        host = $targetHost; seconds = $elapsed; telegramStatus = $tgs
        sources = @($results | ForEach-Object {
            @{ name = $_.Source; status = $_.Status; downloaded = @($_.Downloaded); pruned = @($_.Pruned); problems = @($_.Problems) }
        })
    }
}

$results | ForEach-Object {
    [pscustomobject]@{
        Source     = $_.Source
        Status     = $_.Status
        Downloaded = $_.Downloaded -join ', '
        Pruned     = $_.Pruned -join ', '
        Newest     = $_.Newest
        Problems   = $_.Problems -join ' | '
        Host       = $targetHost
        Seconds    = $elapsed
        Telegram   = $tgs
    }
}
exit ([int]($problems.Count -gt 0))
