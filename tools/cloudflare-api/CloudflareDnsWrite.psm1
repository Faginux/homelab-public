# Write functions for the DNS records of one Cloudflare zone (phase 2).
#
# This module is separate from CloudflareApi.psm1, so the read module stays read-only.
# It uses a second token ("writeToken" in credentials.json) with only the permission
# Zone, DNS, Edit for one zone. Faginux writes the credential file.
#
# Rules:
# - Each function is a dry run unless -Apply is set. The dry run sends nothing. It shows
#   the record before and the request after, and it prints a plan id.
# - -Apply needs -PlanId with the plan id of the same change. A change that nobody showed
#   to Faginux has another plan id, so it cannot run.
# - The OK of Faginux in the chat is still the rule (rule number one of the homelab).
# - The private function sends POST, PATCH and DELETE on the path of a DNS record only.
# - The apex, the wildcard and the types other than A, AAAA and CNAME are blocked unless
#   -Force is set. Caddy (dynamic_dns) updates some records, and Caddy (DNS-01) writes the
#   TXT records for the certificate.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CloudflareApi.psm1') -ErrorAction Stop

$script:ApiBase  = 'https://api.cloudflare.com/client/v4'
$script:SafeType = @('A', 'AAAA', 'CNAME')

function Get-CloudflareWriteToken {
    [CmdletBinding()]
    [OutputType([securestring])]
    param()

    $path = Get-CloudflareCredentialPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "The credential file does not exist: $path"
    }
    $credential = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    $hasToken = $credential.PSObject.Properties['writeToken'] -and
        -not [string]::IsNullOrWhiteSpace($credential.writeToken)
    if (-not $hasToken) {
        throw "The credential file has no 'writeToken' value. Phase 2 needs the second token: $path"
    }
    # The value comes from a file that Faginux writes. It is not a literal in the code.
    ConvertTo-SecureString -String $credential.writeToken -AsPlainText -Force
}

function Invoke-CloudflareDnsWrite {
    # The only function of this module that sends a write request. The path pattern allows
    # the DNS records of a zone and nothing else.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('POST', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidatePattern('^/zones/[0-9a-f]{32}/dns_records(/[0-9a-f]{32})?$')]
        [string]$Path,

        [hashtable]$Body
    )

    $onRecord = $Path -match '/dns_records/[0-9a-f]{32}$'
    if (($Method -eq 'POST') -and $onRecord) {
        throw 'POST needs the path of the collection, not the path of one record.'
    }
    if (($Method -ne 'POST') -and -not $onRecord) {
        throw "$Method needs the path of one record."
    }

    $parameters = @{
        Uri            = "$script:ApiBase$Path"
        Method         = $Method
        Authentication = 'Bearer'
        Token          = (Get-CloudflareWriteToken)
        ErrorAction    = 'Stop'
    }
    if ($Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Compress
    }
    try {
        $response = Invoke-RestMethod @parameters
    }
    catch {
        throw "The Cloudflare write request failed ($Method $Path): $(Get-CloudflareErrorText -ErrorRecord $_)"
    }
    if (-not $response.success) {
        $text = ($response.errors | ForEach-Object { $_.message }) -join '; '
        throw "The Cloudflare API refused the write request ($Method $Path): $text"
    }
    $response.result
}

