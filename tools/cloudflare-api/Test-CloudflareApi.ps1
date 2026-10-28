<#
.SYNOPSIS
Offline test of CloudflareApi.psm1. It makes no network call and it does not read the real token.
.DESCRIPTION
The test replaces Invoke-RestMethod with a function in the global scope and uses a
temporary credential file. It checks the read-only guards, the token handling and the
queries. Exit code 0 = all checks passed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CloudflareApi.psm1') -Force

$fakeToken = 'TEST-TOKEN-NOT-REAL-0123456789'
$zoneId = '0123456789abcdef0123456789abcdef'
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('cf-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
$credentialFile = Join-Path $temporaryDirectory 'credentials.json'
@{ readToken = $fakeToken } | ConvertTo-Json | Set-Content -LiteralPath $credentialFile -Encoding utf8
$env:CLOUDFLARE_CLAUDE_CREDENTIAL_PATH = $credentialFile

$script:failures = 0
$global:CfTestCalls = [System.Collections.Generic.List[object]]::new()
$global:CfTestAnswer = $null
$global:CfTestThrow = $false

function Assert-Test {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { '[ OK ] {0}' -f $Name }
    else { '[FAIL] {0}' -f $Name; $script:failures++ }
}

# Replaces the cmdlet for the module too: a function wins over a cmdlet.
function global:Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Authentication, $Token, $ContentType, $Body)
    $global:CfTestCalls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body })
    if ($global:CfTestThrow) { throw 'simulated network failure' }
    $answer = $global:CfTestAnswer
    if ($answer -is [scriptblock]) { return (& $answer $Uri) }
    $answer
}

