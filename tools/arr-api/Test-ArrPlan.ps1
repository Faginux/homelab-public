<#
  Test-ArrPlan.ps1  -  v0.1  (2026-11-27).
  Offline tests of the plan tools with a false server on 127.0.0.1.

  Safety: the test sets ProgramData of this process to a new folder with a false
  config.xml (the port of the false server and a false key). The module reads
  config.xml from ProgramData, thus it cannot find a real key. The test stops if
  ProgramData is not in the work folder. The test sends no request to an app.

  The test writes only into -WorkRoot. It does not delete the folder.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param([string]$WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('arr-api-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))))

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ArrPlan.psm1') -Force

$canary = 'CANARY0123456789abcdef0123456789'
$script:FailCount = 0
$script:CaseNumber = 0
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Condition, [string]$Detail = '')
    $passed = $false
    try { $passed = [bool](& $Condition) } catch { $passed = $false; $Detail = $_.Exception.Message }
    if (-not $passed) { $script:FailCount++ }
    Write-Output ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $Name)
    if (-not $passed -and $Detail) { Write-Output "      $Detail" }
}

# --- False data -------------------------------------------------------------------
function New-Condition {
    param([string]$Name, [string]$Implementation, $Value, [bool]$Negate = $false, [bool]$Required = $true)
    [ordered]@{ name = $Name; implementation = $Implementation; negate = $Negate; required = $Required; fields = @([ordered]@{ name = 'value'; value = $Value }) }
}

function New-Format {
    param([string]$Name, [object[]]$Condition)
    [ordered]@{ name = $Name; includeCustomFormatWhenRenaming = $false; specifications = @($Condition) }
}

function New-FakeData {
    # New objects for each test case.
    $multi = New-Format 'MULTi' @(New-Condition 'Multi' 'ReleaseTitleSpecification' '\bMULTi\b')
    $aac = New-Format 'AAC' @(New-Condition 'AAC' 'ReleaseTitleSpecification' '\bAAC\b')
    # An existing group with an optional Negate, as the CF "SDR" of the real apps.
    $sdr = New-Format 'SDR' @(
        New-Condition 'SDR word' 'ReleaseTitleSpecification' '\bSDR\b' $false $false
        New-Condition 'Not HDR' 'ReleaseTitleSpecification' '\bHDR\b' $true $false)
    $web = New-Format 'WEB source' @(New-Condition 'WEB' 'SourceSpecification' 7)
    $unicode = New-Format 'Japanese title' @(New-Condition 'JP' 'ReleaseTitleSpecification' '日本語|ジャパン')

    $formats = @()
    $id = 0
    foreach ($definition in $multi, $aac, $sdr, $web, $unicode) {
        $id++
        $object = $definition | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $object | Add-Member -NotePropertyName id -NotePropertyValue $id
        $formats += $object
    }
    # Nested lists with 0 entries and with 1 entry, to test the round trip.
    $items = '[{"quality":{"id":1,"name":"SDTV","source":"television","resolution":480},"items":[],"allowed":false},{"id":1000,"name":"WEB 1080p","items":[{"quality":{"id":3,"name":"WEBDL-1080p","source":"web","resolution":1080},"items":[],"allowed":true}],"allowed":true}]'
    $newProfile = {
        param($ProfileId, $Name, [int[]]$Score, [bool]$Language)
        $body = [ordered]@{
            name = $Name; upgradeAllowed = $true; cutoff = 1000; items = ($items | ConvertFrom-Json)
            minFormatScore = 0; cutoffFormatScore = 10000; minUpgradeFormatScore = 1
            formatItems = @(for ($index = 0; $index -lt $formats.Count; $index++) { [pscustomobject]@{ format = $formats[$index].id; name = $formats[$index].name; score = $Score[$index] } })
        }
        if ($Language) { $body.language = [pscustomobject]@{ id = -1; name = 'Any' } }
        $body.id = $ProfileId
        [pscustomobject]$body
    }
    $copy = { param($value) @(ConvertTo-Json -InputObject @($value) -Depth 16 | ConvertFrom-Json) }

    $series = '[{"id":10,"title":"Alpha Show","year":2020,"monitored":true,"qualityProfileId":7,"seriesType":"anime","path":"X:\\TV\\Alpha","seasons":[{"seasonNumber":0,"monitored":false},{"seasonNumber":1,"monitored":true},{"seasonNumber":2,"monitored":false}]},{"id":11,"title":"Beta Show","year":2021,"monitored":false,"qualityProfileId":4,"seriesType":"standard","path":"X:\\TV\\Beta","seasons":[{"seasonNumber":1,"monitored":true}]},{"id":12,"title":"Gamma Show","year":2022,"monitored":true,"qualityProfileId":4,"seriesType":"standard","path":"X:\\TV\\Gamma","seasons":[{"seasonNumber":1,"monitored":true}]}]' | ConvertFrom-Json
    $episodes = @(
        foreach ($entry in @(@(101, 1, 1, $true), @(102, 1, 2, $true), @(103, 2, 1, $false), @(104, 2, 2, $false))) {
            [pscustomobject]@{ id = $entry[0]; seriesId = 10; seasonNumber = $entry[1]; episodeNumber = $entry[2]; title = "Episode $($entry[0])"; monitored = $entry[3]; hasFile = $true; overview = 'not in the output of the tool' }
        })
    $movies = '[{"id":20,"title":"Delta Movie","year":2019,"monitored":false,"qualityProfileId":4,"path":"X:\\Movies\\Delta","hasFile":true},{"id":21,"title":"Epsilon Movie","year":2018,"monitored":true,"qualityProfileId":9,"path":"X:\\Movies\\Epsilon","hasFile":true}]' | ConvertFrom-Json

    @{
        sonarr = @{
            status = [pscustomobject]@{ appName = 'Sonarr'; version = '4.0.20.3014' }
            customformat = & $copy $formats
            qualityprofile = @((& $newProfile 4 'HD' @(0, 100, 5, 10, 0) $false), (& $newProfile 7 'Anime Test' @(300, 1000, 0, 20, 0) $false))
            mediamanagement = [pscustomobject]@{ recycleBin = 'X:\Bin'; id = 1 }
            delayprofile = @(); releaseprofile = @(); rootfolder = @()
            series = @($series); episode = @($episodes)
        }
        radarr = @{
            status = [pscustomobject]@{ appName = 'Radarr'; version = '7.0.3.10918' }
            customformat = & $copy $formats
            qualityprofile = @((& $newProfile 4 'HD' @(0, 100, 5, 10, 0) $true), (& $newProfile 9 'Anime Test' @(300, 1000, 0, 20, 0) $true))
            mediamanagement = [pscustomobject]@{ recycleBin = ''; id = 1 }
            delayprofile = @(); rootfolder = @()
            movie = @($movies)
        }
    }
}

