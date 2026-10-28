# Read-only client for the Cloudflare API: REST and GraphQL Analytics.
#
# Phase 1 uses a read-only API token. This module sends only GET requests and
# GraphQL queries. The write functions are in CloudflareDnsWrite.psm1, a separate
# module with a second token.
# The token is in the file "credentials.json" (key "readToken"). Faginux writes this
# file. No function of this module prints the token.

Set-StrictMode -Version Latest

$script:ApiBase    = 'https://api.cloudflare.com/client/v4'
$script:GraphQlUrl = "$script:ApiBase/graphql"

function Get-CloudflareCredentialPath {
    # The environment variable is for the offline test. Normal use has the default path.
    if ($env:CLOUDFLARE_CLAUDE_CREDENTIAL_PATH) {
        return $env:CLOUDFLARE_CLAUDE_CREDENTIAL_PATH
    }
    $profileDirectory = [Environment]::GetFolderPath('UserProfile')
    Join-Path $profileDirectory '.config/cloudflare-claude/credentials.json'
}

function Get-CloudflareToken {
    [CmdletBinding()]
    [OutputType([securestring])]
    param()

    $path = Get-CloudflareCredentialPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "The credential file does not exist: $path"
    }
    $credential = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    $hasToken = $credential.PSObject.Properties['readToken'] -and
        -not [string]::IsNullOrWhiteSpace($credential.readToken)
    if (-not $hasToken) {
        throw "The credential file has no 'readToken' value: $path"
    }
    # The value comes from a file that Faginux writes. It is not a literal in the code.
    ConvertTo-SecureString -String $credential.readToken -AsPlainText -Force
}

function Get-CloudflareErrorText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    # ErrorDetails is null for an error that has no body from the server.
    $detail = if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message }
    if ($detail) {
        try {
            $parsed = $detail | ConvertFrom-Json
            if ($parsed.errors) {
                return (($parsed.errors | ForEach-Object { '{0} (code {1})' -f $_.message, $_.code }) -join '; ')
            }
        }
        catch {
            return $detail
        }
    }
    $ErrorRecord.Exception.Message
}

function Invoke-CloudflareApi {
    <#
    .SYNOPSIS
    Sends a GET request to the REST API of Cloudflare and returns the full answer.
    .DESCRIPTION
    The answer has the keys "result" and "result_info". Only GET is allowed. This is
    the read-only guard of phase 1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^/')]
        [string]$Path,

        [hashtable]$Query = @{},

        [ValidateSet('GET')]
        [string]$Method = 'GET'
    )

    $uri = "$script:ApiBase$Path"
    if ($Query.Count -gt 0) {
        $pairs = foreach ($key in $Query.Keys) {
            '{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString([string]$Query[$key])
        }
        $uri = '{0}?{1}' -f $uri, ($pairs -join '&')
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method $Method -Authentication Bearer -Token (Get-CloudflareToken) -ErrorAction Stop
    }
    catch {
        throw "The Cloudflare API request failed ($Path): $(Get-CloudflareErrorText -ErrorRecord $_)"
    }
    if (-not $response.success) {
        $text = ($response.errors | ForEach-Object { $_.message }) -join '; '
        throw "The Cloudflare API refused the request ($Path): $text"
    }
    $response
}

