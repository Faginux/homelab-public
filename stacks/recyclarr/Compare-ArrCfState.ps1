<#
  Compare-ArrCfState.ps1  -  v1.1  (2026-11-21).
  v1.1: mode Config expects no assign_scores_to by default (O16 option b).
  -WithScores checks the score items of option a, as v1.0.
  Two compares for PLAN-RECYCLARR.md:

  -Mode Config (step R5): compares configs/<app>.yml with the CF mapping and the
    score matrix of the baseline. Expect 0 differences. It finds:
      - a managed CF of the mapping that is not in the file, or a trash ID in
        the file that is not a managed CF of the mapping,
      - a trash ID that is in the file two times,
      - default: each assign_scores_to item (option b has none),
      - with -WithScores: a profile name that is not in the baseline, a score
        in the file that is not the baseline score, and a baseline score that
        is not 0 with no item in the file.
    The file reader knows only the format of New-RecyclarrConfig.ps1. It stops
    on each line in the custom_formats block that it does not know.

  -Mode State (steps R7 and R9): compares a new export of Export-ArrCfState.ps1
    with the baseline. It gives the CFs that are new, gone or renamed, the CFs
    with new specifications, and each score that changed. After a sync, expect
    0 score changes. New specifications are the definition updates of R6.

  The script reads files only. It reads no secret.
  Runs on Windows PowerShell 5.1 and PowerShell 7.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Config', 'State')]
    [string]$Mode,

    [string]$BaselineDir = 'S:\docker-appdata\recyclarr\baseline\2026-11-21_033933',

    # Mode Config: the CF mapping of step R4 and the folder of the instance files
    # (default: configs next to this script).
    [string]$MappingPath = 'S:\docker-appdata\recyclarr\baseline\mapping_2026-11-21\cf-mapping.csv',
    [string]$ConfigDir = '',

    # Mode State: the folder of the new export.
    [string]$NewDir,

    [ValidateSet('radarr', 'sonarr')]
    [string[]]$App = @('radarr', 'sonarr'),

    # Mode Config: check the score items of O16 option a. Default: expect no items (option b).
    [switch]$WithScores
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ManagedDecisions = @('adopt', 'C1', 'C3')
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

function Read-RecyclarrScore {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    # Returns a table: trash ID -> (profile name -> score). Stops on an unknown line.
    $result = @{}
    $inBlock = $false
    $trashId = $null
    $profileName = $null
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($Path, $Utf8NoBom)) {
        $lineNumber++
        if (-not $inBlock) {
            if ($line -eq '    custom_formats:') { $inBlock = $true }
            continue
        }
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -eq '      - trash_ids:') { $trashId = $null; $profileName = $null; continue }
        if ($line -match '^          - ([0-9a-f]{32})( #.*)?$') {
            if ($null -ne $trashId) { throw "${Path}:${lineNumber}: an entry with more than one trash ID." }
            $trashId = $Matches[1]
            if ($result.ContainsKey($trashId)) { throw "${Path}:${lineNumber}: the trash ID $trashId is in the file two times." }
            $result[$trashId] = @{}
            continue
        }
        if ($line -eq '        assign_scores_to:') {
            if ($null -eq $trashId) { throw "${Path}:${lineNumber}: assign_scores_to with no trash ID." }
            continue
        }
        if ($line -match '^          - name: "([^"]+)"$') {
            if ($null -eq $trashId) { throw "${Path}:${lineNumber}: a profile item with no trash ID." }
            $profileName = $Matches[1]
            if ($result[$trashId].ContainsKey($profileName)) { throw "${Path}:${lineNumber}: the profile '$profileName' is in the entry two times." }
            $result[$trashId][$profileName] = $null
            continue
        }
        if ($line -match '^            score: (-?\d+)$') {
            if ($null -eq $profileName) { throw "${Path}:${lineNumber}: a score with no profile name." }
            $result[$trashId][$profileName] = [int]$Matches[1]
            $profileName = $null
            continue
        }
        throw "${Path}:${lineNumber}: a line that the script does not know."
    }
    if (-not $inBlock) { throw "${Path}: no custom_formats block." }
    foreach ($id in $result.Keys) {
        foreach ($name in $result[$id].Keys) {
            if ($null -eq $result[$id][$name]) { throw "${Path}: the trash ID $id has the profile '$name' with no score." }
        }
    }
    return $result
}

function Add-Difference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Detail
    )
    $script:differences.Add([pscustomobject]@{ App = $AppName; Kind = $Kind; Detail = $Detail })
}

$differences = New-Object System.Collections.Generic.List[object]
$summary = New-Object System.Collections.Generic.List[object]