function Get-FullBatch {
    # One batch with each type of operation.
    @{
        operations = @(
            @{ op = 'monitorMovies'; app = 'radarr'; ids = @(20); monitored = $true }
            @{ op = 'updateQualityProfile'; app = 'sonarr'; id = 7; set = @{ minFormatScore = 100; cutoffFormatScore = 12000 }; scores = @(@{ ref = 'flac'; score = 2250 }, @{ formatId = 2; score = 500 }) }
            @{ op = 'createCustomFormat'; app = 'sonarr'; ref = 'flac'; definition = (New-Format 'FLAC' @(New-Condition 'FLAC' 'ReleaseTitleSpecification' '\bFLAC(\b|\d)')) }
            @{ op = 'updateCustomFormat'; app = 'sonarr'; id = 1; definition = (New-Format 'MULTi' @((New-Condition 'Multi' 'ReleaseTitleSpecification' '\bMULTi\b'), (New-Condition 'Not Multi Subs' 'ReleaseTitleSpecification' '\bMulti.?Subs?\b' $true $true))) }
            @{ op = 'updateQualityProfile'; app = 'radarr'; id = 4; set = @{ upgradeAllowed = $false } ; scores = @(@{ formatId = 2; score = 150 }) }
            @{ op = 'monitorSeries'; app = 'sonarr'; ids = @(12); monitored = $false }
            @{ op = 'monitorSeason'; app = 'sonarr'; seriesId = 10; seasonNumber = 1; monitored = $false }
            @{ op = 'monitorEpisodes'; app = 'sonarr'; seriesId = 10; ids = @(101, 102); monitored = $false }
        )
        parseTests = @(
            @{ app = 'sonarr'; kind = 'match'; customFormat = 'FLAC'; title = 'Alpha.Show.S01E01.1080p.FLAC-GRP'; expectedScore = 2250 }
            @{ app = 'sonarr'; kind = 'match'; customFormat = 'MULTi'; title = 'Alpha.Show.S01E01.MULTi.1080p-GRP'; expectedScore = 300 }
            @{ app = 'sonarr'; kind = 'noMatch'; customFormat = 'MULTi'; title = 'Alpha.Show.S01E01.Multi.Subs.1080p-GRP' }
            @{ app = 'sonarr'; kind = 'match'; customFormat = 'AAC'; title = 'Alpha.Show.S01E01.AAC-GRP'; expectedScore = 500 }
            @{ app = 'sonarr'; kind = 'unchanged'; title = 'Alpha.Show.S01E02.1080p.WEB-GRP' }
            @{ app = 'sonarr'; kind = 'unchanged'; title = 'Beta.Show.S01E01.720p.HDTV-GRP' }
            # 'SDR' has an optional Negate, thus it matches this title too: 150 + 5.
            @{ app = 'radarr'; kind = 'match'; customFormat = 'AAC'; title = 'Delta.Movie.2019.AAC-GRP'; expectedScore = 155 }
            @{ app = 'radarr'; kind = 'unchanged'; title = 'Delta.Movie.2019.1080p-GRP' }
            @{ app = 'radarr'; kind = 'unchanged'; title = 'Epsilon.Movie.2018.MULTi-GRP' }
        )
    }
}

# --- False server and tool calls -----------------------------------------------
function Get-FreePort {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    $port
}