function Invoke-CloudflareGraphQl {
    <#
    .SYNOPSIS
    Runs a GraphQL query on the Analytics API of Cloudflare and returns the "data" node.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query
    )

    if ($Query -match '(?im)^\s*mutation\b') {
        throw 'A mutation is not allowed. This module is read-only.'
    }
    $body = @{ query = $Query } | ConvertTo-Json -Compress
    try {
        $response = Invoke-RestMethod -Uri $script:GraphQlUrl -Method Post -Authentication Bearer `
            -Token (Get-CloudflareToken) -ContentType 'application/json' -Body $body -ErrorAction Stop
    }
    catch {
        throw "The Cloudflare GraphQL request failed: $(Get-CloudflareErrorText -ErrorRecord $_)"
    }
    if ($response.PSObject.Properties['errors'] -and $response.errors) {
        throw ('Cloudflare GraphQL error: ' + (($response.errors | ForEach-Object { $_.message }) -join '; '))
    }
    $response.data
}

function Test-CloudflareToken {
    <#
    .SYNOPSIS
    Asks Cloudflare if the read token is active. It does not print the token.
    #>
    [CmdletBinding()]
    param()

    $response = Invoke-CloudflareApi -Path '/user/tokens/verify'
    [pscustomobject]@{
        Status    = $response.result.status
        ExpiresOn = if ($response.result.PSObject.Properties['expires_on']) { $response.result.expires_on } else { $null }
    }
}

function Get-CloudflareZone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $response = Invoke-CloudflareApi -Path '/zones' -Query @{ name = $Name }
    $zone = @($response.result) | Select-Object -First 1
    if (-not $zone) {
        throw "The zone does not exist, or the token has no access to it: $Name"
    }
    [pscustomobject]@{
        Id     = $zone.id
        Name   = $zone.name
        Status = $zone.status
        Plan   = if ($zone.PSObject.Properties['plan']) { $zone.plan.name } else { $null }
    }
}

function Get-CloudflareDnsRecord {
    <#
    .SYNOPSIS
    Lists the DNS records of a zone: name, type, content, proxy flag and TTL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ZoneName
    )

    $zone = Get-CloudflareZone -Name $ZoneName
    $page = 1
    do {
        $response = Invoke-CloudflareApi -Path "/zones/$($zone.Id)/dns_records" -Query @{ per_page = 100; page = $page }
        foreach ($record in @($response.result)) {
            [pscustomobject]@{
                Name    = $record.name
                Type    = $record.type
                Content = $record.content
                Proxied = $record.proxied
                Ttl     = $record.ttl
            }
        }
        $totalPages = if ($response.PSObject.Properties['result_info'] -and $response.result_info) { [int]$response.result_info.total_pages } else { 1 }
        $page++
    } while ($page -le $totalPages)
}

function Get-CloudflareTraffic {
    <#
    .SYNOPSIS
    Summarizes the HTTP traffic of a zone that Cloudflare proxies.
    .DESCRIPTION
    One day or less uses the hourly dataset. More than one day uses the daily dataset.
    The summary has the totals, the share of cached requests, the classes of status
    codes, the top countries and the peak period. A peak far above the median can be
    an attack. A name with DNS only (grey cloud) does not pass through Cloudflare, so
    this data does not include it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ZoneName,

        [ValidateRange(1, 30)]
        [int]$Days = 1
    )

    $zone = Get-CloudflareZone -Name $ZoneName
    $end = [datetime]::UtcNow
    $start = $end.AddDays(-$Days)

    if ($Days -le 1) {
        $dataset = 'httpRequests1hGroups'
        $dimension = 'datetime'
        $filter = 'datetime_geq: "{0:yyyy-MM-ddTHH:mm:ssZ}", datetime_lt: "{1:yyyy-MM-ddTHH:mm:ssZ}"' -f $start, $end
        $limit = 48
    }
    else {
        $dataset = 'httpRequests1dGroups'
        $dimension = 'date'
        $filter = 'date_geq: "{0:yyyy-MM-dd}", date_leq: "{1:yyyy-MM-dd}"' -f $start, $end
        $limit = 40
    }

    $query = @"
query {
  viewer {
    zones(filter: { zoneTag: "$($zone.Id)" }) {
      $dataset(limit: $limit, filter: { $filter }, orderBy: [${dimension}_ASC]) {
        dimensions { $dimension }
        sum {
          requests
          cachedRequests
          bytes
          cachedBytes
          threats
          responseStatusMap { edgeResponseStatus requests }
          countryMap { clientCountryName requests }
        }
      }
    }
  }
}
"@
    $data = Invoke-CloudflareGraphQl -Query $query
    $rows = @($data.viewer.zones[0].$dataset)
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ Zone = $zone.Name; Dataset = $dataset; Requests = 0; Note = 'No data in this period.' }
    }

    $requests = ($rows | ForEach-Object { $_.sum.requests } | Measure-Object -Sum).Sum
    $cached = ($rows | ForEach-Object { $_.sum.cachedRequests } | Measure-Object -Sum).Sum
    $bytes = ($rows | ForEach-Object { $_.sum.bytes } | Measure-Object -Sum).Sum
    $threats = ($rows | ForEach-Object { $_.sum.threats } | Measure-Object -Sum).Sum

    $statusClass = $rows.sum.responseStatusMap | Group-Object { '{0}xx' -f ([string]$_.edgeResponseStatus).Substring(0, 1) } |
        ForEach-Object { [pscustomobject]@{ Class = $_.Name; Requests = ($_.Group | Measure-Object -Property requests -Sum).Sum } } |
        Sort-Object Class
    $country = $rows.sum.countryMap | Group-Object clientCountryName |
        ForEach-Object { [pscustomobject]@{ Country = $_.Name; Requests = ($_.Group | Measure-Object -Property requests -Sum).Sum } } |
        Sort-Object Requests -Descending | Select-Object -First 5

    $sorted = @($rows | ForEach-Object { $_.sum.requests } | Sort-Object)
    $median = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
    $peak = $rows | Sort-Object { $_.sum.requests } -Descending | Select-Object -First 1

    [pscustomobject]@{
        Zone           = $zone.Name
        Dataset        = $dataset
        From           = $start.ToString('s') + 'Z'
        To             = $end.ToString('s') + 'Z'
        Requests       = $requests
        CachedPercent  = if ($requests) { [math]::Round(100 * $cached / $requests, 1) } else { 0 }
        BytesMegabyte  = [math]::Round($bytes / 1MB, 1)
        Threats        = $threats
        StatusClass    = $statusClass
        TopCountry     = $country
        PeakPeriod     = $peak.dimensions.$dimension
        PeakRequests   = $peak.sum.requests
        MedianRequests = $median
    }
}

function Get-CloudflareSecurityEvent {
    <#
    .SYNOPSIS
    Counts the security events of a zone by action, source and country.
    .DESCRIPTION
    The query does not return URIs or client IP addresses. It reads the raw dataset
    "firewallEventsAdaptive" and counts the rows in this module. The grouped dataset
    "firewallEventsAdaptiveGroups" is not available on the Free plan (the settings node
    gives maxDuration 0, checked on 2026-10-27). One query returns 10000 rows at most.
    The source "l7ddos" is the HTTP DDoS protection, if Cloudflare returns that value
    for the zone. On the Free plan the logs can be sampled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ZoneName,

        [ValidateRange(1, 720)]
        [int]$Hours = 24
    )

    $zone = Get-CloudflareZone -Name $ZoneName
    $end = [datetime]::UtcNow
    $start = $end.AddHours(-$Hours)
    $startText = $start.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $endText = $end.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $maxRows = 10000
    $query = @"
query {
  viewer {
    zones(filter: { zoneTag: "$($zone.Id)" }) {
      firewallEventsAdaptive(limit: $maxRows, filter: { datetime_geq: "$startText", datetime_leq: "$endText" }, orderBy: [datetime_DESC]) {
        action
        source
        clientCountryName
      }
    }
  }
}
"@
    $data = Invoke-CloudflareGraphQl -Query $query
    $rows = @($data.viewer.zones[0].firewallEventsAdaptive)
    if ($rows.Count -ge $maxRows) {
        Write-Warning "The result has the maximum of $maxRows rows. The counts are lower than the real number of events. Use a shorter period."
    }
    $rows | Group-Object action, source, clientCountryName | ForEach-Object {
        $first = $_.Group[0]
        [pscustomobject]@{
            Action  = $first.action
            Source  = $first.source
            Country = $first.clientCountryName
            Count   = $_.Count
        }
    } | Sort-Object Count -Descending
}

function Get-CloudflareGraphQlType {
    <#
    .SYNOPSIS
    Lists the fields of a GraphQL type. Use it to check a field name before a query.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_]+$')]
        [string]$Name
    )

    $data = Invoke-CloudflareGraphQl -Query "query { __type(name: `"$Name`") { name kind fields { name } inputFields { name } } }"
    if (-not $data.__type) {
        throw "The GraphQL type does not exist: $Name"
    }
    $names = @($data.__type.fields) + @($data.__type.inputFields) | Where-Object { $_ } | ForEach-Object { $_.name }
    [pscustomobject]@{ Type = $data.__type.name; Kind = $data.__type.kind; Field = @($names | Sort-Object) }
}

# Get-CloudflareCredentialPath and Get-CloudflareErrorText are exported for
# CloudflareDnsWrite.psm1. Get-CloudflareToken stays private.
Export-ModuleMember -Function Invoke-CloudflareApi, Invoke-CloudflareGraphQl, Test-CloudflareToken,
    Get-CloudflareZone, Get-CloudflareDnsRecord, Get-CloudflareTraffic, Get-CloudflareSecurityEvent,
    Get-CloudflareGraphQlType, Get-CloudflareCredentialPath, Get-CloudflareErrorText
