<#
  Test-ArrApi.ps1  -  v0.3  (2026-11-27).
  Offline tests of ArrApi.psm1 and static tests of the source files. The tests use
  false data with a canary value. They send no request and read no config.xml.

  The tests of the write function set ProgramData of this process to a folder that
  does not exist. Thus the module cannot read a key, and a body that passes the check
  stops at that read. Each body of these tests has an id that no app has.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ArrApi.psm1') -Force

$canary = 'CANARY-0123456789abcdef'
$script:FailCount = 0

function Test-Case {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Condition
    )
    $passed = $false
    try { $passed = [bool](& $Condition) } catch { $passed = $false }
    if (-not $passed) { $script:FailCount++ }
    '{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $Name
}

function Test-Throws {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Action)
    try { & $Action | Out-Null; $false } catch { $true }
}

function Get-ErrorText {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try { & $Action | Out-Null; '' } catch { $_.Exception.Message }
}

$indexer = [pscustomobject]@{
    id = 1; name = 'Mock'; enable = $true
    fields = @(@{ name = 'apiKey'; value = $canary })
    infoLink = "https://example.test/?passkey=$canary"
}
$safeIndexer = @(Select-ArrSafeProperty -InputItem @($indexer) -Keep @('id', 'name', 'enable'))
Test-Case 'The allowlist removes fields and URLs' { -not (ConvertTo-Json -InputObject $safeIndexer -Depth 8).Contains($canary) }
Test-Case 'The allowlist keeps the listed properties' { $safeIndexer[0].name -eq 'Mock' -and $safeIndexer[0].enable }

$series = [pscustomobject]@{
    id = 2; seasons = @([pscustomobject]@{ seasonNumber = 1; monitored = $false; statistics = $canary })
}
$safeSeries = @(Select-ArrSafeProperty -InputItem @($series) -Keep @('id', 'seasons'))
Test-Case 'A season keeps only two properties' { -not (ConvertTo-Json -InputObject $safeSeries -Depth 8).Contains($canary) }

$parse = [pscustomobject]@{
    series = [pscustomobject]@{ id = 3; title = 'Mock'; path = $canary }
    customFormats = @([pscustomobject]@{ id = 4; name = 'AAC'; specifications = $canary })
}
$safeParse = @(Select-ArrSafeProperty -InputItem @($parse) -Keep @('series', 'customFormats'))
Test-Case 'A parse answer keeps only the ids and the names' {
    -not (ConvertTo-Json -InputObject $safeParse -Depth 8).Contains($canary) -and $safeParse[0].series.id -eq 3 -and @($safeParse[0].customFormats).Count -eq 1
}

