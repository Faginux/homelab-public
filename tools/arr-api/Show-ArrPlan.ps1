<#
  Show-ArrPlan.ps1  -  v0.1  (2026-11-27).
  Checks a plan against its snapshot. It prints the table that a person approves,
  the warnings, the SHA-256 of the plan and the apply command.

  The script is offline. It sends no request and reads no config.xml.
  A plan with an error gives no table and no command. Exit code 1.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [string]$RecyclarrDir = (Join-Path $PSScriptRoot '..' '..' 'stacks' 'recyclarr' 'configs')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ArrApi gives only the verified versions here. No call of this script reads a key.
Import-Module (Join-Path $PSScriptRoot 'ArrApi.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArrPlan.psm1') -Force

$planFile = Read-ArrPlanFile -Path $PlanPath
$problems = @(Get-ArrPlanShapeError -Plan $planFile.Plan)
if ($problems.Count -eq 0) {
    $state = Read-ArrBaseline -Plan $planFile.Plan
    $verified = @{ sonarr = Get-ArrVerifiedVersion -App sonarr; radarr = Get-ArrVerifiedVersion -App radarr }
    $check = Test-ArrPlan -Plan $planFile.Plan -State $state -VerifiedVersion $verified
    $problems = @($check.Errors)
}
if ($problems.Count) {
    'The plan has errors. Do not apply it.'
    $problems | ForEach-Object { "- $_" }
    exit 1
}

Format-ArrPlanReport -Plan $planFile.Plan -State $state -Warning $check.Warnings -RecyclarrDir $RecyclarrDir
$fullPath = (Resolve-Path -LiteralPath $PlanPath).ProviderPath.Replace('\', '/')
$applyScript = (Join-Path $PSScriptRoot 'Invoke-ArrPlan.ps1').Replace('\', '/')
''
"Snapshot: $($planFile.Plan.snapshot)"
"Plan SHA-256: $($planFile.Sha256)"
'Apply command (only after the OK in chat):'
"pwsh -NoProfile -File `"$applyScript`" -PlanPath `"$fullPath`" -PlanSha256 $($planFile.Sha256)"
