<#
.SYNOPSIS
Offline test of CloudflareDnsWrite.psm1. It makes no network call and it does not read the real tokens.
.DESCRIPTION
The test replaces Invoke-RestMethod with a function in the global scope and uses a
temporary credential file with two fake tokens. It checks the dry run, the plan id, the
guards, the path restriction and the use of each token. Exit code 0 = all checks passed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CloudflareApi.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CloudflareDnsWrite.psm1') -Force

$readToken = 'TEST-READ-TOKEN-NOT-REAL-0001'
$writeToken = 'TEST-WRITE-TOKEN-NOT-REAL-0002'
$zoneId = '0123456789abcdef0123456789abcdef'
$recordId = 'fedcba9876543210fedcba9876543210'
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('cf-dns-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
$credentialFile = Join-Path $temporaryDirectory 'credentials.json'
@{ readToken = $readToken; writeToken = $writeToken } | ConvertTo-Json | Set-Content -LiteralPath $credentialFile -Encoding utf8
$env:CLOUDFLARE_CLAUDE_CREDENTIAL_PATH = $credentialFile

$script:failures = 0
$global:CfTestCalls = [System.Collections.Generic.List[object]]::new()
$global:CfTestExisting = @()
$global:CfTestThrow = $false

function Assert-Test {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { '[ OK ] {0}' -f $Name }
    else { '[FAIL] {0}' -f $Name; $script:failures++ }
}

function Get-WriteCall { @($global:CfTestCalls | Where-Object { $_.Method -in 'POST', 'PATCH', 'DELETE' }) }

# Replaces the cmdlet for the modules too: a function wins over a cmdlet.
function global:Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Authentication, $Token, $ContentType, $Body)
    $plain = if ($Token) { [System.Net.NetworkCredential]::new('', $Token).Password } else { $null }
    $global:CfTestCalls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body; Token = $plain })
    if ($global:CfTestThrow) { throw 'simulated network failure' }
    if ($Method -eq 'Get' -or $Method -eq 'GET') {
        if ($Uri -like '*/zones?name=*') {
            return [pscustomobject]@{ success = $true; errors = @(); result = @([pscustomobject]@{ id = $zoneId; name = 'example.test'; status = 'active' }) }
        }
        return [pscustomobject]@{ success = $true; errors = @(); result = @($global:CfTestExisting) }
    }
    $sent = if ($Body) { $Body | ConvertFrom-Json } else { $null }
    $result = [pscustomobject]@{
        id      = $recordId
        content = if ($sent -and $sent.PSObject.Properties['content']) { $sent.content } else { 'unchanged' }
        proxied = if ($sent -and $sent.PSObject.Properties['proxied']) { $sent.proxied } else { $false }
        ttl     = 1
    }
    [pscustomobject]@{ success = $true; errors = @(); result = $result }
}

function New-ExistingRecord {
    param([string]$Name, [string]$Type, [string]$Content)
    [pscustomobject]@{ id = $recordId; name = $Name; type = $Type; content = $Content; proxied = $false; ttl = 1 }
}