try {
    # 1. Read-only guards.
    $rejected = $false
    try { Invoke-CloudflareApi -Path '/zones' -Method 'POST' } catch { $rejected = $true }
    Assert-Test 'Invoke-CloudflareApi rejects POST' $rejected

    $rejected = $false
    try { Invoke-CloudflareGraphQl -Query 'mutation { x }' } catch { $rejected = $true }
    Assert-Test 'Invoke-CloudflareGraphQl rejects a mutation' $rejected

    # 2. A zone lookup builds the right URL and parses the answer.
    $global:CfTestCalls.Clear()
    $global:CfTestAnswer = [pscustomobject]@{
        success = $true; errors = @()
        result  = @([pscustomobject]@{ id = $zoneId; name = 'example.test'; status = 'active'; plan = [pscustomobject]@{ name = 'Free Website' } })
    }
    $zone = Get-CloudflareZone -Name 'example.test'
    Assert-Test 'Get-CloudflareZone parses the zone' ($zone.Id -eq $zoneId -and $zone.Plan -eq 'Free Website')
    Assert-Test 'Get-CloudflareZone sends GET with the name' ($global:CfTestCalls[0].Method -eq 'GET' -and $global:CfTestCalls[0].Uri -like '*/zones?name=example.test')

    # 3. The token never appears in an error text.
    $global:CfTestThrow = $true
    $message = ''
    try { Get-CloudflareZone -Name 'example.test' } catch { $message = $_.Exception.Message }
    $global:CfTestThrow = $false
    Assert-Test 'An error text does not contain the token' ($message -and $message -notlike "*$fakeToken*")

    # 4. DNS records: two pages.
    $global:CfTestCalls.Clear()
    $global:CfTestAnswer = {
        param($Uri)
        if ($Uri -like '*/zones?name=*') {
            return [pscustomobject]@{ success = $true; errors = @(); result = @([pscustomobject]@{ id = $zoneId; name = 'example.test'; status = 'active' }) }
        }
        $page = if ($Uri -like '*page=2*') { 2 } else { 1 }
        [pscustomobject]@{
            success = $true; errors = @(); result_info = [pscustomobject]@{ total_pages = 2 }
            result  = @([pscustomobject]@{ name = "r$page.example.test"; type = 'A'; content = '192.0.2.1'; proxied = $false; ttl = 1 })
        }
    }
    $records = @(Get-CloudflareDnsRecord -ZoneName 'example.test')
    Assert-Test 'Get-CloudflareDnsRecord reads both pages' ($records.Count -eq 2 -and $records[1].Name -eq 'r2.example.test')

    # 5. The traffic query has the zone, a dataset for one day and a summary.
    $global:CfTestCalls.Clear()
    $global:CfTestAnswer = {
        param($Uri)
        if ($Uri -like '*/zones?name=*') {
            return [pscustomobject]@{ success = $true; errors = @(); result = @([pscustomobject]@{ id = $zoneId; name = 'example.test'; status = 'active' }) }
        }
        $rows = foreach ($requests in 10, 12, 500) {
            [pscustomobject]@{
                dimensions = [pscustomobject]@{ datetime = '2026-10-27T01:00:00Z' }
                sum        = [pscustomobject]@{
                    requests = $requests; cachedRequests = [int]($requests / 2); bytes = 1MB; cachedBytes = 0; threats = 0
                    responseStatusMap = @([pscustomobject]@{ edgeResponseStatus = 200; requests = $requests })
                    countryMap = @([pscustomobject]@{ clientCountryName = 'IT'; requests = $requests })
                }
            }
        }
        [pscustomobject]@{ data = [pscustomobject]@{ viewer = [pscustomobject]@{ zones = @([pscustomobject]@{ httpRequests1hGroups = @($rows) }) } } }
    }
    $traffic = Get-CloudflareTraffic -ZoneName 'example.test' -Days 1
    $body = ($global:CfTestCalls | Where-Object { $_.Body } | Select-Object -First 1).Body
    Assert-Test 'The traffic query has the zone tag and the hourly dataset' ($body -like "*$zoneId*" -and $body -like '*httpRequests1hGroups*')
    Assert-Test 'The traffic summary has totals, peak and median' ($traffic.Requests -eq 522 -and $traffic.PeakRequests -eq 500 -and $traffic.MedianRequests -eq 12)

    # 6. The security query has no URI field and no client IP field.
    $global:CfTestCalls.Clear()
    $global:CfTestAnswer = {
        param($Uri)
        if ($Uri -like '*/zones?name=*') {
            return [pscustomobject]@{ success = $true; errors = @(); result = @([pscustomobject]@{ id = $zoneId; name = 'example.test'; status = 'active' }) }
        }
        $rows = 1..7 | ForEach-Object { [pscustomobject]@{ action = 'block'; source = 'l7ddos'; clientCountryName = 'XX' } }
        $rows += [pscustomobject]@{ action = 'managed_challenge'; source = 'firewallManaged'; clientCountryName = 'YY' }
        [pscustomobject]@{ data = [pscustomobject]@{ viewer = [pscustomobject]@{ zones = @([pscustomobject]@{ firewallEventsAdaptive = @($rows) }) } } }
    }
    $events = @(Get-CloudflareSecurityEvent -ZoneName 'example.test' -Hours 24)
    $body = ($global:CfTestCalls | Where-Object { $_.Body } | Select-Object -First 1).Body
    Assert-Test 'The security query does not ask for a URI or an IP address' ($body -notmatch 'clientIP|clientRequestPath|clientRequestQuery')
    Assert-Test 'The security query uses the raw dataset (the grouped one is not on the Free plan)' ($body -like '*firewallEventsAdaptive(*' -and $body -notlike '*firewallEventsAdaptiveGroups*')
    Assert-Test 'The security events are counted by action, source and country' ($events.Count -eq 2 -and $events[0].Source -eq 'l7ddos' -and $events[0].Count -eq 7 -and $events[1].Count -eq 1)
}
finally {
    Remove-Item function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item Env:\CLOUDFLARE_CLAUDE_CREDENTIAL_PATH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Error "$($script:failures) check(s) failed."
    exit 1
}
'All checks passed.'
