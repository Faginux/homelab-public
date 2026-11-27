<#
  New-ArrPlan.ps1  -  v0.1  (2026-11-27).
  Makes a plan file from a change file and a snapshot folder. It adds the SHA-256
  of each snapshot file that the plan needs. Thus a person writes no hash by hand.

  The change file is JSON: { "operations": [ ... ], "parseTests": [ ... ] }.
  The README gives the form of each operation.

  The script is offline. It sends no request. It does not overwrite a file.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ChangePath,
    [Parameter(Mandatory)][string]$SnapshotPath,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ArrPlan.psm1') -Force

if (Test-Path -LiteralPath $OutputPath) { throw "The file $OutputPath exists. The script does not overwrite it." }
$snapshot = (Resolve-Path -LiteralPath $SnapshotPath).ProviderPath
$change = ConvertFrom-ArrJson -Text (Get-Content -LiteralPath $ChangePath -Raw)

$names = [string[]]@($change.PSObject.Properties.Name)
if ($names -cnotcontains 'operations' -or @($names | Where-Object { $_ -cnotin 'operations', 'parseTests' }).Count) {
    throw 'The change file must have "operations" and can have "parseTests".'
}
$parseTests = if ($names -ccontains 'parseTests') { $change.parseTests } else { @() }

$plan = [pscustomobject][ordered]@{
    planVersion   = 1
    snapshot      = $snapshot
    snapshotFiles = [pscustomobject]@{}
    operations    = $change.operations
    parseTests    = @($parseTests)
}
$shapeErrors = @(Get-ArrPlanShapeError -Plan $plan)
if ($shapeErrors.Count) { throw "The change file has errors:`n- $($shapeErrors -join "`n- ")" }

$hashes = [ordered]@{}
foreach ($resource in Get-ArrRequiredResource -Scope (Get-ArrPlanScope -Plan $plan)) {
    $path = Join-Path $snapshot $resource.File
    if (-not (Test-Path -LiteralPath $path)) {
        $hint = if ($resource.Name -eq 'episode') { " Make a snapshot with -SeriesId $($resource.QueryValue)." } else { '' }
        throw "The snapshot has no file $($resource.File).$hint"
    }
    $hashes[$resource.File] = Get-ArrFileSha256 -Byte ([System.IO.File]::ReadAllBytes($path))
}
$plan.snapshotFiles = [pscustomobject]$hashes

$json = ConvertTo-Json -InputObject $plan -Depth 40
[System.IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath), $json, [System.Text.UTF8Encoding]::new($false))
"Plan file: $OutputPath"
'Next step: Show-ArrPlan.ps1 -PlanPath <plan file>'