$zone = 'example.test'
try {
    # 1. A dry run sends no write request.
    $global:CfTestExisting = @()
    $dry = New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10'
    Assert-Test 'A dry run gives the mode DryRun, a plan id and the full name' ($dry.Mode -eq 'DryRun' -and $dry.PlanId -match '^[0-9a-f]{12}$' -and $dry.Name -eq "zz-test.$zone")
    Assert-Test 'A dry run sends no write request' ((Get-WriteCall).Count -eq 0)
    Assert-Test 'The reads of a dry run use the read token' (@($global:CfTestCalls | Where-Object { $_.Token -ne $readToken }).Count -eq 0)

    # 2. -Apply needs the right plan id.
    $failed = $false
    try { New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10' -Apply } catch { $failed = $true }
    Assert-Test '-Apply with no -PlanId is refused' $failed
    $failed = $false
    try { New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10' -Apply -PlanId '000000000000' } catch { $failed = $true }
    Assert-Test '-Apply with a wrong plan id is refused' $failed
    $failed = $false
    try { New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.99' -Apply -PlanId $dry.PlanId } catch { $failed = $true }
    Assert-Test 'The plan id of another content is refused' $failed
    Assert-Test 'No refused call sent a write request' ((Get-WriteCall).Count -eq 0)

    # 3. The plan id is stable, and it changes with the content.
    $again = New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10'
    Assert-Test 'The same change gives the same plan id' ($again.PlanId -eq $dry.PlanId)

    # 4. Create with the right plan id: one POST, the write token, the right body.
    $global:CfTestCalls.Clear()
    $applied = New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10' -Apply -PlanId $dry.PlanId
    $writes = Get-WriteCall
    Assert-Test 'Create sends one POST on the collection with the write token' ($writes.Count -eq 1 -and $writes[0].Method -eq 'POST' -and $writes[0].Uri -like "*/zones/$zoneId/dns_records" -and $writes[0].Token -eq $writeToken)
    $sent = $writes[0].Body | ConvertFrom-Json
    Assert-Test 'Create sends the full name, DNS only and automatic TTL' ($sent.name -eq "zz-test.$zone" -and $sent.proxied -eq $false -and $sent.ttl -eq 1 -and $sent.content -eq '192.0.2.10')
    Assert-Test 'The result says Applied' ($applied.Mode -eq 'Applied' -and $applied.After.Content -eq '192.0.2.10')

    # 5. Update: PATCH of one record with the changed field only.
    $global:CfTestExisting = @(New-ExistingRecord -Name "zz-test.$zone" -Type 'A' -Content '192.0.2.10')
    $dry = Set-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.20'
    Assert-Test 'The dry run of an update shows the record before' ($dry.Before.Content -eq '192.0.2.10')
    $global:CfTestCalls.Clear()
    Set-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.20' -Apply -PlanId $dry.PlanId | Out-Null
    $writes = Get-WriteCall
    $sent = $writes[0].Body | ConvertFrom-Json
    Assert-Test 'Update sends one PATCH on the record with the content only' ($writes.Count -eq 1 -and $writes[0].Method -eq 'PATCH' -and $writes[0].Uri -like "*/dns_records/$recordId" -and @($sent.PSObject.Properties).Count -eq 1 -and $sent.content -eq '192.0.2.20')

    # 6. Delete: one DELETE and no body.
    $dry = Remove-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A
    $global:CfTestCalls.Clear()
    Remove-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Apply -PlanId $dry.PlanId | Out-Null
    $writes = Get-WriteCall
    Assert-Test 'Delete sends one DELETE on the record with no body' ($writes.Count -eq 1 -and $writes[0].Method -eq 'DELETE' -and $writes[0].Uri -like "*/dns_records/$recordId" -and -not $writes[0].Body)

    # 7. Cases that stop before a request.
    $global:CfTestExisting = @(New-ExistingRecord -Name "zz-test.$zone" -Type 'A' -Content '192.0.2.10')
    $failed = $false
    try { New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10' } catch { $failed = $true }
    Assert-Test 'Create of a record that exists is refused' $failed
    $global:CfTestExisting = @()
    $failed = $false
    try { Remove-CloudflareDnsRecord -ZoneName $zone -Name 'zz-none' -Type A } catch { $failed = $true }
    Assert-Test 'Delete of a record that does not exist is refused' $failed
    $global:CfTestExisting = @(New-ExistingRecord -Name "zz-test.$zone" -Type 'A' -Content '192.0.2.10')
    $failed = $false
    try { Set-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A } catch { $failed = $true }
    Assert-Test 'An update with nothing to change is refused' $failed

    # 8. The guards.
    $global:CfTestExisting = @()
    foreach ($case in @(
            @{ Label = 'the apex'; Name = '@'; Type = 'A'; Content = '192.0.2.1' }
            @{ Label = 'a wildcard'; Name = '*'; Type = 'A'; Content = '192.0.2.1' }
            @{ Label = 'a TXT record'; Name = 'zz-test'; Type = 'TXT'; Content = 'hello' }
            @{ Label = 'an MX record'; Name = 'zz-test'; Type = 'MX'; Content = 'mail.example.test' })) {
        $failed = $false
        try { New-CloudflareDnsRecord -ZoneName $zone -Name $case.Name -Type $case.Type -Content $case.Content } catch { $failed = $true }
        Assert-Test "The guard blocks $($case.Label)" $failed
    }
    $forced = New-CloudflareDnsRecord -ZoneName $zone -Name '@' -Type A -Content '192.0.2.1' -Force
    Assert-Test '-Force lets the apex pass the guard (dry run only)' ($forced.Mode -eq 'DryRun')
    $failed = $false
    try { New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content 'not-an-ip' } catch { $failed = $true }
    Assert-Test 'An A record with a content that is not IPv4 is refused' $failed
    $failed = $false
    try { New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '2001:db8::1' } catch { $failed = $true }
    Assert-Test 'An A record with an IPv6 content is refused' $failed

    # 9. The private write function accepts only a DNS record path.
    $module = Get-Module CloudflareDnsWrite
    foreach ($case in @(
            @{ Label = 'the security level of the zone'; Method = 'POST'; Path = "/zones/$zoneId/settings/security_level" }
            @{ Label = 'the zone itself'; Method = 'DELETE'; Path = "/zones/$zoneId" }
            @{ Label = 'the method PUT'; Method = 'PUT'; Path = "/zones/$zoneId/dns_records/$recordId" }
            @{ Label = 'POST on one record'; Method = 'POST'; Path = "/zones/$zoneId/dns_records/$recordId" }
            @{ Label = 'DELETE on the collection'; Method = 'DELETE'; Path = "/zones/$zoneId/dns_records" })) {
        $global:CfTestCalls.Clear()
        $failed = $false
        try { & $module { param($m, $p) Invoke-CloudflareDnsWrite -Method $m -Path $p } $case.Method $case.Path } catch { $failed = $true }
        Assert-Test "The write function refuses $($case.Label)" ($failed -and (Get-WriteCall).Count -eq 0)
    }

    # 10. An error text has no token. A missing writeToken has a clear message.
    $global:CfTestExisting = @()
    $dry = New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10'
    $global:CfTestCalls.Clear()
    $message = ''
    try {
        $global:CfTestThrow = $false
        # The zone lookup and the record lookup pass. Only the write request fails.
        Remove-Item function:\global:Invoke-RestMethod
        function global:Invoke-RestMethod {
            [CmdletBinding()]
            param($Uri, $Method, $Authentication, $Token, $ContentType, $Body)
            if ($Method -in 'POST', 'PATCH', 'DELETE') { throw 'simulated write failure' }
            if ($Uri -like '*/zones?name=*') { return [pscustomobject]@{ success = $true; errors = @(); result = @([pscustomobject]@{ id = $zoneId; name = 'example.test'; status = 'active' }) } }
            [pscustomobject]@{ success = $true; errors = @(); result = @() }
        }
        New-CloudflareDnsRecord -ZoneName $zone -Name 'zz-test' -Type A -Content '192.0.2.10' -Apply -PlanId $dry.PlanId
    }
    catch { $message = $_.Exception.Message }
    Assert-Test 'A failed write gives an error text with no token' ($message -and $message -notlike "*$writeToken*" -and $message -notlike "*$readToken*")

    @{ readToken = $readToken } | ConvertTo-Json | Set-Content -LiteralPath $credentialFile -Encoding utf8
    $message = ''
    try { Test-CloudflareWriteToken } catch { $message = $_.Exception.Message }
    Assert-Test 'A missing writeToken gives a clear error' ($message -like "*writeToken*")
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
