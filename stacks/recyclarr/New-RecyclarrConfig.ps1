<#
  New-RecyclarrConfig.ps1  -  v1.1  (2026-11-21).
  Writes configs/radarr.yml and configs/sonarr.yml for Recyclarr from the CF
  mapping (PLAN-RECYCLARR.md, step R4) and the score matrix of the baseline
  (step R2). Step R5 of the plan.
  v1.1: no assign_scores_to by default (O16 option b, decision of Faginux on
  2026-11-21). -WithScores writes the items of v1.0 (O16 option a).

  For each app:
    - One custom_formats entry for each CF with the decision adopt, C1 or C3.
      The entry has one trash ID, with the CF name in a comment.
    - Default: no assign_scores_to. Recyclarr then updates only the CF
      definitions. It changes no score ("No quality profiles are changed").
      The scores stay in the UI of the app, as Faginux sets them.
    - With -WithScores: one assign_scores_to item for each profile where the
      baseline score is not 0, with the profile name and the score (D3, O5).
      Then each sync sets these scores again, also after a change in the UI.
    - No quality_profiles block (D2). delete_old_custom_formats is false (D5).
  The script joins the mapping and the score matrix on the CF ID, not on the
  name: Faginux renamed two Sonarr CFs after the baseline (C1).

  The script writes the full file each time. It sorts the entries with an
  ordinal compare, thus PowerShell 5.1 and 7 write the same bytes.
  It reads no secret: the URL and the API key stay as !secret in the file.

  Runs on Windows PowerShell 5.1 and PowerShell 7.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    # The final CF mapping of step R4.
    [string]$MappingPath = 'S:\docker-appdata\recyclarr\baseline\mapping_2026-11-21\cf-mapping.csv',

    # The baseline export of step R2 (score matrix and quality profiles).
    [string]$BaselineDir = 'S:\docker-appdata\recyclarr\baseline\2026-11-21_033933',

    # The folder of the instance files (in git). Default: configs next to this script.
    [string]$ConfigDir = '',

    [ValidateSet('radarr', 'sonarr')]
    [string[]]$App = @('radarr', 'sonarr'),

    # Write the assign_scores_to items (O16 option a). Default: no items (option b).
    [switch]$WithScores
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ManagedDecisions = @('adopt', 'C1', 'C3')
$SchemaLine = '# yaml-language-server: $schema=https://schemas.recyclarr.dev/latest/config-schema.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
# Windows PowerShell 5.1 gives an empty $PSScriptRoot in the param block. Set the default here.
if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot 'configs' }

function Get-JsonArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)
    # Windows PowerShell 5.1 gives a JSON array as one object, PowerShell 7 gives its items.
    $text = [IO.File]::ReadAllText($Path, $Utf8NoBom)
    return @($text | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
}

function Get-SortedByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][string]$Property
    )
    # Ordinal compare: Sort-Object uses the culture, and the culture rules of
    # .NET Framework (5.1) and .NET (7) can give a different order.
    $keys = [string[]]@($Item | ForEach-Object { [string]$_.$Property })
    $copy = [object[]]@($Item)
    [Array]::Sort($keys, $copy, [StringComparer]::OrdinalIgnoreCase)
    return $copy
}

if (-not (Test-Path -LiteralPath $MappingPath -PathType Leaf)) { throw "The mapping $MappingPath does not exist." }
$mapping = @(Import-Csv -LiteralPath $MappingPath -Encoding UTF8)
$mappingHash = (Get-FileHash -LiteralPath $MappingPath -Algorithm SHA256).Hash.ToLowerInvariant()
$baselineName = Split-Path -Leaf $BaselineDir

