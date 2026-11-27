<#
  Invoke-ArrPlan.ps1  -  v0.1  (2026-11-27).
  Applies one approved plan. It is the only command of the tool that changes data.

  Sequence: checks of the plan, live drift check, backup, parse tests, writes with
  a read after each write, full comparison, parse tests, final snapshot.
  At the first error after the first write, the script restores the batch.
  The restore deletes nothing: a new custom format stays with the score 0.

  Exit codes:
    0  The batch is applied and all checks passed.
    1  The batch failed. The restore is complete.
    2  The batch failed and the restore is NOT complete. Read the output.
    3  The script stopped before the first write. The apps did not change.

  A killed process does not restore. The run folder then has the backup and the journal.
  Give the command a time limit of 10 minutes.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    # The SHA-256 that Show-ArrPlan.ps1 printed for the approved plan.
    [Parameter(Mandatory)][string]$PlanSha256,
    [string]$RunRoot = 'S:\docker-appdata\arr-api\runs',
    [string]$SnapshotRoot = 'S:\docker-appdata\arr-api\snapshots'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ArrApi.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ArrPlan.psm1') -Force

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$runDir = $null

function Read-LiveText {
    # File name to safe JSON text, for a list of resources.
    param([object[]]$Resource)
    $texts = [ordered]@{}
    foreach ($item in $Resource) {
        $query = @{}
        if ($item.QueryValue) { $query.QueryValue = $item.QueryValue }
        $texts[$item.File] = (Get-ArrResourceJson -App $item.App -Name $item.Name @query).Json
    }
    $texts
}

function Read-LiveState {
    param([object[]]$Resource)
    ConvertTo-ArrState -Resource $Resource -TextByFile (Read-LiveText -Resource $Resource)
}

function Update-LiveApp {
    # Reads all resources of one app again.
    param([hashtable]$Live, [object[]]$Resource, [string]$App)
    $Live[$App] = (Read-LiveState -Resource @($Resource | Where-Object App -EQ $App))[$App]
}

function Read-ParseResult {
    param($Test)
    ConvertFrom-ArrJson -Text (Get-ArrResourceJson -App $Test.app -Name parse -QueryValue $Test.title).Json
}

function Add-Journal {
    # A journal error must not stop a restore.
    param([System.Collections.IDictionary]$Entry)
    try {
        $record = [ordered]@{ time = (Get-Date).ToString('o') }
        foreach ($key in $Entry.Keys) { $record[$key] = $Entry[$key] }
        [System.IO.File]::AppendAllText((Join-Path $runDir 'journal.jsonl'), (ConvertTo-Json -InputObject $record -Depth 5 -Compress) + "`n", $utf8NoBom)
    } catch {
        Write-Warning "Cannot write the journal: $($_.Exception.Message)"
    }
}

function Send-PlanWrite {
    param($Write, [string]$Phase, [int]$Step)
    $entry = [ordered]@{ phase = $Phase; step = $Step; app = $Write.App; operation = $Write.Operation; id = $Write.Id }
    Add-Journal -Entry ($entry + [ordered]@{ event = 'send'; body = $Write.BodyJson })
    $parameters = @{ App = $Write.App; Operation = $Write.Operation; BodyJson = $Write.BodyJson }
    if ($null -ne $Write.Id) { $parameters.Id = $Write.Id }
    try {
        [void](Invoke-ArrWrite @parameters)
    } catch {
        Add-Journal -Entry ($entry + [ordered]@{ event = 'error'; message = $_.Exception.Message })
        throw
    }
    Add-Journal -Entry ($entry + [ordered]@{ event = 'ok' })
}

function Copy-FactSet {
    param([System.Collections.Generic.Dictionary[string, string]]$Fact)
    $copy = [System.Collections.Generic.Dictionary[string, string]]::new($Fact, [System.StringComparer]::Ordinal)
    , $copy
}

function Save-Result {
    param([System.Collections.IDictionary]$Result)
    if ($runDir) { [System.IO.File]::WriteAllText((Join-Path $runDir 'result.json'), (ConvertTo-Json -InputObject $Result -Depth 8), $utf8NoBom) }
}

