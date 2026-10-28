#Requires -Version 7.0
<#
  New-ItaOverlay.ps1  -  v1.0  (2026-09-28).
  "Cascading" Italian flag for TV series and Anime. It is a request of the operator:
    - SERIES poster:    "IT A"      all the episodes of all the seasons
                                     have Italian audio.
                        "IT S1-3,8" only some seasons are complete
                                     in Italian (list if it fits in the
                                     pill, if not only "IT S").
                        nothing     no complete season.
    - SEASON poster:    "IT"        all the episodes of the season.
  The specials (season 0) do not count for the series poster.

  Why a script: the Kometa default `languages` uses
  `plex_search: any: audio_language`. So ONE Italian episode is sufficient for
  the flag on the series (checked on 2026-09-28: Reacher 7/32). Kometa can do
  "all the episodes" (filter `episodes` with `percentage: 100`). But it cannot
  write WHICH seasons in the text. This script calculates that from Plex and
  writes it into an overlay file, as TSSK does. The season poster uses
  the native Kometa filter (a static file, that this script also writes).

  Data: 3 requests for each library to the Plex API (all the episodes +
  episodes filtered by audio language "Italiano"), a few seconds. Plex read only.
  Output (Kometa reads them as config/overlays-custom/*.yml):
    ita-show.yml    made again at each run.
    ita-season.yml  static, written again at each run from the base.
  Style and position are identical to the Kometa flag. The base is in
  overlays/ita-base.yml (= languages.yml of Kometa v2.5.1, refer to its header).

  Invoke-KometaRun.ps1 starts it before Kometa (Full, and Quick if it touches
  TV series or Anime). Exit 0 = files written, 1 = error (old files not changed).

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [string[]]$Libraries = @('Serie TV', 'Anime'),
    [string]$PlexConfig  = 'S:\Scripts\Tmm\plex.config.psd1',
    [string]$OutDir      = 'S:\docker-appdata\kometa\config\overlays-custom',
    [string]$BaseFile    = (Join-Path $PSScriptRoot 'overlays\ita-base.yml'),
    [string]$LanguageKey = 'it',          # Plex key (ISO 639-1): it takes it and it-IT
    # regex for the season filter: name in validation, languageCode on the tracks
    [string]$LanguageRegex = '(?i)^(ita|italian|italiano)$',
    [int]$MaxSeasonText  = 7              # above this, the pill shows only "IT S"
)
$ErrorActionPreference = 'Stop'

function Get-PlexJson([string]$Path) {
    Invoke-RestMethod "$($script:plex.BaseUrl)$Path" -Headers @{ 'X-Plex-Token' = $script:plex.Token; Accept = 'application/json' }
}
function Get-PlexXml([string]$Path) {
    # with JSON + includeGuids Plex returns "Guid" and "guid": ConvertFrom-Json
    # (case-insensitive) loses them. XML does not.
    [xml](Invoke-WebRequest "$($script:plex.BaseUrl)$Path" -Headers @{ 'X-Plex-Token' = $script:plex.Token }).Content
}

function Format-SeasonRange([int[]]$Seasons) {
    # 1,2,3,5,7,8 -> "1-3,5,7-8"
    $parts = @(); $i = 0; $s = @($Seasons | Sort-Object)
    while ($i -lt $s.Count) {
        $j = $i
        while ($j + 1 -lt $s.Count -and $s[$j + 1] -eq $s[$j] + 1) { $j++ }
        $parts += $(if ($j -gt $i) { "$($s[$i])-$($s[$j])" } else { "$($s[$i])" })
        $i = $j + 1
    }
    $parts -join ','
}

function Get-LabelWidth([string]$Text) {
    # 190 = Kometa default for "IT". ~27 px for each more character (Inter-Bold
    # 50), measured on the B99 poster on 2026-09-28 (40 px left the pill too wide)
    190 + 27 * [math]::Max(0, $Text.Length - 2)
}

$script:plex = Import-PowerShellDataFile -Path $PlexConfig
$base = Get-Content -LiteralPath $BaseFile -Raw
$sections = (Get-PlexJson '/library/sections').MediaContainer.Directory

$shows = [System.Collections.Generic.List[object]]::new()
foreach ($libName in $Libraries) {
    $sec = $sections | Where-Object { $_.title -eq $libName -and $_.type -eq 'show' }
    if (-not $sec) { throw "library '$libName' non trovata in Plex" }

    # keys of the language (TV series has two: it and it-IT). By key, not by
    # name: Plex localizes the name ("Italiano"/"Italian") on the client.
    $langKeys = @((Get-PlexJson "/library/sections/$($sec.key)/audioLanguage?type=4").MediaContainer.Directory |
        Where-Object { $_.key -eq $LanguageKey -or $_.key -like "$LanguageKey-*" } | ForEach-Object key)

    $episodes = @((Get-PlexJson "/library/sections/$($sec.key)/all?type=4").MediaContainer.Metadata)
    $itaKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($k in $langKeys) {
        foreach ($e in @((Get-PlexJson "/library/sections/$($sec.key)/all?type=4&audioLanguage=$([uri]::EscapeDataString($k))").MediaContainer.Metadata)) {
            if ($e) { [void]$itaKeys.Add([string]$e.ratingKey) }
        }
    }

    $guidMap = @{}
    foreach ($d in @((Get-PlexXml "/library/sections/$($sec.key)/all?type=2&includeGuids=1").MediaContainer.Directory)) {
        $ids = @($d.Guid | ForEach-Object { $_.id })
        $guidMap[[string]$d.ratingKey] = [pscustomobject]@{
            Title = $d.title
            Tvdb  = ($ids | Where-Object { $_ -like 'tvdb://*' } | Select-Object -First 1) -replace '^tvdb://'
            Tmdb  = ($ids | Where-Object { $_ -like 'tmdb://*' } | Select-Object -First 1) -replace '^tmdb://'
        }
    }

    foreach ($g in ($episodes | Where-Object { [int]$_.parentIndex -gt 0 } | Group-Object grandparentRatingKey)) {
        $full = @()
        $seasonCount = 0
        foreach ($sg in ($g.Group | Group-Object parentIndex)) {
            $seasonCount++
            $ita = @($sg.Group | Where-Object { $itaKeys.Contains([string]$_.ratingKey) }).Count
            if ($ita -eq $sg.Count) { $full += [int]$sg.Name }
        }
        if ($full.Count -eq 0) { continue }
        $info = $guidMap[[string]$g.Name]
        if (-not $info -or (-not $info.Tvdb -and -not $info.Tmdb)) { continue }
        $label = if ($full.Count -eq $seasonCount) { 'IT A' } else {
            $r = Format-SeasonRange $full
            if ($r.Length -le $MaxSeasonText) { "IT S$r" } else { 'IT S' }
        }
        $shows.Add([pscustomobject]@{ Library = $libName; Title = $info.Title; Label = $label; Tvdb = $info.Tvdb; Tmdb = $info.Tmdb; FullSeasons = ($full | Sort-Object) -join ',' })
    }
}

# --- ita-show.yml: one overlay for each different label ---------------------
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# GENERATED by stacks/kometa/New-ItaOverlay.ps1 on $(Get-Date -Format 'dd/MM/yyyy HH:mm') - do not edit by hand.")
[void]$sb.Append($base)
[void]$sb.AppendLine('overlays:')
$n = 0
foreach ($grp in ($shows | Group-Object Label | Sort-Object Name)) {
    $n++
    $key = 'ita_' + (($grp.Name.ToLower() -replace '[^a-z0-9]+', '_').Trim('_'))
    $tvdb = @($grp.Group | Where-Object Tvdb | ForEach-Object Tvdb | Sort-Object -Unique)
    $tmdb = @($grp.Group | Where-Object { -not $_.Tvdb -and $_.Tmdb } | ForEach-Object Tmdb | Sort-Object -Unique)
    [void]$sb.AppendLine("  ${key}:")
    [void]$sb.AppendLine("    # $(($grp.Group.Title | Sort-Object) -join ' | ')")
    [void]$sb.AppendLine("    variables: {key: $key, country: it, text: `"$($grp.Name)`", weight: 510, label_width: $(Get-LabelWidth $grp.Name)}")
    [void]$sb.AppendLine('    template: [name: standard]')
    [void]$sb.AppendLine('    ignore_blank_results: true')
    if ($tvdb) { [void]$sb.AppendLine("    tvdb_show: $($tvdb -join ', ')") }
    if ($tmdb) { [void]$sb.AppendLine("    tmdb_show: $($tmdb -join ', ')") }
}

# --- ita-season.yml: native Kometa filter, all the episodes of the season ---
# Use .regex on the 3-letter code, NOT "audio_language: Italiano". In Kometa
# v2.5.1 the simple filter checks the value in the Plex key ("it"). Then it
# compares the value with [language, languageCode] of the track ("Italian", "ita").
# They are never equal (and the name is also localized). Seen on 2026-09-28: "Plex
# Error: audio_language: Italiano not found". The .regex compares the tracks.
# BUT in its check it must find minimum one name of the Plex language list
# ("Italian"/"Italiano", not "ita"). If not, Kometa shows "No matches found with
# regex pattern ^ita$" and skips the overlay. For this reason the regex accepts
# all three.
$season = @"
# GENERATED by stacks/kometa/New-ItaOverlay.ps1 - do not edit by hand.
# Use with template_variables: {builder_level: season}.
$base
templates:
  ita_full_episodes:
    ignore_blank_results: true
    plex_all: true
    filters:
      episodes:
        audio_language.regex: '$LanguageRegex'
        percentage: 100

overlays:
  italian:
    variables: {key: it, text: IT, weight: 510}
    template: [name: ita_full_episodes, name: standard]
"@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
foreach ($f in @(@{ Name = 'ita-show.yml'; Text = $(if ($n -gt 0) { $sb.ToString() } else { "# No series with complete seasons in Italian.`n" }) },
                 @{ Name = 'ita-season.yml'; Text = $season })) {
    $final = Join-Path $OutDir $f.Name
    $tmp = "$final.tmp"
    Set-Content -LiteralPath $tmp -Value $f.Text -NoNewline -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $final -Force
}

$shows | Sort-Object Library, Label, Title
