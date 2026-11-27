<#
  Start-FakeArrServer.ps1  -  v0.1  (2026-11-27).
  A false Sonarr and a false Radarr for the offline tests. Test-ArrPlan.ps1 starts
  it as a thread job. It listens only on 127.0.0.1 and keeps its data in memory.

  -Shared is a synchronized table:
    Listener  a started HttpListener with one prefix for each app
    PortApp   port to app name
    Key       the false API key
    Data      app to its data
    Log       a queue of the requests
    Faults    a list of faults for the write requests
    Errors    a queue of the errors of this server

  A fault has App, Method, Path, From, To and Mode. From and To give the numbers
  of the matching requests, with 1 as the first. Mode:
    error           status 500, no change
    applyThenError  the change occurs, then status 500 (a lost answer)
    ignore          status 200, no change
    collateral      the change occurs, and one score changes that the plan does
                    not have (ProfileId, FormatId, Score)

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param([Parameter(Mandatory)][System.Collections.IDictionary]$Shared)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Send-FakeAnswer {
    param($Context, [int]$Status, $Body)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $text = if ($null -eq $Body) { '{}' } else { ConvertTo-Json -InputObject $Body -Depth 40 -Compress }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Add-FakeFieldDetail {
    # The real apps add properties to each condition and each field.
    param($Definition, [int]$Id)
    [pscustomobject]@{
        id                              = $Id
        name                            = $Definition.name
        includeCustomFormatWhenRenaming = $Definition.includeCustomFormatWhenRenaming
        specifications                  = @(foreach ($specification in $Definition.specifications) {
                [pscustomobject]@{
                    name = $specification.name; implementation = $specification.implementation
                    implementationName = 'Fake'; infoLink = 'https://example.test'
                    negate = $specification.negate; required = $specification.required
                    fields = @(foreach ($field in $specification.fields) {
                            [pscustomobject]@{ order = 0; name = $field.name; label = 'Fake'; value = $field.value; type = 'textbox'; advanced = $false }
                        })
                }
            })
    }
}

function Test-FakeCondition {
    param($Specification, [string]$Title)
    $match = $false
    if ($Specification.implementation -in 'ReleaseTitleSpecification', 'ReleaseGroupSpecification') {
        $value = [string]@($Specification.fields | Where-Object name -EQ 'value')[0].value
        $text = if ($Specification.implementation -eq 'ReleaseGroupSpecification') { ($Title -split '-')[-1] } else { $Title }
        $match = $text -match $value
    }
    if ($Specification.negate) { -not $match } else { $match }
}

function Get-FakeParse {
    param($Data, [string]$App, [string]$Title)
    $itemName = if ($App -eq 'sonarr') { 'series' } else { 'movie' }
    $plain = $Title -replace '[._]', ' '
    $item = @($Data[$itemName] | Where-Object { $plain.StartsWith($_.title, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
    if (-not $item) { return [pscustomobject]@{ title = $Title; customFormatScore = 0 } }
    $matched = @(foreach ($format in $Data.customformat) {
            $groupFailed = $false
            foreach ($group in @($format.specifications | Group-Object implementation)) {
                $results = @(foreach ($specification in $group.Group) { [pscustomobject]@{ Required = $specification.required; Match = (Test-FakeCondition -Specification $specification -Title $Title) } })
                # The same rule as SpecificationMatchesGroup.DidMatch of the apps.
                if (@($results | Where-Object { $_.Required -and -not $_.Match }).Count -or @($results | Where-Object Match).Count -eq 0) { $groupFailed = $true }
            }
            if (-not $groupFailed) { $format }
        })
    $qualityProfile = @($Data.qualityprofile | Where-Object id -EQ $item.qualityProfileId)[0]
    $score = 0
    foreach ($formatItem in $qualityProfile.formatItems) { if ($formatItem.format -in @($matched | ForEach-Object id)) { $score += $formatItem.score } }
    $answer = [ordered]@{
        title             = $Title
        customFormats     = @($matched | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name } })
        customFormatScore = $score
        parsedInfo        = [pscustomobject]@{ extra = 'not in the output of the tool' }
    }
    $answer[$itemName] = [pscustomobject]@{ id = $item.id; title = $item.title; path = $item.path }
    [pscustomobject]$answer
}

function Invoke-FakeWrite {
    # Changes the data. Returns the answer.
    param($Data, [string]$Method, [string]$Path, $Body)
    switch -Regex ("$Method $Path") {
        '\APOST customformat\z' {
            if (@($Data.customformat | Where-Object name -CEQ $Body.name).Count) { throw 'Must be unique.' }
            $id = 1 + ($Data.customformat | Measure-Object id -Maximum).Maximum
            $format = Add-FakeFieldDetail -Definition $Body -Id $id
            $Data.customformat = @($Data.customformat) + $format
            foreach ($qualityProfile in $Data.qualityprofile) {
                $qualityProfile.formatItems = @([pscustomobject]@{ format = $id; name = $Body.name; score = 0 }) + @($qualityProfile.formatItems)
            }
            return $format
        }
        '\APUT customformat/(\d+)\z' {
            $id = [int]$Matches[1]
            $Data.customformat = @(foreach ($format in $Data.customformat) {
                    if ($format.id -eq $id) { Add-FakeFieldDetail -Definition $Body -Id $id } else { $format }
                })
            return @{ id = $id }
        }
        '\APUT qualityprofile/(\d+)\z' {
            $id = [int]$Matches[1]
            $ids = @($Body.formatItems | ForEach-Object format)
            if (@($Data.customformat | Where-Object { $_.id -notin $ids }).Count) { throw 'All Custom Formats must be present.' }
            if ($Body.minUpgradeFormatScore -lt 1) { throw 'minUpgradeFormatScore must be 1 or more.' }
            $Data.qualityprofile = @(foreach ($qualityProfile in $Data.qualityprofile) { if ($qualityProfile.id -eq $id) { $Body } else { $qualityProfile } })
            return @{ id = $id }
        }
        '\APUT series/editor\z' {
            foreach ($series in $Data.series) { if ($series.id -in $Body.seriesIds) { $series.monitored = $Body.monitored } }
            return @{}
        }
        '\APOST seasonpass\z' {
            foreach ($entry in $Body.series) {
                $series = @($Data.series | Where-Object id -EQ $entry.id)[0]
                foreach ($wanted in $entry.seasons) {
                    foreach ($season in $series.seasons) { if ($season.seasonNumber -eq $wanted.seasonNumber) { $season.monitored = $wanted.monitored } }
                }
            }
            # The real app changes each episode if the body has this key.
            if ($Body.PSObject.Properties['monitoringOptions']) { foreach ($episode in $Data.episode) { $episode.monitored = $false } }
            return @{}
        }
        '\APUT episode/monitor\z' {
            foreach ($episode in $Data.episode) { if ($episode.id -in $Body.episodeIds) { $episode.monitored = $Body.monitored } }
            return @{}
        }
        '\APUT movie/editor\z' {
            foreach ($movie in $Data.movie) { if ($movie.id -in $Body.movieIds) { $movie.monitored = $Body.monitored } }
            return @{}
        }
        default { throw "The false server has no route $Method $Path." }
    }
}

$listener = $Shared.Listener
while ($listener.IsListening) {
    try { $context = $listener.GetContext() } catch { break }
    try {
        $request = $context.Request
        $app = $Shared.PortApp[$request.LocalEndPoint.Port]
        $data = $Shared.Data[$app]
        $path = $request.Url.AbsolutePath -replace '\A/api/v3/'
        $reader = [System.IO.StreamReader]::new($request.InputStream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $Shared.Log.Enqueue([pscustomobject]@{ App = $app; Method = $request.HttpMethod; Path = $path; Query = $request.Url.Query; Body = $text; ContentType = $request.ContentType })

        if ($request.Headers['X-Api-Key'] -cne $Shared.Key) { Send-FakeAnswer -Context $context -Status 401 -Body $null; continue }

        if ($request.HttpMethod -eq 'GET') {
            $answer = switch ($path) {
                'system/status' { $data.status }
                'config/mediamanagement' { $data.mediamanagement }
                'episode' { , @($data.episode | Where-Object seriesId -EQ ([int]$request.QueryString['seriesId'])) }
                'parse' { Get-FakeParse -Data $data -App $app -Title $request.QueryString['title'] }
                default {
                    if ($data.Contains($path)) { , @($data[$path]) } else { throw "The false server has no resource $path." }
                }
            }
            Send-FakeAnswer -Context $context -Status 200 -Body $answer
            continue
        }

        if ($request.HttpMethod -notin 'POST', 'PUT') {
            $Shared.Errors.Enqueue("FORBIDDEN METHOD $($request.HttpMethod) $path")
            Send-FakeAnswer -Context $context -Status 500 -Body $null
            continue
        }

        $mode = ''
        $fault = $null
        foreach ($candidate in @($Shared.Faults)) {
            if ($candidate.App -eq $app -and $candidate.Method -eq $request.HttpMethod -and $candidate.Path -eq $path) {
                $candidate.Count++
                if ($candidate.Count -ge $candidate.From -and $candidate.Count -le $candidate.To) { $mode = $candidate.Mode; $fault = $candidate }
            }
        }
        if ($mode -eq 'error') { Send-FakeAnswer -Context $context -Status 500 -Body $null; continue }
        if ($mode -eq 'ignore') { Send-FakeAnswer -Context $context -Status 200 -Body $null; continue }

        $body = $text | ConvertFrom-Json -Depth 64 -DateKind String
        $answer = Invoke-FakeWrite -Data $data -Method $request.HttpMethod -Path $path -Body $body
        if ($mode -eq 'collateral') {
            $qualityProfile = @($data.qualityprofile | Where-Object id -EQ $fault.ProfileId)[0]
            foreach ($item in $qualityProfile.formatItems) { if ($item.format -eq $fault.FormatId) { $item.score = $fault.Score } }
        }
        if ($mode -eq 'applyThenError') { Send-FakeAnswer -Context $context -Status 500 -Body $null; continue }
        $status = if ($path -eq 'customformat') { 201 } else { 202 }
        Send-FakeAnswer -Context $context -Status $status -Body $answer
    } catch {
        $Shared.Errors.Enqueue("$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)")
        try { Send-FakeAnswer -Context $context -Status 400 -Body @(@{ errorMessage = $_.Exception.Message }) } catch { }
    }
}
