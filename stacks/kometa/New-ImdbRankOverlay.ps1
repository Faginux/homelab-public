#Requires -Version 7.0
<#
  New-ImdbRankOverlay.ps1  -  v1.0  (2026-11-05).
  IMDb Top 250 position on the rating badge. It is a request of the operator.
  For a title in the IMDb Top 250 the badge shows three lines:
      250      (the Kometa "Top" logo)
      #32      (position in the chart)
      8.9      (IMDb rating)
  Movies and Anime movies use the chart "top_movies". TV series and Anime use
  the chart "top_shows".

  Why a script: Kometa knows if a title is in the Top 250 (the logo changes
  from "IMDb" to "250"), but it does not give the position. The source here is
  the Kometa IMDb service, that is the primary source of Kometa for
  `imdb_chart` (modules/imdb.py, v2.5.4). Thus the position and the "250" logo
  always come from the same data. The service gives `rank` for each title and
  it is refreshed one time each day.

  How the badge is replaced: the default `ratings` puts its overlays in the
  group "rating1_group" (Top variant: weight 110). Kometa keeps one group
  table for all the overlay files of a library (modules/overlays.py), so the
  badge here (same group, weight 200) replaces the Kometa badge only on the
  titles of the chart. It is taller (more space between logo and rating). A
  second text overlay writes the position in that space.

  Data: 1 request for each chart to the service, 1 request for each library
  to Plex (IDs of the titles). Plex read only. A few seconds.
  Output (Kometa reads them as config/overlays-custom/*.yml):
    imdb-rank-<library>.yml   made again at each run, one for each library.
  The files are written only when all the requests are successful.

  Invoke-KometaRun.ps1 starts it before Kometa (Full, and each Quick).
  Exit 0 = files written, 1 = error (old files not changed).

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [hashtable]$LibraryCharts = @{
        'Movies'       = 'top_movies'
        'Anime movies' = 'top_movies'
        'Serie TV'     = 'top_shows'
        'Anime'        = 'top_shows'
    },
    [string]$PlexConfig = 'S:\Scripts\Tmm\plex.config.psd1',
    [string]$OutDir     = 'S:\docker-appdata\kometa\config\overlays-custom',
    [string]$ServiceUrl = 'https://utilities.kometa.wiki/imdb-service/chart',
    # Geometry on the 1000x1500 Kometa canvas. The badge must have the same
    # offsets as the `ratings` default in config.yml (rating1_*_offset). The
    # backdrop goes 15 px (back_padding) out of the offset on each side.
    [int]$BadgeX        = 30,
    [int]$BadgeY        = 150,
    [int]$BadgeHeight   = 220,    # default 160 + space for the position line
    [int]$AddonOffset   = 75,     # default 15 + space for the position line
    [int]$RankY         = 250,    # top of the position text box
    [int]$RankFontSize  = 50,
    [int]$RankBoxHeight = 50
)
$ErrorActionPreference = 'Stop'

function Get-PlexJson([string]$Path) {
    Invoke-RestMethod "$($script:plex.BaseUrl)$Path" -Headers @{ 'X-Plex-Token' = $script:plex.Token; Accept = 'application/json' }
}
function Get-PlexXml([string]$Path) {
    # with JSON + includeGuids Plex returns "Guid" and "guid": ConvertFrom-Json
    # (case-insensitive) loses them. XML does not (same as New-ItaOverlay.ps1).
    [xml](Invoke-WebRequest "$($script:plex.BaseUrl)$Path" -Headers @{ 'X-Plex-Token' = $script:plex.Token }).Content
}

function Get-ChartRanks([string]$Chart) {
    # Returns a hashtable: IMDb ID (tt...) -> rank. Stops on a short chart: a
    # partial answer must not remove the position from the posters.
    $data = Invoke-RestMethod "$ServiceUrl/$Chart" -Headers @{ 'User-Agent' = 'homelab-kometa-rank/1.0' } -TimeoutSec 60
    $results = @($data.results | Where-Object { $_.tconst -and $_.rank })
    if ($results.Count -lt 200) { throw "chart ${Chart}: only $($results.Count) titles (expected 250)" }
    $map = @{}
    foreach ($r in $results) { $map[[string]$r.tconst] = [int]$r.rank }
    # ConvertFrom-Json makes refreshed_at a DateTime: write it in ISO format
    $refreshed = if ($data.refreshed_at -is [datetime]) { $data.refreshed_at.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC' } else { [string]$data.refreshed_at }
    [pscustomobject]@{ Ranks = $map; RefreshedAt = $refreshed }
}

$script:plex = Import-PowerShellDataFile -Path $PlexConfig
$sections = (Get-PlexJson '/library/sections').MediaContainer.Directory

$charts = @{}
foreach ($chart in ($LibraryCharts.Values | Sort-Object -Unique)) { $charts[$chart] = Get-ChartRanks $chart }

# --- Collect all the data first: no file changes if one request fails -------
$files = [System.Collections.Generic.List[object]]::new()
$found = [System.Collections.Generic.List[object]]::new()
foreach ($libName in ($LibraryCharts.Keys | Sort-Object)) {
    $chartName = $LibraryCharts[$libName]
    $chart = $charts[$chartName]
    $sec = $sections | Where-Object { $_.title -eq $libName }
    if (-not $sec) { throw "library '$libName' non trovata in Plex" }
    $isMovie = $sec.type -eq 'movie'
    $plexType = if ($isMovie) { 1 } else { 2 }

    $xml = Get-PlexXml "/library/sections/$($sec.key)/all?type=$plexType&includeGuids=1"
    $nodes = if ($isMovie) { @($xml.MediaContainer.Video) } else { @($xml.MediaContainer.Directory) }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $nodes) {
        if (-not $n) { continue }
        $ids = @($n.Guid | ForEach-Object { $_.id })
        $imdb = ($ids | Where-Object { $_ -like 'imdb://*' } | Select-Object -First 1) -replace '^imdb://'
        if (-not $imdb -or -not $chart.Ranks.ContainsKey($imdb)) { continue }
        $tmdb = ($ids | Where-Object { $_ -like 'tmdb://*' } | Select-Object -First 1) -replace '^tmdb://'
        $tvdb = ($ids | Where-Object { $_ -like 'tvdb://*' } | Select-Object -First 1) -replace '^tvdb://'
        # Builder: the IDs that Plex itself has, as New-ItaOverlay.ps1 does.
        $builder = if ($isMovie -and $tmdb) { "tmdb_movie: $tmdb" }
                   elseif ($isMovie)        { "imdb_id: $imdb" }
                   elseif ($tvdb)           { "tvdb_show: $tvdb" }
                   elseif ($tmdb)           { "tmdb_show: $tmdb" }
                   else                     { $null }
        if (-not $builder) { continue }
        $item = [pscustomobject]@{ Library = $libName; Rank = $chart.Ranks[$imdb]; Title = [string]$n.title; Imdb = $imdb; Builder = $builder }
        $items.Add($item)
        $found.Add($item)
    }

    $slug = ($libName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# GENERATED by stacks/kometa/New-ImdbRankOverlay.ps1 on $(Get-Date -Format 'dd/MM/yyyy HH:mm') - do not edit by hand.")
    [void]$sb.AppendLine("# Library: $libName | chart: $chartName | service refreshed_at: $($chart.RefreshedAt)")
    if ($items.Count -eq 0) {
        [void]$sb.AppendLine('# No title of this library is in the chart.')
    } else {
        [void]$sb.AppendLine('overlays:')
        # One badge for all the titles: same group as the default `ratings`,
        # higher weight, so Kometa shows this one and not its Top badge. The
        # style values are the ones of the default (ratings.yml, v2.5.4).
        [void]$sb.AppendLine('  imdb_rank_badge:')
        [void]$sb.AppendLine('    ignore_blank_results: true')
        [void]$sb.AppendLine('    overlay:')
        [void]$sb.AppendLine('      name: text(<<imdb_rating>>)')
        [void]$sb.AppendLine('      default: rating/IMDbTop')
        [void]$sb.AppendLine('      group: rating1_group')
        [void]$sb.AppendLine('      weight: 200')
        [void]$sb.AppendLine('      horizontal_align: left')
        [void]$sb.AppendLine("      horizontal_offset: $BadgeX")
        [void]$sb.AppendLine('      vertical_align: top')
        [void]$sb.AppendLine("      vertical_offset: $BadgeY")
        [void]$sb.AppendLine('      font: fonts/Inter-Bold.ttf')
        [void]$sb.AppendLine('      font_size: 63')
        [void]$sb.AppendLine('      font_color: "#FFFFFF"')
        [void]$sb.AppendLine('      back_color: "#00000099"')
        [void]$sb.AppendLine('      back_width: 160')
        [void]$sb.AppendLine("      back_height: $BadgeHeight")
        [void]$sb.AppendLine('      back_padding: 15')
        [void]$sb.AppendLine('      back_radius: 30')
        [void]$sb.AppendLine("      addon_offset: $AddonOffset")
        [void]$sb.AppendLine('      addon_position: top')
        foreach ($b in ($items | Group-Object { ($_.Builder -split ':')[0] })) {
            [void]$sb.AppendLine("    $($b.Name): $(($b.Group | ForEach-Object { ($_.Builder -split ':\s*')[1] }) -join ', ')")
        }
        # One position text for each title. Transparent box with the width of
        # the badge content: the text is in the center of the badge.
        foreach ($i in ($items | Sort-Object Rank)) {
            [void]$sb.AppendLine("  imdb_rank_$($i.Rank):")
            [void]$sb.AppendLine("    # $($i.Title) ($($i.Imdb))")
            [void]$sb.AppendLine('    ignore_blank_results: true')
            [void]$sb.AppendLine('    overlay:')
            [void]$sb.AppendLine("      name: 'text(#$($i.Rank))'")
            [void]$sb.AppendLine('      horizontal_align: left')
            [void]$sb.AppendLine("      horizontal_offset: $BadgeX")
            [void]$sb.AppendLine('      vertical_align: top')
            [void]$sb.AppendLine("      vertical_offset: $RankY")
            [void]$sb.AppendLine('      font: fonts/Inter-Bold.ttf')
            [void]$sb.AppendLine("      font_size: $RankFontSize")
            [void]$sb.AppendLine('      font_color: "#FFFFFF"')
            [void]$sb.AppendLine('      back_color: "#00000000"')
            [void]$sb.AppendLine('      back_width: 160')
            [void]$sb.AppendLine("      back_height: $RankBoxHeight")
            [void]$sb.AppendLine('      back_padding: 0')
            [void]$sb.AppendLine("    $($i.Builder)")
        }
    }
    $files.Add([pscustomobject]@{ Name = "imdb-rank-$slug.yml"; Text = $sb.ToString() })
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
foreach ($f in $files) {
    $final = Join-Path $OutDir $f.Name
    $tmp = "$final.tmp"
    Set-Content -LiteralPath $tmp -Value $f.Text -NoNewline -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $final -Force
}

$found | Sort-Object Library, Rank