if ($Mode -eq 'Config') {
    $mapping = @(Import-Csv -LiteralPath $MappingPath -Encoding UTF8)
    foreach ($appName in $App) {
        $config = Read-RecyclarrScore -Path (Join-Path $ConfigDir "$appName.yml")
        $managed = @($mapping | Where-Object { $_.app -eq $appName -and $ManagedDecisions -contains $_.decision })
        $profileNames = @(Get-JsonArray -Path (Join-Path $BaselineDir "$appName-qualityprofile.json") | ForEach-Object { [string]$_.name })
        $scoresByCfId = @{}
        foreach ($row in (Import-Csv -LiteralPath (Join-Path $BaselineDir "$appName-scores.csv") -Encoding UTF8)) {
            $id = [int]$row.cf_id
            if (-not $scoresByCfId.ContainsKey($id)) { $scoresByCfId[$id] = @{} }
            $scoresByCfId[$id][[string]$row.profile] = [int]$row.score
        }

        $managedIds = @{}
        $checked = 0
        foreach ($row in $managed) {
            $managedIds[$row.trash_id] = $true
            if (-not $config.ContainsKey($row.trash_id)) {
                Add-Difference -AppName $appName -Kind 'missing CF' -Detail "$($row.cf_name) ($($row.trash_id))"; continue
            }
            $baseline = $scoresByCfId[[int]$row.cf_id]
            if ($null -eq $baseline) { Add-Difference -AppName $appName -Kind 'no baseline' -Detail "$($row.cf_name) (ID $($row.cf_id))"; continue }
            $items = $config[$row.trash_id]
            if (-not $WithScores) {
                foreach ($name in $items.Keys) {
                    Add-Difference -AppName $appName -Kind 'score item' -Detail "$($row.cf_name) / ${name}: option b has no assign_scores_to"
                }
                continue
            }
            foreach ($name in $items.Keys) {
                if ($profileNames -notcontains $name) { Add-Difference -AppName $appName -Kind 'unknown profile' -Detail "$($row.cf_name): '$name'" }
            }
            foreach ($name in $baseline.Keys) {
                $expected = $baseline[$name]
                $checked++
                if ($items.ContainsKey($name)) {
                    if ($items[$name] -ne $expected) { Add-Difference -AppName $appName -Kind 'score' -Detail "$($row.cf_name) / ${name}: file $($items[$name]), baseline $expected" }
                } elseif ($expected -ne 0) {
                    Add-Difference -AppName $appName -Kind 'no item' -Detail "$($row.cf_name) / ${name}: baseline $expected"
                }
            }
        }
        foreach ($id in $config.Keys) {
            if (-not $managedIds.ContainsKey($id)) { Add-Difference -AppName $appName -Kind 'extra CF' -Detail "trash ID $id is not a managed CF of the mapping" }
        }
        $summary.Add([pscustomobject]@{ App = $appName; ManagedCfs = $managed.Count; FileEntries = $config.Count; ScorePairsChecked = $checked })
    }
} else {
    if (-not $NewDir) { throw 'Mode State needs -NewDir (the folder of the new export).' }
    foreach ($appName in $App) {
        $oldCfs = @(Get-JsonArray -Path (Join-Path $BaselineDir "$appName-customformat.json"))
        $newCfs = @(Get-JsonArray -Path (Join-Path $NewDir "$appName-customformat.json"))
        $oldById = @{}; foreach ($cf in $oldCfs) { $oldById[[int]$cf.id] = $cf }
        $newById = @{}; foreach ($cf in $newCfs) { $newById[[int]$cf.id] = $cf }
        $specChanges = 0
        foreach ($cf in $newCfs) {
            $old = $oldById[[int]$cf.id]
            if ($null -eq $old) { Add-Difference -AppName $appName -Kind 'new CF' -Detail "$($cf.name) (ID $($cf.id))"; continue }
            if ([string]$old.name -cne [string]$cf.name) { Add-Difference -AppName $appName -Kind 'renamed' -Detail "ID $($cf.id): '$($old.name)' -> '$($cf.name)'" }
            $oldSpec = $old.specifications | ConvertTo-Json -Depth 8 -Compress
            $newSpec = $cf.specifications | ConvertTo-Json -Depth 8 -Compress
            if ($oldSpec -ne $newSpec) { $specChanges++; Add-Difference -AppName $appName -Kind 'new specs' -Detail "$($cf.name) (ID $($cf.id))" }
        }
        foreach ($cf in $oldCfs) {
            if (-not $newById.ContainsKey([int]$cf.id)) { Add-Difference -AppName $appName -Kind 'gone CF' -Detail "$($cf.name) (ID $($cf.id))" }
        }

        $oldScores = @{}
        foreach ($row in (Import-Csv -LiteralPath (Join-Path $BaselineDir "$appName-scores.csv") -Encoding UTF8)) { $oldScores["$($row.profile)|$($row.cf_id)"] = [int]$row.score }
        $scoreChanges = 0
        foreach ($row in (Import-Csv -LiteralPath (Join-Path $NewDir "$appName-scores.csv") -Encoding UTF8)) {
            $key = "$($row.profile)|$($row.cf_id)"
            $old = if ($oldScores.ContainsKey($key)) { $oldScores[$key] } else { 0 }
            if ([int]$row.score -ne $old) { $scoreChanges++; Add-Difference -AppName $appName -Kind 'score' -Detail "$($row.cf_name) / $($row.profile): baseline $old, now $($row.score)" }
        }
        $summary.Add([pscustomobject]@{ App = $appName; BaselineCfs = $oldCfs.Count; NewCfs = $newCfs.Count; SpecChanges = $specChanges; ScoreChanges = $scoreChanges })
    }
}

$summary | Format-Table -AutoSize | Out-String -Stream | Write-Output
if ($differences.Count -gt 0) {
    $differences | Format-Table -AutoSize -Wrap | Out-String -Stream | Write-Output
}
"Differences: $($differences.Count)"