# --- Phase 1: no write. Each error stops with exit code 3. -------------------------
$lockStream = $null
try {
    $planFile = Read-ArrPlanFile -Path $PlanPath
    if ($planFile.Sha256 -ne $PlanSha256.Trim().ToUpperInvariant()) {
        throw "The SHA-256 of the plan file is not the approved one. File: $($planFile.Sha256)."
    }
    $plan = $planFile.Plan
    $shapeErrors = @(Get-ArrPlanShapeError -Plan $plan)
    if ($shapeErrors.Count) { throw "The plan has errors: $($shapeErrors -join ' / ')" }
    $baseline = Read-ArrBaseline -Plan $plan
    $verified = @{ sonarr = Get-ArrVerifiedVersion -App sonarr; radarr = Get-ArrVerifiedVersion -App radarr }
    $check = Test-ArrPlan -Plan $plan -State $baseline -VerifiedVersion $verified
    if (@($check.Errors).Count) { throw "The plan has errors: $(@($check.Errors) -join ' / ')" }

    New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
    try {
        # The lock file stays. Only the open handle is the lock.
        $lockStream = [System.IO.File]::Open((Join-Path $RunRoot 'apply.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        throw 'An other apply runs now.'
    }

    $scope = Get-ArrPlanScope -Plan $plan
    $resources = @(Get-ArrRequiredResource -Scope $scope)
    $steps = @(Get-ArrPlanStep -Plan $plan)

    $liveText = Read-LiveText -Resource $resources
    $live = ConvertTo-ArrState -Resource $resources -TextByFile $liveText
    foreach ($app in $scope.Keys) {
        $version = [string]@($live[$app].status)[0].version
        if ($version -cne $verified[$app]) { throw "$app now has version $version. The tool is verified for $($verified[$app])." }
    }

    $targetKeys = @(foreach ($step in $steps) {
            if ($step.Type -like 'monitor*') { (Get-ArrStepChange -Step $step -State $baseline).Keys }
        })
    $drift = @(Compare-ArrFactSet -Expected (Get-ArrFactSet -State $baseline -Scope $scope) `
            -Actual (Get-ArrFactSet -State $live -Scope $scope) -StrictKey $targetKeys)
    if ($drift.Count) { throw "The apps changed after the snapshot. Make a new snapshot and a new plan. $($drift.Count) difference(s): $(($drift | Select-Object -First 10) -join ' / ')" }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $runDir = Join-Path $RunRoot $stamp
    $suffix = 1
    while (Test-Path -LiteralPath $runDir) { $suffix++; $runDir = Join-Path $RunRoot "$stamp-$suffix" }
    New-Item -ItemType Directory -Path (Join-Path $runDir 'backup') -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $runDir 'plan.json'), $planFile.Byte)
    foreach ($file in $liveText.Keys) { [System.IO.File]::WriteAllText((Join-Path $runDir 'backup' $file), $liveText[$file], $utf8NoBom) }
    # The backup is the state before the writes. Nothing changes this object.
    $backup = ConvertTo-ArrState -Resource $resources -TextByFile $liveText
    $backupFacts = Get-ArrFactSet -State $backup -Scope $scope

    $parseBefore = @(foreach ($test in $plan.parseTests) {
            $result = Read-ParseResult -Test $test
            $itemName = if ($test.app -eq 'sonarr') { 'series' } else { 'movie' }
            $item = $result.PSObject.Properties[$itemName]
            if (-not $item -or $null -eq $item.Value) { throw "Parse test '$($test.title)': the title matches no $itemName of the library. Use a different title." }
            $result
        })
} catch {
    'STOPPED before the first write. The apps did not change.'
    $_.Exception.Message
    Save-Result -Result ([ordered]@{ outcome = 'stopped'; failure = $_.Exception.Message })
    if ($lockStream) { $lockStream.Dispose() }
    exit 3
}

"Run folder: $runDir"

# --- Phase 2: writes and checks ---------------------------------------------------
$attempted = [System.Collections.Generic.List[object]]::new()
$refMap = @{}
$failure = $null
try {
    $expected = Copy-FactSet -Fact $backupFacts
    foreach ($step in $steps) {
        $write = Get-ArrStepWrite -Step $step -State $live -RefMap $refMap
        # Add the step BEFORE the send: a write without an answer can change the app.
        $attempted.Add($step)
        Send-PlanWrite -Write $write -Phase 'apply' -Step $step.Number
        Update-LiveApp -Live $live -Resource $resources -App $step.App

        if ($step.Type -ceq 'createCustomFormat') {
            $created = @(Get-ArrCreatedFormat -Step $step -Live $live -Backup $backup)
            if ($created.Count -ne 1) { throw "Step $($step.Number): the live state has $($created.Count) new custom formats with the planned name." }
            $refMap["$($step.App)/$($step.Operation.ref)"] = [int]$created[0].id
        }
        $change = Get-ArrStepChange -Step $step -State $live -RefMap $refMap
        foreach ($key in $change.Keys) { $expected[$key] = $change[$key] }
        $differences = @(Compare-ArrFactSet -Expected $expected -Actual (Get-ArrFactSet -State $live -Scope $scope) -StrictKey $targetKeys -IgnoreHasFile)
        if ($differences.Count) { throw "Step $($step.Number): the live state is not the expected state. $(($differences | Select-Object -First 10) -join ' / ')" }
        "Step $($step.Number) of $($steps.Count): $($step.App) $($step.Type) - written and read again."
    }

    # Full comparison: all custom formats, all scores and all profile fields.
    $live = Read-LiveState -Resource $resources
    $differences = @(Compare-ArrFactSet -Expected $expected -Actual (Get-ArrFactSet -State $live -Scope $scope) -StrictKey $targetKeys -IgnoreHasFile)
    if ($differences.Count) { throw "Final comparison: $(($differences | Select-Object -First 10) -join ' / ')" }
    'Final comparison: only the planned values changed.'

    $parseProblems = @(for ($index = 0; $index -lt $plan.parseTests.Count; $index++) {
            $test = $plan.parseTests[$index]
            Get-ArrParseProblem -Test $test -Before $parseBefore[$index] -After (Read-ParseResult -Test $test) -State $live
        })
    if ($parseProblems.Count) { throw ($parseProblems -join ' / ') }
    if ($plan.parseTests.Count) { "Parse tests: $($plan.parseTests.Count) passed." }
} catch {
    $failure = $_.Exception.Message
}

# --- Phase 3: restore -------------------------------------------------------------
$restoreProblems = [System.Collections.Generic.List[string]]::new()
$restoreDifferences = @()
$outcome = 'applied'
if ($failure) {
    "FAILED: $failure"
    'Restore of the batch starts. The restore deletes nothing.'
    Add-Journal -Entry ([ordered]@{ phase = 'restore'; event = 'start'; failure = $failure })
    $outcome = 'restore-incomplete'
    try {
        for ($index = $attempted.Count - 1; $index -ge 0; $index--) {
            $step = $attempted[$index]
            try {
                Update-LiveApp -Live $live -Resource $resources -App $step.App
                foreach ($write in @(Get-ArrRestoreWrite -Step $step -Live $live -Backup $backup -Scope $scope)) {
                    try { Send-PlanWrite -Write $write -Phase 'restore' -Step $step.Number }
                    catch { $restoreProblems.Add("Step $($step.Number): $($_.Exception.Message)") }
                }
            } catch {
                $restoreProblems.Add("Step $($step.Number): $($_.Exception.Message)")
            }
        }

        # The read of the live state decides if the restore is complete.
        $live = Read-LiveState -Resource $resources
        $restored = Copy-FactSet -Fact $backupFacts
        foreach ($step in @($attempted | Where-Object Type -CEQ 'createCustomFormat')) {
            foreach ($format in Get-ArrCreatedFormat -Step $step -Live $live -Backup $backup) {
                $restored["$($step.App)/cf/$($format.id)"] = Get-ArrFormatKey -CustomFormat $format
                foreach ($qualityProfile in $backup[$step.App].qualityprofile) { $restored["$($step.App)/profile/$($qualityProfile.id)/score/$($format.id)"] = '0' }
                "The new custom format '$($format.name)' (id $($format.id), $($step.App)) stays. The skill deletes nothing."
            }
        }
        $restoreDifferences = @(Compare-ArrFactSet -Expected $restored -Actual (Get-ArrFactSet -State $live -Scope $scope) -StrictKey $targetKeys -IgnoreHasFile)
        if ($restoreDifferences.Count -eq 0) { $outcome = 'restored' }
    } catch {
        $restoreProblems.Add("The check of the restore failed: $($_.Exception.Message)")
    }
}

switch ($outcome) {
    'applied' { 'RESULT: applied. All checks passed.' }
    'restored' {
        'RESULT: the batch failed. The restore is complete: the values are equal to the backup.'
        $restoreProblems | ForEach-Object { "Note: $_" }
    }
    default {
        'RESULT: THE RESTORE IS NOT COMPLETE. Examine these items by hand.'
        $restoreProblems | ForEach-Object { "- $_" }
        $restoreDifferences | ForEach-Object { "- $_" }
        "Backup: $(Join-Path $runDir 'backup')"
        "Journal: $(Join-Path $runDir 'journal.jsonl')"
    }
}

# --- Final snapshot ----------------------------------------------------------------
# Keep it as the last step: the snapshot script loads the modules again.
$finalSnapshot = $null
try {
    $snapshotParameters = @{ App = @($scope.Keys) -join ','; OutputRoot = $SnapshotRoot }
    $seriesIds = @(foreach ($app in $scope.Keys) { $scope[$app].SeriesIds })
    if ($seriesIds.Count) { $snapshotParameters.SeriesId = $seriesIds -join ',' }
    $output = & (Join-Path $PSScriptRoot 'Get-ArrSnapshot.ps1') @snapshotParameters
    $finalSnapshot = @($output | Where-Object { $_ -like 'Snapshot: *' })[0] -replace '\ASnapshot: '
    "Final snapshot: $finalSnapshot"
} catch {
    "WARNING: the final snapshot failed: $($_.Exception.Message)"
}

$seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
"Duration: $seconds s"
Save-Result -Result ([ordered]@{
        outcome            = $outcome
        planSha256         = $planFile.Sha256
        failure            = $failure
        restoreProblems    = @($restoreProblems)
        restoreDifferences = @($restoreDifferences)
        finalSnapshot      = $finalSnapshot
        durationSeconds    = $seconds
    })
$lockStream.Dispose()

exit $(switch ($outcome) { 'applied' { 0 } 'restored' { 1 } default { 2 } })
