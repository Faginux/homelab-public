<#
  Get-ArrSnapshot.ps1  -  v0.3  (2026-11-27).
  Reads the configuration and the monitored flags of Sonarr, Radarr and Prowlarr
  and writes one snapshot folder with one safe JSON file for each resource.

  The script only reads from the apps (GET). It writes only into a new folder
  below -OutputRoot. It does not overwrite and does not delete a file.

  -SeriesId adds the episodes of these Sonarr series. A plan that changes the
  monitored flag of a series, a season or an episode needs them.

  The two list parameters are text. "pwsh -File" gives "a,b" as one text, and a
  number parameter reads the text "1,2" as the number 12.

  The output on the screen has counts only. Read the JSON files for the data.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    # sonarr, radarr, prowlarr. A comma separates the names.
    [string[]]$App = @('sonarr', 'radarr', 'prowlarr'),

    # Sonarr series ids. A comma separates the numbers.
    [string[]]$SeriesId = @(),

    # The parent folder of the snapshots, outside the repo.
    [string]$OutputRoot = 'S:\docker-appdata\arr-api\snapshots'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$appList = @($App -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
foreach ($appName in $appList) {
    if ($appName -notin 'sonarr', 'radarr', 'prowlarr') { throw "'$appName' is not an app of this tool." }
}
if ($appList.Count -eq 0) { throw 'Give one app or more.' }

$seriesList = @($SeriesId -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
foreach ($id in $seriesList) {
    if ($id -notmatch '\A\d{1,9}\z') { throw "'$id' is not a series id." }
}
if ($seriesList.Count -gt 0 -and 'sonarr' -notin $appList) { throw '-SeriesId needs the app sonarr.' }

Import-Module (Join-Path $PSScriptRoot 'ArrApi.psm1') -Force

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$outputDir = Join-Path $OutputRoot $stamp
$suffix = 1
while (Test-Path -LiteralPath $outputDir) {
    $suffix++
    $outputDir = Join-Path $OutputRoot "$stamp-$suffix"
}
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$requests = foreach ($appName in $appList) {
    foreach ($name in Get-ArrResourceName -App $appName) {
        @{ App = $appName; Name = $name; Query = @{}; File = "$appName-$name.json" }
    }
    if ($appName -eq 'sonarr') {
        foreach ($id in $seriesList) {
            @{ App = $appName; Name = 'episode'; Query = @{ QueryValue = $id }; File = "sonarr-episode-$id.json" }
        }
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$summary = [System.Collections.Generic.List[object]]::new()

foreach ($request in $requests) {
    $label = $request.File -replace '\A[a-z]+-|\.json\z'
    try {
        $query = $request.Query
        $result = Get-ArrResourceJson -App $request.App -Name $request.Name @query
        [IO.File]::WriteAllText((Join-Path $outputDir $request.File), $result.Json, $utf8NoBom)
        $summary.Add([pscustomobject]@{ App = $request.App; Resource = $label; Items = $result.Count; Result = 'ok' })
    } catch {
        # The module gives error texts with no data and no key.
        $summary.Add([pscustomobject]@{ App = $request.App; Resource = $label; Items = 0; Result = $_.Exception.Message })
    }
}

$manifest = [ordered]@{
    script  = 'Get-ArrSnapshot.ps1 v0.3'
    created = (Get-Date).ToString('o')
    results = $summary
}
[IO.File]::WriteAllText((Join-Path $outputDir 'manifest.json'), (ConvertTo-Json -InputObject $manifest -Depth 5), $utf8NoBom)

$summary | Format-Table -AutoSize -Wrap | Out-String -Width 160
"Snapshot: $outputDir"
$failed = @($summary | Where-Object Result -ne 'ok').Count
if ($failed -gt 0) { throw "$failed resource(s) failed. Read the table." }