function Test-CloudflareWriteToken {
    <#
    .SYNOPSIS
    Asks Cloudflare if the write token is active. It writes nothing and it does not print the token.
    #>
    [CmdletBinding()]
    param()

    try {
        $response = Invoke-RestMethod -Uri "$script:ApiBase/user/tokens/verify" -Method Get `
            -Authentication Bearer -Token (Get-CloudflareWriteToken) -ErrorAction Stop
    }
    catch {
        throw "The Cloudflare token check failed: $(Get-CloudflareErrorText -ErrorRecord $_)"
    }
    [pscustomobject]@{ Status = $response.result.status }
}

function Resolve-CloudflareDnsName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ZoneName
    )

    $short = $Name.Trim().TrimEnd('.').ToLowerInvariant()
    $zone = $ZoneName.Trim().ToLowerInvariant()
    if ($short -eq '@') { return $zone }
    if ($short -eq $zone -or $short.EndsWith(".$zone")) { return $short }
    "$short.$zone"
}

function Assert-CloudflareDnsChange {
    [CmdletBinding()]
    param(
        [string]$Fqdn,
        [string]$ZoneName,
        [string]$Type,
        [string]$Content,
        [switch]$Force
    )

    if ($Force) { return }
    if ($Type -notin $script:SafeType) {
        throw "The type $Type is blocked. A, AAAA and CNAME are allowed. Use -Force, with the OK of Faginux."
    }
    if ($Fqdn -eq $ZoneName.ToLowerInvariant()) {
        throw 'The apex record is blocked: Caddy (dynamic_dns) updates it. Use -Force, with the OK of Faginux.'
    }
    if ($Fqdn.StartsWith('*')) {
        throw 'A wildcard record is blocked: it serves every name that has no record. Use -Force, with the OK of Faginux.'
    }
    if (-not $Content) { return }
    switch ($Type) {
        'A' {
            $address = $null
            $valid = [ipaddress]::TryParse($Content, [ref]$address) -and $address.AddressFamily -eq 'InterNetwork'
            if (-not $valid) { throw "The content is not an IPv4 address: $Content" }
        }
        'AAAA' {
            $address = $null
            $valid = [ipaddress]::TryParse($Content, [ref]$address) -and $address.AddressFamily -eq 'InterNetworkV6'
            if (-not $valid) { throw "The content is not an IPv6 address: $Content" }
        }
        'CNAME' {
            if ($Content -notmatch '^[A-Za-z0-9._-]+$') { throw "The content is not a host name: $Content" }
        }
    }
}

function New-CloudflareDnsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Update', 'Delete')]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$ZoneName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Type,

        [string]$Content,
        [Nullable[bool]]$Proxied,
        [Nullable[int]]$Ttl,
        [switch]$Force
    )

    $zone = Get-CloudflareZone -Name $ZoneName
    $fqdn = Resolve-CloudflareDnsName -Name $Name -ZoneName $zone.Name
    $recordType = $Type.ToUpperInvariant()
    Assert-CloudflareDnsChange -Fqdn $fqdn -ZoneName $zone.Name -Type $recordType -Content $Content -Force:$Force

    # The read token finds the record: the id is needed for an update and for a delete.
    $found = @((Invoke-CloudflareApi -Path "/zones/$($zone.Id)/dns_records" -Query @{ name = $fqdn; type = $recordType }).result)
    $collection = "/zones/$($zone.Id)/dns_records"

    switch ($Action) {
        'Create' {
            if ($found.Count -gt 0) { throw "The record exists already: $recordType $fqdn. Use Set-CloudflareDnsRecord." }
            $body = @{
                type    = $recordType
                name    = $fqdn
                content = $Content
                ttl     = if ($null -ne $Ttl) { [int]$Ttl } else { 1 }
                proxied = if ($null -ne $Proxied) { [bool]$Proxied } else { $false }
            }
            $method = 'POST'; $path = $collection; $before = $null; $recordId = $null
        }
        'Update' {
            if ($found.Count -ne 1) { throw "Update needs exactly one record. Found $($found.Count): $recordType $fqdn." }
            $body = @{}
            if ($Content) { $body.content = $Content }
            if ($null -ne $Proxied) { $body.proxied = [bool]$Proxied }
            if ($null -ne $Ttl) { $body.ttl = [int]$Ttl }
            if ($body.Count -eq 0) { throw 'Nothing to change. Set -Content, -Proxied or -Ttl.' }
            $recordId = $found[0].id
            $method = 'PATCH'; $path = "$collection/$recordId"
            $before = [pscustomobject]@{ Content = $found[0].content; Proxied = $found[0].proxied; Ttl = $found[0].ttl }
        }
        'Delete' {
            if ($found.Count -ne 1) { throw "Delete needs exactly one record. Found $($found.Count): $recordType $fqdn." }
            $body = $null
            $recordId = $found[0].id
            $method = 'DELETE'; $path = "$collection/$recordId"
            $before = [pscustomobject]@{ Content = $found[0].content; Proxied = $found[0].proxied; Ttl = $found[0].ttl }
        }
    }

    # The plan id is a hash of the request. The same change gives the same id.
    $canonical = if ($body) { (($body.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '&') } else { '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes("$method $path $canonical")
    $planId = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').ToLowerInvariant().Substring(0, 12)

    [pscustomobject]@{
        Action = $Action
        Zone   = $zone.Name
        Name   = $fqdn
        Type   = $recordType
        Before = $before
        Request = [pscustomobject]@{ Method = $method; Path = $path; Body = $body }
        PlanId = $planId
    }
}

function Invoke-CloudflareDnsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Plan,

        [switch]$Apply,
        [string]$PlanId
    )

    if (-not $Apply) {
        return [pscustomobject]@{
            Mode = 'DryRun'; Action = $Plan.Action; Zone = $Plan.Zone; Name = $Plan.Name; Type = $Plan.Type
            Before = $Plan.Before; Request = $Plan.Request; PlanId = $Plan.PlanId
            Next = "Nothing was sent. Show this plan to Faginux. After his OK, repeat the command with -Apply -PlanId $($Plan.PlanId)"
        }
    }
    if (-not $PlanId) {
        throw 'The option -Apply needs -PlanId, with the plan id of the dry run of this change.'
    }
    if ($PlanId -ne $Plan.PlanId) {
        throw "The plan id does not match this change (this change has $($Plan.PlanId)). Run the dry run again and show it to Faginux."
    }
    $request = $Plan.Request
    $result = if ($request.Body) {
        Invoke-CloudflareDnsWrite -Method $request.Method -Path $request.Path -Body $request.Body
    }
    else {
        Invoke-CloudflareDnsWrite -Method $request.Method -Path $request.Path
    }
    [pscustomobject]@{
        Mode = 'Applied'; Action = $Plan.Action; Zone = $Plan.Zone; Name = $Plan.Name; Type = $Plan.Type
        Before = $Plan.Before; PlanId = $Plan.PlanId
        After  = if ($Plan.Action -eq 'Delete') { $null } else { [pscustomobject]@{ Content = $result.content; Proxied = $result.proxied; Ttl = $result.ttl } }
    }
}

function New-CloudflareDnsRecord {
    <#
    .SYNOPSIS
    Creates a DNS record. Dry run unless -Apply and -PlanId are set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ZoneName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'CAA', 'SRV')] [string]$Type,
        [Parameter(Mandatory)] [string]$Content,
        [bool]$Proxied = $false,
        [ValidateRange(1, 86400)] [int]$Ttl = 1,
        [switch]$Apply,
        [string]$PlanId,
        [switch]$Force
    )

    $plan = New-CloudflareDnsPlan -Action Create -ZoneName $ZoneName -Name $Name -Type $Type -Content $Content -Proxied $Proxied -Ttl $Ttl -Force:$Force
    Invoke-CloudflareDnsPlan -Plan $plan -Apply:$Apply -PlanId $PlanId
}

function Set-CloudflareDnsRecord {
    <#
    .SYNOPSIS
    Changes the content, the proxy flag or the TTL of one DNS record. Dry run unless -Apply and -PlanId are set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ZoneName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'CAA', 'SRV')] [string]$Type,
        [string]$Content,
        [Nullable[bool]]$Proxied,
        [Nullable[int]]$Ttl,
        [switch]$Apply,
        [string]$PlanId,
        [switch]$Force
    )

    $plan = New-CloudflareDnsPlan -Action Update -ZoneName $ZoneName -Name $Name -Type $Type -Content $Content -Proxied $Proxied -Ttl $Ttl -Force:$Force
    Invoke-CloudflareDnsPlan -Plan $plan -Apply:$Apply -PlanId $PlanId
}

function Remove-CloudflareDnsRecord {
    <#
    .SYNOPSIS
    Deletes one DNS record. Dry run unless -Apply and -PlanId are set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ZoneName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'CAA', 'SRV')] [string]$Type,
        [switch]$Apply,
        [string]$PlanId,
        [switch]$Force
    )

    $plan = New-CloudflareDnsPlan -Action Delete -ZoneName $ZoneName -Name $Name -Type $Type -Force:$Force
    Invoke-CloudflareDnsPlan -Plan $plan -Apply:$Apply -PlanId $PlanId
}

Export-ModuleMember -Function Test-CloudflareWriteToken, New-CloudflareDnsRecord, Set-CloudflareDnsRecord, Remove-CloudflareDnsRecord