New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$WorkRoot = (Resolve-Path -LiteralPath $WorkRoot).ProviderPath
$fakeProgramData = Join-Path $WorkRoot 'ProgramData'
$ports = @{ sonarr = Get-FreePort; radarr = Get-FreePort }
foreach ($app in 'Sonarr', 'Radarr') {
    $folder = Join-Path $fakeProgramData $app
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $folder 'config.xml'), "<Config><Port>$($ports[$app.ToLower()])</Port><UrlBase></UrlBase><ApiKey>$canary</ApiKey></Config>", $utf8NoBom)
}

$listener = [System.Net.HttpListener]::new()
foreach ($port in $ports.Values) { $listener.Prefixes.Add("http://127.0.0.1:$port/") }
$listener.Start()
$shared = [hashtable]::Synchronized(@{
        Listener = $listener
        PortApp  = @{ $ports.sonarr = 'sonarr'; $ports.radarr = 'radarr' }
        Key      = $canary
        Data     = New-FakeData
        Log      = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Errors   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        Faults   = @()
    })
$server = Start-ThreadJob -FilePath (Join-Path $PSScriptRoot 'Start-FakeArrServer.ps1') -ArgumentList $shared

function Invoke-Tool {
    param([string]$Script, [string[]]$Argument)
    if (-not $env:ProgramData.StartsWith($WorkRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'ProgramData is not in the work folder. The test stops.' }
    $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot $Script) @Argument 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = @($output) -join "`n" }
}

function New-Case {
    # New data, a snapshot and a plan. The request log is empty after this function.
    param([hashtable]$Change)
    $script:CaseNumber++
    $folder = Join-Path $WorkRoot ('case{0:D2}' -f $script:CaseNumber)
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $shared.Data = New-FakeData
    $shared.Faults = @()
    $snapshot = Invoke-Tool 'Get-ArrSnapshot.ps1' @('-App', 'sonarr,radarr', '-SeriesId', '10,12', '-OutputRoot', (Join-Path $folder 'snapshots'))
    if ($snapshot.ExitCode -ne 0) { throw "The snapshot failed: $($snapshot.Text)" }
    $snapshotPath = (Get-ChildItem -LiteralPath (Join-Path $folder 'snapshots') -Directory)[0].FullName
    $changePath = Join-Path $folder 'change.json'
    [System.IO.File]::WriteAllText($changePath, (ConvertTo-Json -InputObject $Change -Depth 16), $utf8NoBom)
    $planPath = Join-Path $folder 'plan.json'
    $made = Invoke-Tool 'New-ArrPlan.ps1' @('-ChangePath', $changePath, '-SnapshotPath', $snapshotPath, '-OutputPath', $planPath)
    if ($made.ExitCode -ne 0) { throw "New-ArrPlan failed: $($made.Text)" }
    $entry = $null
    while ($shared.Log.TryDequeue([ref]$entry)) { }
    [pscustomobject]@{
        Folder = $folder; Snapshot = $snapshotPath; PlanPath = $planPath
        Hash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
        Original = Get-DataKey
    }
}

function Invoke-Apply {
    param($Case, [string]$Hash = $Case.Hash)
    $result = Invoke-Tool 'Invoke-ArrPlan.ps1' @('-PlanPath', $Case.PlanPath, '-PlanSha256', $Hash,
        '-RunRoot', (Join-Path $Case.Folder 'runs'), '-SnapshotRoot', (Join-Path $Case.Folder 'final'))
    $requests = @($shared.Log.ToArray())
    $result | Add-Member -NotePropertyName Request -NotePropertyValue $requests
    $result | Add-Member -NotePropertyName Write -NotePropertyValue @($requests | Where-Object Method -NE 'GET') -PassThru
}

function Get-DataKey {
    # The canonical text of each object of the false server that a write can change.
    $key = [ordered]@{}
    foreach ($app in 'sonarr', 'radarr') {
        $data = $shared.Data[$app]
        foreach ($format in $data.customformat) { $key["$app/cf/$($format.id)"] = Get-ArrFormatKey -CustomFormat $format }
        foreach ($qualityProfile in $data.qualityprofile) {
            $core = $qualityProfile | Select-Object -ExcludeProperty formatItems -Property *
            $key["$app/profile/$($qualityProfile.id)"] = ConvertTo-ArrCanonical -Value $core
            foreach ($item in $qualityProfile.formatItems) { $key["$app/score/$($qualityProfile.id)/$($item.format)"] = "$($item.score)" }
        }
        $listName = if ($app -eq 'sonarr') { 'series' } else { 'movie' }
        $key["$app/$listName"] = ConvertTo-ArrCanonical -Value @($data[$listName])
        if ($app -eq 'sonarr') { $key['sonarr/episode'] = ConvertTo-ArrCanonical -Value @($data.episode) }
    }
    $key
}

function Get-ChangedKey {
    param($Before, $After)
    $names = @($Before.Keys) + @($After.Keys) | Select-Object -Unique
    @($names | Where-Object { -not $Before.Contains($_) -or -not $After.Contains($_) -or $Before[$_] -cne $After[$_] })
}