Test-Case 'Leak check stops a URL with a passkey' { Test-Throws { Assert-ArrNoSecret -Text "{`"u`":`"https://x.test/a?passkey=$canary`"}" -Label 'mock' } }
Test-Case 'Leak check stops a password property' { Test-Throws { Assert-ArrNoSecret -Text "{`"password`": `"$canary`"}" -Label 'mock' } }
Test-Case 'Leak check accepts a masked value' { -not (Test-Throws { Assert-ArrNoSecret -Text '{"password": "********"}' -Label 'mock' }) }
Test-Case 'Leak check accepts a custom format' { -not (Test-Throws { Assert-ArrNoSecret -Text '{"name":"FLAC","value":"\\bFLAC(\\b|\\d)"}' -Label 'mock' }) }

# These names must stop BEFORE the module reads a key.
Test-Case 'config/host is not a resource' { Test-Throws { Get-ArrResourceJson -App sonarr -Name 'config/host' } }
Test-Case 'downloadclient is not a resource' { Test-Throws { Get-ArrResourceJson -App radarr -Name 'downloadclient' } }
Test-Case 'command is not a resource' { Test-Throws { Get-ArrResourceJson -App sonarr -Name 'command' } }
Test-Case 'A snapshot list has no resource with a query value' {
    $names = @(Get-ArrResourceName -App sonarr)
    $names -notcontains 'episode' -and $names -notcontains 'parse' -and $names -contains 'series'
}
Test-Case 'The episode list needs a series id' { (Get-ErrorText { Get-ArrResourceJson -App sonarr -Name episode }) -match 'needs a value' }
Test-Case 'A series id must be a number' { (Get-ErrorText { Get-ArrResourceJson -App sonarr -Name episode -QueryValue '1&apikey=x' }) -match 'must be a number' }
Test-Case 'A resource with no query accepts no value' { (Get-ErrorText { Get-ArrResourceJson -App sonarr -Name series -QueryValue '1' }) -match 'accepts no query value' }
Test-Case 'Prowlarr indexer has no "fields" in the output list' {
    (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ArrApi.psm1') -Raw) -notmatch "Keep\s*=\s*@\([^)]*'fields'"
}

# --- Write table -----------------------------------------------------------------
$operations = @(Get-ArrWriteOperation -App sonarr; Get-ArrWriteOperation -App radarr)
Test-Case 'Each write method is Post or Put' { @($operations | Where-Object { $_.Method -cnotin 'Post', 'Put' }).Count -eq 0 }
$permittedPath = 'customformat', 'customformat/{id}', 'qualityprofile/{id}', 'series/editor', 'seasonpass', 'episode/monitor', 'movie/editor'
Test-Case 'Each write path is in the list of this test' { @($operations | Where-Object { $_.Path -cnotin $permittedPath }).Count -eq 0 }
Test-Case 'Prowlarr has no write operation' { Test-Throws { Get-ArrWriteOperation -App prowlarr } }

# --- Body check before the read of a key -----------------------------------------
$noProgramData = Join-Path ([System.IO.Path]::GetTempPath()) ('arr-api-no-config-' + [guid]::NewGuid().ToString('N'))
$oldProgramData = $env:ProgramData
try {
    $env:ProgramData = $noProgramData
    if (Test-Path -LiteralPath $env:ProgramData) { throw 'The false ProgramData folder exists. The test stops.' }
    $noId = 2147483000

    function Test-BodyRejected {
        param([string]$Name, [string]$App, [string]$Operation, [string]$Body)
        $text = Get-ErrorText { Invoke-ArrWrite -App $App -Operation $Operation -BodyJson $Body }
        Test-Case "Body rejected before a key read: $Name" { $text -match '\ABody check:' }
    }

    Test-BodyRejected 'moveFiles' radarr movie.monitor "{`"movieIds`":[$noId],`"monitored`":false,`"moveFiles`":true}"
    Test-BodyRejected 'rootFolderPath' radarr movie.monitor "{`"movieIds`":[$noId],`"monitored`":false,`"rootFolderPath`":`"X:\\`"}"
    Test-BodyRejected 'deleteFiles' sonarr series.monitor "{`"seriesIds`":[$noId],`"monitored`":false,`"deleteFiles`":true}"
    Test-BodyRejected 'MoveFiles with a capital letter' sonarr series.monitor "{`"seriesIds`":[$noId],`"monitored`":false,`"MoveFiles`":true}"
    Test-BodyRejected 'a second key with a different case' sonarr series.monitor "{`"seriesIds`":[$noId],`"monitored`":false,`"Monitored`":true}"
    Test-BodyRejected 'the same key two times' sonarr series.monitor "{`"seriesIds`":[$noId],`"monitored`":false,`"monitored`":true}"
    Test-BodyRejected 'monitoringOptions' sonarr season.monitor "{`"series`":[{`"id`":$noId,`"seasons`":[{`"seasonNumber`":1,`"monitored`":false}]}],`"monitoringOptions`":{`"monitor`":`"none`"}}"
    Test-BodyRejected 'a path in a season entry' sonarr season.monitor "{`"series`":[{`"id`":$noId,`"path`":`"X:\\`",`"seasons`":[{`"seasonNumber`":1,`"monitored`":false}]}]}"
    Test-BodyRejected 'a season with no monitored value' sonarr season.monitor "{`"series`":[{`"id`":$noId,`"seasons`":[{`"seasonNumber`":1}]}]}"
    Test-BodyRejected 'episodes with no monitored value' sonarr episode.monitor "{`"episodeIds`":[$noId]}"
    Test-BodyRejected 'monitored as a text' sonarr episode.monitor "{`"episodeIds`":[$noId],`"monitored`":`"false`"}"
    Test-BodyRejected 'an empty id list' radarr movie.monitor '{"movieIds":[],"monitored":false}'
    Test-BodyRejected 'a body that is not JSON' radarr movie.monitor 'movieIds=1'

    Test-Case 'A correct body passes the check and stops only at the read of the key' {
        (Get-ErrorText { Invoke-ArrWrite -App radarr -Operation movie.monitor -BodyJson "{`"movieIds`":[$noId],`"monitored`":false}" }) -match 'Cannot read the necessary values'
    }
    Test-Case 'The command operation does not exist' { (Get-ErrorText { Invoke-ArrWrite -App sonarr -Operation command -BodyJson '{"name":"x"}' }) -match 'not in the write list' }
    Test-Case 'An operation name with a different case does not exist' { (Get-ErrorText { Invoke-ArrWrite -App sonarr -Operation 'Series.Monitor' -BodyJson '{}' }) -match 'not in the write list' }
    Test-Case 'Radarr has no series operation' { (Get-ErrorText { Invoke-ArrWrite -App radarr -Operation series.monitor -BodyJson '{}' }) -match 'not in the write list' }
    Test-Case 'The id of the body must be the id of the path' {
        $body = '{"id":2147483000,"name":"x","includeCustomFormatWhenRenaming":false,"specifications":[{"name":"a","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"a"}]}]}'
        (Get-ErrorText { Invoke-ArrWrite -App sonarr -Operation customformat.update -Id 2147482999 -BodyJson $body }) -match 'not equal to -Id'
    }
} finally {
    $env:ProgramData = $oldProgramData
}

# --- Static checks of the source files ---------------------------------------------
$sourceNames = 'ArrApi.psm1', 'ArrPlan.psm1', 'Get-ArrSnapshot.ps1', 'New-ArrPlan.ps1', 'Show-ArrPlan.ps1', 'Invoke-ArrPlan.ps1'
$requests = [System.Collections.Generic.List[object]]::new()
$forbidden = [System.Collections.Generic.List[string]]::new()
$deleteAlias = 'Remove-Item', 'Move-Item', 'Rename-Item', 'Clear-Content', 'Clear-Item', 'rm', 'del', 'rd', 'ri', 'erase', 'rmdir', 'mv', 'move', 'mi', 'ren', 'rni', 'clc'
foreach ($sourceName in $sourceNames) {
    $path = Join-Path $PSScriptRoot $sourceName
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { $forbidden.Add("$sourceName has a parse error.") }
    foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -in 'Invoke-RestMethod', 'Invoke-WebRequest', 'irm', 'iwr', 'curl', 'wget') {
            $requests.Add([pscustomobject]@{ File = $sourceName; Command = $name; Text = $command.Extent.Text })
        }
        if ($name -in $deleteAlias) { $forbidden.Add("${sourceName}: $name") }
        if ($name -in 'Invoke-Expression', 'iex', 'Start-Process') { $forbidden.Add("${sourceName}: $name") }
    }
    $text = Get-Content -LiteralPath $path -Raw
    foreach ($pattern in '\[(System\.)?IO\.(File|Directory)\]::(Delete|Move|Replace)', '\.Delete\(', 'HttpClient|WebClient|HttpWebRequest|\[(System\.)?Net\.WebRequest\]', '-CustomMethod') {
        if ($text -match $pattern) { $forbidden.Add("${sourceName}: $pattern") }
    }
}
Test-Case 'No source file can delete or move a file, or use an other HTTP client' { $forbidden.Count -eq 0 }
$forbidden | ForEach-Object { "      $_" }
Test-Case 'Only ArrApi.psm1 sends requests, with 3 commands' { $requests.Count -eq 3 -and @($requests | Where-Object File -NE 'ArrApi.psm1').Count -eq 0 }
Test-Case 'The 3 requests are one GET, one POST and one PUT, each with a literal method and no splat' {
    $methods = @(foreach ($request in $requests) {
            if ($request.Command -ne 'Invoke-RestMethod' -or $request.Text -match '(^|\s)@\w') { 'bad' }
            elseif ($request.Text -match '(?i)\s-Method\s+(\w+)(?=\s)') { $Matches[1] }
            else { 'none' }
        })
    (@($methods | Sort-Object) -join ',') -ceq 'Get,Post,Put'
}

if ($script:FailCount -gt 0) { throw "$($script:FailCount) test(s) failed." }
'All tests passed.'