foreach ($appName in $App) {
    $title = (Get-Culture).TextInfo.ToTitleCase($appName)

    # 1. Read the sources.
    $managed = @($mapping | Where-Object { $_.app -eq $appName -and $ManagedDecisions -contains $_.decision })
    $scoreRows = @(Import-Csv -LiteralPath (Join-Path $BaselineDir "$appName-scores.csv") -Encoding UTF8)
    $profiles = @(Get-JsonArray -Path (Join-Path $BaselineDir "$appName-qualityprofile.json") | Sort-Object -Property { [int]$_.id })

    # 2. Check the sources before the script writes a line.
    $seen = @{}
    foreach ($row in $managed) {
        if ($row.trash_id -notmatch '^[0-9a-f]{32}$') { throw "${appName}: no valid trash ID for the CF '$($row.cf_name)' (ID $($row.cf_id))." }
        if ($seen.ContainsKey($row.trash_id)) { throw "${appName}: the trash ID $($row.trash_id) is in the mapping two times." }
        $seen[$row.trash_id] = $true
    }
    foreach ($qualityProfile in $profiles) {
        if ([string]$qualityProfile.name -match '["\\]') { throw "${appName}: the profile name '$($qualityProfile.name)' has a character that the script does not quote." }
    }
    $profileOrder = @{}
    for ($i = 0; $i -lt $profiles.Count; $i++) { $profileOrder[[string]$profiles[$i].name] = $i }

    $scoresByCfId = @{}
    foreach ($scoreRow in $scoreRows) {
        $id = [int]$scoreRow.cf_id
        if (-not $scoresByCfId.ContainsKey($id)) { $scoresByCfId[$id] = New-Object System.Collections.Generic.List[object] }
        $scoresByCfId[$id].Add($scoreRow)
    }

    # 3. Make the lines.
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($SchemaLine)
    $lines.Add("# Recyclarr instance file for $title (PLAN-RECYCLARR.md, D7).")
    $lines.Add('# New-RecyclarrConfig.ps1 v1.1 wrote the custom_formats block from these sources:')
    $lines.Add("#   mapping  cf-mapping.csv, SHA-256 $($mappingHash.Substring(0, 16))")
    $lines.Add("#   scores   the score matrix of the baseline $baselineName")
    $lines.Add('# The URL and the API key come from secrets.yml (D6, D12). This file has no secret.')
    if ($WithScores) {
        $lines.Add('# Each score comes from the baseline (D3). A profile with score 0 has no item: Recyclarr')
        $lines.Add('# does not change that score. Each sync sets the scores of this file again.')
    } else {
        $lines.Add('# No assign_scores_to (O16 option b): Recyclarr updates only the CF definitions. It')
        $lines.Add('# changes no score. Faginux sets the scores in the UI of the app.')
    }
    $lines.Add('# No quality_profiles block (D2): Recyclarr does not change the profiles.')
    $lines.Add("${appName}:")
    $lines.Add("  ${appName}:")
    $lines.Add("    base_url: !secret ${appName}_url")
    $lines.Add("    api_key: !secret ${appName}_api_key")
    $lines.Add('    # D5: Recyclarr never deletes a CF')
    $lines.Add('    delete_old_custom_formats: false')
    $lines.Add('    custom_formats:')

    $assignCount = 0
    $noScoreCount = 0
    foreach ($row in (Get-SortedByName -Item $managed -Property 'cf_name')) {
        $id = [int]$row.cf_id
        if (-not $scoresByCfId.ContainsKey($id)) { throw "${appName}: the score matrix has no row for the CF '$($row.cf_name)' (ID $id)." }
        $cfName = [string]$row.cf_name -replace '[\r\n]', ' '
        $lines.Add('      - trash_ids:')
        $lines.Add("          - $($row.trash_id) # $cfName")

        $items = @($scoresByCfId[$id] | Where-Object { [int]$_.score -ne 0 } |
            Sort-Object -Property { $profileOrder[[string]$_.profile] })
        if (-not $WithScores -or $items.Count -eq 0) { $noScoreCount++; continue }
        $lines.Add('        assign_scores_to:')
        foreach ($item in $items) {
            if (-not $profileOrder.ContainsKey([string]$item.profile)) { throw "${appName}: the profile '$($item.profile)' is not in the baseline profiles." }
            $lines.Add(('          - name: "{0}"' -f $item.profile))
            $lines.Add(('            score: {0}' -f [int]$item.score))
            $assignCount++
        }
    }

    # 4. Write the file (UTF-8 with no BOM, LF line ends).
    $path = Join-Path $ConfigDir "$appName.yml"
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $Utf8NoBom)

    [pscustomobject]@{
        App              = $appName
        Entries          = $managed.Count
        AssignItems      = $assignCount
        EntriesWithScore = $managed.Count - $noScoreCount
        EntriesNoScore   = $noScoreCount
        File             = $path
    }
}