function Test-OnlyNewFormatLeft {
    # After a restore, the only difference is the new custom format with the score 0.
    param($Case, [int]$NewId = 6)
    $now = Get-DataKey
    $changed = @(Get-ChangedKey $Case.Original $now)
    $allowed = @("sonarr/cf/$NewId", "sonarr/score/4/$NewId", "sonarr/score/7/$NewId")
    $unexpected = @($changed | Where-Object { $_ -notin $allowed })
    $unexpected.Count -eq 0 -and $now.Contains("sonarr/cf/$NewId") -and $now["sonarr/score/4/$NewId"] -eq '0' -and $now["sonarr/score/7/$NewId"] -eq '0'
}

function New-Fault {
    param([string]$Method, [string]$Path, [string]$Mode, [string]$App = 'sonarr', [int]$From = 1, [int]$To = 1, [int]$ProfileId = 0, [int]$FormatId = 0, [int]$Score = 0)
    [pscustomobject]@{ App = $App; Method = $Method; Path = $Path; Mode = $Mode; From = $From; To = $To; Count = 0; ProfileId = $ProfileId; FormatId = $FormatId; Score = $Score }
}

$oldProgramData = $env:ProgramData
try {
    $env:ProgramData = $fakeProgramData
    $env:NO_COLOR = '1'

    # --- 1. The full batch -------------------------------------------------------
    $case = New-Case (Get-FullBatch)
    $show = Invoke-Tool 'Show-ArrPlan.ps1' @('-PlanPath', $case.PlanPath, '-RecyclarrDir', (Join-Path $case.Folder 'no-recyclarr'))
    Test-Case 'Show: a correct plan gives the table, the hash and the command' { $show.ExitCode -eq 0 -and $show.Text.Contains($case.Hash) -and $show.Text.Contains('Invoke-ArrPlan.ps1') } $show.Text
    Test-Case 'Show: it has the three necessary warnings' { $show.Text -match 'REPLACES a file' -and $show.Text -match 'NO Recycling Bin' -and $show.Text -match 'QUALITY first' } $show.Text
    Test-Case 'Show: an unchanged optional Negate group is not an error' { $show.Text -notmatch 'has errors' } $show.Text
    Test-Case 'Show: no season warning if the plan also lists the episodes' { $show.Text -notmatch 'episode\(s\) keep' } $show.Text
    Test-Case 'Show sends no request' { $shared.Log.Count -eq 0 }
    $recyclarrDir = Join-Path $case.Folder 'recyclarr'
    New-Item -ItemType Directory -Path $recyclarrDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $recyclarrDir 'sonarr.yml'), "      - trash_ids:`n          - a50b8a0c62274a7c38b09a9619ba9d86 # AAC`n          - a570d4a0e56a2874b64e5bfa55202a1b # FLAC`n", $utf8NoBom)
    $show = Invoke-Tool 'Show-ArrPlan.ps1' @('-PlanPath', $case.PlanPath, '-RecyclarrDir', $recyclarrDir)
    Test-Case 'Show: it tells which custom format Recyclarr manages' {
        $show.Text -match "sonarr 'FLAC': MANAGED by Recyclarr" -and $show.Text -match "sonarr 'AAC': managed by Recyclarr \(definition only\)" -and
        $show.Text -match "sonarr 'MULTi': not in the Recyclarr list" -and $show.Text -match "radarr 'AAC': UNKNOWN"
    } $show.Text

    $apply = Invoke-Apply $case
    Test-Case 'Full batch: exit code 0' { $apply.ExitCode -eq 0 } $apply.Text
    $sonarr = $shared.Data.sonarr
    $new = @($sonarr.customformat | Where-Object name -EQ 'FLAC')
    $anime = @($sonarr.qualityprofile | Where-Object id -EQ 7)[0]
    Test-Case 'Full batch: the new custom format and its scores are correct' {
        $new.Count -eq 1 -and @($anime.formatItems | Where-Object format -EQ $new[0].id)[0].score -eq 2250 -and
        @($sonarr.qualityprofile[0].formatItems | Where-Object format -EQ $new[0].id)[0].score -eq 0
    }
    Test-Case 'Full batch: only the planned objects changed' {
        $expected = @('sonarr/cf/1', 'sonarr/cf/6', 'sonarr/score/4/6', 'sonarr/score/7/6', 'sonarr/score/7/2', 'sonarr/profile/7', 'sonarr/series', 'sonarr/episode', 'radarr/profile/4', 'radarr/score/4/2', 'radarr/movie')
        $changed = @(Get-ChangedKey $case.Original (Get-DataKey))
        @($changed | Where-Object { $_ -notin $expected }).Count -eq 0 -and @($expected | Where-Object { $_ -notin $changed }).Count -eq 0
    } ((Get-ChangedKey $case.Original (Get-DataKey)) -join ', ')
    Test-Case 'Full batch: the monitor flags are correct, and the other episodes did not change' {
        -not $sonarr.series[2].monitored -and -not $sonarr.series[0].seasons[1].monitored -and
        @($sonarr.episode | Where-Object monitored).Count -eq 0 -and $shared.Data.radarr.movie[0].monitored
    }
    Test-Case 'Full batch: the order is monitor off, new CF, changed CF, profiles, monitor on' {
        $sequence = @($apply.Write | ForEach-Object { "$($_.Method) $($_.Path)" })
        ($sequence -join ';') -ceq 'PUT series/editor;POST seasonpass;PUT episode/monitor;POST customformat;PUT customformat/1;PUT qualityprofile/7;PUT qualityprofile/4;PUT movie/editor'
    } (@($apply.Write | ForEach-Object { "$($_.Method) $($_.Path)" }) -join ';')
    Test-Case 'Full batch: a monitor body has only ids and flags' {
        $bodies = @($apply.Write | Where-Object { $_.Path -in 'series/editor', 'seasonpass', 'episode/monitor', 'movie/editor' } | ForEach-Object Body)
        $bodies -ccontains '{"seriesIds":[12],"monitored":false}' -and $bodies -ccontains '{"series":[{"id":10,"seasons":[{"seasonNumber":1,"monitored":false}]}]}' -and
        $bodies -ccontains '{"episodeIds":[101,102],"monitored":false}' -and $bodies -ccontains '{"movieIds":[20],"monitored":true}'
    } (@($apply.Write | ForEach-Object Body | Where-Object Length -LT 200) -join ' ')
    Test-Case 'Full batch: text that is not ASCII stays correct' { @($sonarr.customformat | Where-Object id -EQ 5)[0].specifications[0].fields[0].value -ceq '日本語|ジャパン' }
    Test-Case 'Full batch: the run folder has the plan, the backup, the journal and the result' {
        $run = (Get-ChildItem -LiteralPath (Join-Path $case.Folder 'runs') -Directory)[0].FullName
        (Test-Path (Join-Path $run 'plan.json')) -and (Test-Path (Join-Path $run 'backup' 'sonarr-qualityprofile.json')) -and
        (Test-Path (Join-Path $run 'journal.jsonl')) -and (Get-Content (Join-Path $run 'result.json') -Raw | ConvertFrom-Json).outcome -eq 'applied'
    }
    Test-Case 'Full batch: there is a final snapshot with the episodes' { @(Get-ChildItem -LiteralPath (Join-Path $case.Folder 'final') -Recurse -Filter 'sonarr-episode-10.json').Count -eq 1 } $apply.Text
    $allApplyRequests = $apply.Request

    # --- 2 to 6. Stops before the first write -----------------------------------
    $case = New-Case (Get-FullBatch)
    $apply = Invoke-Apply $case -Hash ('0' * 64)
    Test-Case 'Incorrect hash: exit code 3 and no request' { $apply.ExitCode -eq 3 -and $apply.Request.Count -eq 0 } $apply.Text

    $case = New-Case (Get-FullBatch)
    Add-Content -LiteralPath (Join-Path $case.Snapshot 'sonarr-series.json') -Value ' '
    $apply = Invoke-Apply $case
    Test-Case 'Changed snapshot file: exit code 3 and no request' { $apply.ExitCode -eq 3 -and $apply.Request.Count -eq 0 -and $apply.Text -match 'SHA-256' } $apply.Text

    $case = New-Case (Get-FullBatch)
    $shared.Data.sonarr.qualityprofile[1].formatItems[3].score = 999
    $apply = Invoke-Apply $case
    Test-Case 'Live drift of one score: exit code 3 and no write' { $apply.ExitCode -eq 3 -and $apply.Write.Count -eq 0 -and $apply.Text -match 'sonarr/profile/7/score/4' } $apply.Text

    $case = New-Case (Get-FullBatch)
    $shared.Data.sonarr.episode[0].monitored = $false
    $apply = Invoke-Apply $case
    Test-Case 'Live drift of one episode: exit code 3 and no write' { $apply.ExitCode -eq 3 -and $apply.Write.Count -eq 0 } $apply.Text

    $case = New-Case (Get-FullBatch)
    $shared.Data.radarr.status.version = '7.9.9.1'
    $apply = Invoke-Apply $case
    Test-Case 'New version of an app: exit code 3 and no write' { $apply.ExitCode -eq 3 -and $apply.Write.Count -eq 0 -and $apply.Text -match 'verified for' } $apply.Text

    $change = Get-FullBatch
    $change.parseTests[4].title = 'Unknown.Show.S01E01-GRP'
    $case = New-Case $change
    $apply = Invoke-Apply $case
    Test-Case 'Parse title with no library item: exit code 3 and no write' { $apply.ExitCode -eq 3 -and $apply.Write.Count -eq 0 } $apply.Text

    # --- 7 to 13. A failure and a complete restore ------------------------------
    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(New-Fault PUT 'qualityprofile/7' error)
    $apply = Invoke-Apply $case
    Test-Case 'HTTP 500 in the middle: exit code 1' { $apply.ExitCode -eq 1 -and $apply.Text -match 'restore is complete' } $apply.Text
    Test-Case 'HTTP 500 in the middle: only the new custom format stays, with score 0' { Test-OnlyNewFormatLeft $case } ((Get-ChangedKey $case.Original (Get-DataKey)) -join ', ')
    Test-Case 'HTTP 500 in the middle: no later step started' { @($apply.Write | Where-Object App -EQ 'radarr').Count -eq 0 }

    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(New-Fault POST 'customformat' applyThenError)
    $apply = Invoke-Apply $case
    Test-Case 'Lost answer of a new custom format: restored, the format stays with score 0' { $apply.ExitCode -eq 1 -and (Test-OnlyNewFormatLeft $case) } $apply.Text

    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(New-Fault PUT 'qualityprofile/7' applyThenError)
    $apply = Invoke-Apply $case
    Test-Case 'Lost answer of a profile write: restored' { $apply.ExitCode -eq 1 -and (Test-OnlyNewFormatLeft $case) } $apply.Text

    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(New-Fault PUT 'episode/monitor' ignore)
    $apply = Invoke-Apply $case
    Test-Case 'Ignored write: the read finds it, and the batch is restored' { $apply.ExitCode -eq 1 -and $apply.Text -match 'sonarr/episode/101/monitored' -and @(Get-ChangedKey $case.Original (Get-DataKey)).Count -eq 0 } $apply.Text

    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(New-Fault PUT 'qualityprofile/7' collateral -ProfileId 7 -FormatId 4 -Score 7777)
    $apply = Invoke-Apply $case
    Test-Case 'Unplanned score in the written profile: found and restored' { $apply.ExitCode -eq 1 -and $apply.Text -match 'sonarr/profile/7/score/4' -and (Test-OnlyNewFormatLeft $case) } $apply.Text

    $change = Get-FullBatch
    $change.parseTests[0].expectedScore = 1
    $case = New-Case $change
    $apply = Invoke-Apply $case
    Test-Case 'Failed parse test after all writes: all values are restored' { $apply.ExitCode -eq 1 -and $apply.Write.Count -gt 8 -and (Test-OnlyNewFormatLeft $case) } $apply.Text

    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(New-Fault PUT 'movie/editor' applyThenError -App radarr)
    $apply = Invoke-Apply $case
    Test-Case 'Failure of the last step: all values are restored' { $apply.ExitCode -eq 1 -and (Test-OnlyNewFormatLeft $case) } $apply.Text
    $allApplyRequests += $apply.Request

    # --- 14 and 15. A restore that is not complete -------------------------------
    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(
        New-Fault PUT 'movie/editor' error -App radarr
        New-Fault PUT 'qualityprofile/7' error -From 2 -To 99)
    $apply = Invoke-Apply $case
    Test-Case 'Failed restore: exit code 2 and a clear text' { $apply.ExitCode -eq 2 -and $apply.Text -match 'RESTORE IS NOT COMPLETE' -and $apply.Text -match 'sonarr/profile/7/score/2' -and $apply.Text -match 'Backup: ' } $apply.Text
    Test-Case 'Failed restore: the script still restores the other objects' {
        $now = Get-DataKey
        $now['sonarr/cf/1'] -ceq $case.Original['sonarr/cf/1'] -and $now['sonarr/series'] -ceq $case.Original['sonarr/series'] -and
        $now['sonarr/episode'] -ceq $case.Original['sonarr/episode'] -and $now['radarr/profile/4'] -ceq $case.Original['radarr/profile/4']
    }

    $case = New-Case (Get-FullBatch)
    $shared.Faults = @(New-Fault PUT 'qualityprofile/7' collateral -ProfileId 4 -FormatId 4 -Score 7777)
    $apply = Invoke-Apply $case
    Test-Case 'Unplanned score in a profile that the batch did not write: exit code 2' { $apply.ExitCode -eq 2 -and $apply.Text -match 'sonarr/profile/4/score/4' } $apply.Text
    $allApplyRequests += $apply.Request

    # --- Safety of all requests ---------------------------------------------------
    Test-Case 'No request used a method other than GET, POST and PUT' { @($allApplyRequests | Where-Object { $_.Method -cnotin 'GET', 'POST', 'PUT' }).Count -eq 0 -and -not (@($shared.Errors.ToArray()) -match 'FORBIDDEN') }
    Test-Case 'No body had a key that moves or deletes files' { @($allApplyRequests | Where-Object { $_.Body -match '(?i)"(moveFiles|rootFolderPath|deleteFiles|monitoringOptions|path|addImportListExclusion)"\s*:' }).Count -eq 0 }
    Test-Case 'No write path starts a command or a search' { @($allApplyRequests | Where-Object { $_.Method -ne 'GET' -and $_.Path -notmatch '\A(customformat(/\d+)?|qualityprofile/\d+|series/editor|seasonpass|episode/monitor|movie/editor)\z' }).Count -eq 0 }
    $files = @(Get-ChildItem -LiteralPath $WorkRoot -Recurse -File | Where-Object FullName -NotLike "$fakeProgramData*")
    Test-Case "The false key is in no output file ($($files.Count) files)" { @($files | Select-String -SimpleMatch $canary -List).Count -eq 0 }

    # --- Checks of a plan -----------------------------------------------------------
    $case = New-Case (Get-FullBatch)
    $verified = @{ sonarr = '4.0.20.3014'; radarr = '7.0.3.10918' }
    function Get-CheckError {
        param([hashtable]$Change)
        $plan = ConvertFrom-ArrJson -Text (ConvertTo-Json -Depth 16 -InputObject ([ordered]@{ planVersion = 1; snapshot = $case.Snapshot; snapshotFiles = @{}; operations = @($Change.operations); parseTests = @($Change.parseTests) }))
        $shape = @(Get-ArrPlanShapeError -Plan $plan)
        if ($shape.Count) { return $shape -join ' / ' }
        $hashes = [ordered]@{}
        foreach ($file in Get-ChildItem -LiteralPath $case.Snapshot -Filter '*-*.json') { $hashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName).Hash }
        $plan.snapshotFiles = [pscustomobject]$hashes
        @((Test-ArrPlan -Plan $plan -State (Read-ArrBaseline -Plan $plan) -VerifiedVersion $verified).Errors) -join ' / '
    }
    function Test-Rejected {
        param([string]$Name, [string]$Pattern, [hashtable]$Change)
        $text = Get-CheckError -Change $Change
        Test-Case $Name { $text -match $Pattern } $text
    }
    $oneOperation = { param($operation, $tests = @()) @{ operations = @($operation); parseTests = @($tests) } }

    Test-Case 'Check: the full batch has no error' { (Get-CheckError -Change (Get-FullBatch)) -eq '' } (Get-CheckError -Change (Get-FullBatch))
    # The Negate rule. 'a' and 'b' are normal conditions, 'n' is a Negate.
    # New-Condition: name, type, value, negate, required.
    $negateRule = 'each of them must be Required'
    $newFormat = { param([object[]]$condition) & $oneOperation @{ op = 'createCustomFormat'; app = 'sonarr'; ref = 'x'; definition = (New-Format 'New' $condition) } }
    $title = 'ReleaseTitleSpecification'
    Test-Rejected 'Negate rule: a Required Negate next to an optional condition' $negateRule (& $newFormat @((New-Condition 'a' $title 'a' $false $false), (New-Condition 'n' $title 'n' $true $true)))
    Test-Rejected 'Negate rule: a Required Negate next to 2 optional conditions' $negateRule (& $newFormat @((New-Condition 'a' $title 'a' $false $false), (New-Condition 'b' $title 'b' $false $false), (New-Condition 'n' $title 'n' $true $true)))
    Test-Rejected 'Negate rule: an optional Negate next to a Required condition' $negateRule (& $newFormat @((New-Condition 'a' $title 'a' $false $true), (New-Condition 'n' $title 'n' $true $false)))
    Test-Rejected 'Negate rule: both conditions are optional' $negateRule (& $newFormat @((New-Condition 'a' $title 'a' $false $false), (New-Condition 'n' $title 'n' $true $false)))
    foreach ($accepted in @(
            @{ Name = 'a Negate and a condition that are both Required'; Condition = @((New-Condition 'a' $title 'a' $false $true), (New-Condition 'n' $title 'n' $true $true)) }
            @{ Name = '2 optional conditions with no Negate'; Condition = @((New-Condition 'a' $title 'a' $false $false), (New-Condition 'b' $title 'b' $false $false)) }
            @{ Name = 'a Negate alone, optional'; Condition = @(New-Condition 'n' $title 'n' $true $false) }
            @{ Name = 'a Negate next to an optional condition of an other type'; Condition = @((New-Condition 'n' $title 'n' $true $true), (New-Condition 's' 'SourceSpecification' 7 $false $false)) })) {
        $text = Get-CheckError -Change (& $newFormat $accepted.Condition)
        # The plan has no parse tests, thus other errors are correct here.
        Test-Case "Negate rule accepts: $($accepted.Name)" { $text -notmatch $negateRule -and $text -match 'needs a parse test' } $text
    }
    Test-Rejected 'Negate rule: a change in an existing unsafe group' $negateRule (& $oneOperation @{ op = 'updateCustomFormat'; app = 'sonarr'; id = 3; definition = (New-Format 'SDR' @((New-Condition 'SDR word' $title '\bSDR2\b' $false $false), (New-Condition 'Not HDR' $title '\bHDR\b' $true $false))) })
    Test-Rejected 'Check: a new custom format that goes into file names' 'includeCustomFormatWhenRenaming = false' (& $oneOperation @{ op = 'createCustomFormat'; app = 'sonarr'; ref = 'x'; definition = @{ name = 'New'; includeCustomFormatWhenRenaming = $true; specifications = @(New-Condition 'a' 'ReleaseTitleSpecification' 'a') } })
    Test-Rejected 'Check: a name that exists' 'two custom formats' (& $oneOperation @{ op = 'createCustomFormat'; app = 'sonarr'; ref = 'x'; definition = (New-Format 'aac' @(New-Condition 'a' 'ReleaseTitleSpecification' 'a')) })
    Test-Rejected 'Check: an incorrect type of a field value' 'needs a number' (& $oneOperation @{ op = 'createCustomFormat'; app = 'sonarr'; ref = 'x'; definition = (New-Format 'New' @(New-Condition 'a' 'SourceSpecification' 'web')) })
    Test-Rejected 'Check: a condition type that the snapshot does not have' 'cannot check' (& $oneOperation @{ op = 'createCustomFormat'; app = 'sonarr'; ref = 'x'; definition = (New-Format 'New' @(New-Condition 'a' 'SizeSpecification' 1)) })
    Test-Rejected 'Check: a regular expression that is not valid' 'not valid' (& $oneOperation @{ op = 'createCustomFormat'; app = 'sonarr'; ref = 'x'; definition = (New-Format 'New' @(New-Condition 'a' 'ReleaseTitleSpecification' '(')) })
    Test-Rejected 'Check: a score that does not change' 'does not change' (& $oneOperation @{ op = 'updateQualityProfile'; app = 'sonarr'; id = 7; scores = @(@{ formatId = 2; score = 1000 }) })
    Test-Rejected 'Check: minUpgradeFormatScore 0' '1 or more' (& $oneOperation @{ op = 'updateQualityProfile'; app = 'sonarr'; id = 7; set = @{ minUpgradeFormatScore = 0 } })
    Test-Rejected 'Check: a minimum score that no release can have' 'no release' (& $oneOperation @{ op = 'updateQualityProfile'; app = 'sonarr'; id = 7; set = @{ minFormatScore = 999999 } })
    Test-Rejected 'Check: a field of the profile that is out of scope' 'not permitted' (& $oneOperation @{ op = 'updateQualityProfile'; app = 'sonarr'; id = 7; set = @{ cutoff = 1 } })
    Test-Rejected 'Check: an operation with an unknown key' 'not permitted' (& $oneOperation @{ op = 'monitorSeries'; app = 'sonarr'; ids = @(12); monitored = $false; moveFiles = $true })
    Test-Rejected 'Check: an unknown operation' 'unknown operation' (& $oneOperation @{ op = 'deleteCustomFormat'; app = 'sonarr'; id = 1 })
    Test-Rejected 'Check: a write to Prowlarr' 'not permitted for the app' (& $oneOperation @{ op = 'monitorSeries'; app = 'prowlarr'; ids = @(1); monitored = $false })
    Test-Rejected 'Check: a monitor flag that does not change' 'already has' (& $oneOperation @{ op = 'monitorEpisodes'; app = 'sonarr'; seriesId = 10; ids = @(103); monitored = $false })
    Test-Rejected 'Check: a score change with no parse tests' "needs a parse test of the kind 'match'" (& $oneOperation @{ op = 'updateQualityProfile'; app = 'sonarr'; id = 7; scores = @(@{ formatId = 2; score = 1 }) })
    Test-Rejected 'Check: only one unchanged title' "2 parse tests of the kind 'unchanged'" (& $oneOperation @{ op = 'updateQualityProfile'; app = 'sonarr'; id = 7; scores = @(@{ formatId = 2; score = 1 }) } @(
            @{ app = 'sonarr'; kind = 'match'; customFormat = 'AAC'; title = 'a' }, @{ app = 'sonarr'; kind = 'unchanged'; title = 'b' }, @{ app = 'sonarr'; kind = 'unchanged'; title = 'b' }))
    $seasonOnly = Get-CheckError -Change (& $oneOperation @{ op = 'monitorSeason'; app = 'sonarr'; seriesId = 10; seasonNumber = 1; monitored = $false })
    Test-Case 'Check: a season change alone is permitted' { $seasonOnly -eq '' } $seasonOnly
    $seasonChange = @{ operations = @(@{ op = 'monitorSeason'; app = 'sonarr'; seriesId = 10; seasonNumber = 1; monitored = $false }); parseTests = @() }
    $case2 = New-Case $seasonChange
    $show = Invoke-Tool 'Show-ArrPlan.ps1' @('-PlanPath', $case2.PlanPath)
    Test-Case 'Show: it warns about the episodes that keep the other value' { $show.Text -match '2 episode\(s\) keep the other value' } $show.Text
    $apply = Invoke-Apply $case2
    Test-Case 'A season change alone does not change an episode' { $apply.ExitCode -eq 0 -and (Get-DataKey)['sonarr/episode'] -ceq $case2.Original['sonarr/episode'] -and -not $shared.Data.sonarr.series[0].seasons[1].monitored } $apply.Text

    $serverErrors = @($shared.Errors.ToArray())
    Test-Case 'The false server had no error' { $serverErrors.Count -eq 0 } ($serverErrors -join ' / ')
} finally {
    $env:ProgramData = $oldProgramData
    $listener.Stop()
    $server | Wait-Job -Timeout 10 | Out-Null
}

"Work folder: $WorkRoot"
if ($script:FailCount -gt 0) { throw "$($script:FailCount) test(s) failed." }
'All tests passed.'
