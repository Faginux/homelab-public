# ArrApi.psm1 - v0.3 (2026-11-27). The common part of the arr-api tool.
#
# Safety rules of this module:
# - It sends only GET, POST and PUT requests. It has no DELETE request.
# - A caller gives a resource NAME or a write OPERATION from a table below, not a free path.
#   Some paths of the apps (for example config/host or downloadclient) return secrets.
#   Some paths (for example command or release) start a search or a download.
# - A write body can have only the keys of its operation. The module does this check before
#   it reads a key.
# - The API keys stay inside the module. No exported function returns a key.
# - For a resource that can hold secrets, only the listed properties go out.
# - The answer to a write does not go out. Only the id of a new custom format goes out.
#
# Made with Claude Code (Anthropic).

Set-StrictMode -Version 3.0

# The versions for which a person compared the endpoints and the bodies with the official
# source code (git tags v4.0.20.3014 and v7.0.3.10918). After an update of an app, compare
# the source again before you change these values.
$script:VerifiedVersion = @{
    sonarr = '4.0.20.3014'
    radarr = '7.0.3.10918'
}

# Keep = $null: the full object goes out. Use it only for a resource with no secret.
# Query: the resource needs one value. Get-ArrResourceName does not list such a resource.
$script:ResourceByApp = @{
    sonarr = @{
        ApiBase  = '/api/v3'
        Resource = [ordered]@{
            status          = @{ Path = 'system/status'; List = $false; Keep = @('appName', 'version') }
            customformat    = @{ Path = 'customformat'; List = $true; Keep = $null }
            qualityprofile  = @{ Path = 'qualityprofile'; List = $true; Keep = $null }
            mediamanagement = @{ Path = 'config/mediamanagement'; List = $false; Keep = $null }
            delayprofile    = @{ Path = 'delayprofile'; List = $true; Keep = $null }
            releaseprofile  = @{ Path = 'releaseprofile'; List = $true; Keep = $null }
            rootfolder      = @{ Path = 'rootfolder'; List = $true; Keep = @('id', 'path', 'accessible', 'freeSpace') }
            series          = @{ Path = 'series'; List = $true; Keep = @('id', 'title', 'year', 'monitored', 'qualityProfileId', 'seriesType', 'path', 'seasons') }
            episode         = @{ Path = 'episode'; List = $true; Query = 'seriesId'; Keep = @('id', 'seriesId', 'seasonNumber', 'episodeNumber', 'title', 'monitored', 'hasFile') }
            parse           = @{ Path = 'parse'; List = $false; Query = 'title'; Keep = @('title', 'series', 'customFormats', 'customFormatScore') }
        }
    }
    radarr = @{
        ApiBase  = '/api/v3'
        Resource = [ordered]@{
            status          = @{ Path = 'system/status'; List = $false; Keep = @('appName', 'version') }
            customformat    = @{ Path = 'customformat'; List = $true; Keep = $null }
            qualityprofile  = @{ Path = 'qualityprofile'; List = $true; Keep = $null }
            mediamanagement = @{ Path = 'config/mediamanagement'; List = $false; Keep = $null }
            delayprofile    = @{ Path = 'delayprofile'; List = $true; Keep = $null }
            rootfolder      = @{ Path = 'rootfolder'; List = $true; Keep = @('id', 'path', 'accessible', 'freeSpace') }
            movie           = @{ Path = 'movie'; List = $true; Keep = @('id', 'title', 'year', 'monitored', 'qualityProfileId', 'path', 'hasFile') }
            parse           = @{ Path = 'parse'; List = $false; Query = 'title'; Keep = @('title', 'movie', 'customFormats', 'customFormatScore') }
        }
    }
    prowlarr = @{
        ApiBase  = '/api/v1'
        Resource = [ordered]@{
            status       = @{ Path = 'system/status'; List = $false; Keep = @('appName', 'version') }
            # Never add "fields" to these two lists: it holds keys, passkeys and cookies.
            indexer      = @{ Path = 'indexer'; List = $true; Keep = @('id', 'name', 'enable', 'protocol', 'privacy', 'priority', 'appProfileId', 'implementation', 'tags') }
            applications = @{ Path = 'applications'; List = $true; Keep = @('id', 'name', 'syncLevel', 'implementation', 'tags') }
            appprofile   = @{ Path = 'appprofile'; List = $true; Keep = $null }
        }
    }
}

# A property with one of these names holds objects. Only the listed properties of them go out.
$script:NestedKeep = @{
    seasons       = @('seasonNumber', 'monitored')
    series        = @('id', 'title')
    movie         = @('id', 'title')
    customFormats = @('id', 'name')
}

# --- Shapes of the write bodies -------------------------------------------------
# A text value is a scalar type. A table with the one key '[]' is a list of one shape, with
# one entry or more. Each other table is an object that must have exactly its keys.
# The type 'array' or 'object' accepts the content as it is. Use it only for a part of a
# quality profile that the tool sends back unchanged.
$fieldShape = [ordered]@{ name = 'text'; value = 'scalar' }
$specificationShape = [ordered]@{
    name = 'text'; implementation = 'text'; negate = 'bool'; required = 'bool'
    fields = @{ '[]' = $fieldShape }
}
$formatCreateShape = [ordered]@{
    name = 'text'; includeCustomFormatWhenRenaming = 'bool'
    specifications = @{ '[]' = $specificationShape }
}
$formatUpdateShape = [ordered]@{
    id = 'id'; name = 'text'; includeCustomFormatWhenRenaming = 'bool'
    specifications = @{ '[]' = $specificationShape }
}
$formatItemShape = [ordered]@{ format = 'id'; name = 'text'; score = 'int' }
$sonarrProfileShape = [ordered]@{
    id = 'id'; name = 'text'; upgradeAllowed = 'bool'; cutoff = 'int'; items = 'array'
    minFormatScore = 'int'; cutoffFormatScore = 'int'; minUpgradeFormatScore = 'int'
    formatItems = @{ '[]' = $formatItemShape }
}
$radarrProfileShape = [ordered]@{
    id = 'id'; name = 'text'; upgradeAllowed = 'bool'; cutoff = 'int'; items = 'array'
    minFormatScore = 'int'; cutoffFormatScore = 'int'; minUpgradeFormatScore = 'int'
    formatItems = @{ '[]' = $formatItemShape }; language = 'object'
}

# The monitor operations send only ids and flags. These keys must never be in a body:
# rootFolderPath and moveFiles (they move files), deleteFiles, and monitoringOptions
# (POST seasonpass then changes each episode of the series).
$seriesMonitorShape = [ordered]@{ seriesIds = @{ '[]' = 'id' }; monitored = 'bool' }
$seasonMonitorShape = [ordered]@{
    series = @{ '[]' = [ordered]@{
            id      = 'id'
            seasons = @{ '[]' = [ordered]@{ seasonNumber = 'int'; monitored = 'bool' } }
        }
    }
}
$episodeMonitorShape = [ordered]@{ episodeIds = @{ '[]' = 'id' }; monitored = 'bool' }
$movieMonitorShape = [ordered]@{ movieIds = @{ '[]' = 'id' }; monitored = 'bool' }

# The only write requests of the tool. Prowlarr has no write operation.
$script:WriteByApp = @{
    sonarr = [ordered]@{
        'customformat.create'   = @{ Method = 'Post'; Path = 'customformat'; Shape = $formatCreateShape }
        'customformat.update'   = @{ Method = 'Put'; Path = 'customformat/{id}'; Shape = $formatUpdateShape }
        'qualityprofile.update' = @{ Method = 'Put'; Path = 'qualityprofile/{id}'; Shape = $sonarrProfileShape }
        'series.monitor'        = @{ Method = 'Put'; Path = 'series/editor'; Shape = $seriesMonitorShape }
        'season.monitor'        = @{ Method = 'Post'; Path = 'seasonpass'; Shape = $seasonMonitorShape }
        'episode.monitor'       = @{ Method = 'Put'; Path = 'episode/monitor'; Shape = $episodeMonitorShape }
    }
    radarr = [ordered]@{
        'customformat.create'   = @{ Method = 'Post'; Path = 'customformat'; Shape = $formatCreateShape }
        'customformat.update'   = @{ Method = 'Put'; Path = 'customformat/{id}'; Shape = $formatUpdateShape }
        'qualityprofile.update' = @{ Method = 'Put'; Path = 'qualityprofile/{id}'; Shape = $radarrProfileShape }
        'movie.monitor'         = @{ Method = 'Put'; Path = 'movie/editor'; Shape = $movieMonitorShape }
    }
}

# The keys that the module read in this process. Only for the leak check.
$script:LoadedKey = [System.Collections.Generic.HashSet[string]]::new()

function Get-ArrResourceName {
    # The resources of a snapshot. A resource that needs a query value is not in this list.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('sonarr', 'radarr', 'prowlarr')][string]$App)

    $resources = $script:ResourceByApp[$App].Resource
    @($resources.Keys | Where-Object { -not $resources[$_].ContainsKey('Query') })
}

function Get-ArrVerifiedVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('sonarr', 'radarr')][string]$App)

    $script:VerifiedVersion[$App]
}

function Get-ArrWriteOperation {
    # The list of the write operations, for a test and for a review. It sends no request.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('sonarr', 'radarr')][string]$App)

    foreach ($name in $script:WriteByApp[$App].Keys) {
        $write = $script:WriteByApp[$App][$name]
        [pscustomobject]@{ Name = $name; Method = $write.Method; Path = $write.Path }
    }
}

function Get-ArrConnection {
    # Not exported: the result holds the API key.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$App)

    $folder = (Get-Culture).TextInfo.ToTitleCase($App)
    $configPath = Join-Path $env:ProgramData (Join-Path $folder 'config.xml')
    try {
        [xml]$document = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
        $port = $document.SelectSingleNode('/Config/Port').InnerText.Trim()
        $urlBaseNode = $document.SelectSingleNode('/Config/UrlBase')
        $urlBase = if ($null -eq $urlBaseNode) { '' } else { $urlBaseNode.InnerText.Trim().Trim('/') }
        $apiKey = $document.SelectSingleNode('/Config/ApiKey').InnerText.Trim()
    } catch {
        # A fixed text: a parse error of PowerShell can show the content of the file.
        throw "Cannot read the necessary values from $configPath."
    }
    if ($port -notmatch '^\d+$') { throw "No valid Port in $configPath." }
    if ($apiKey.Length -lt 20) { throw "No valid ApiKey in $configPath." }
    if ($urlBase) { $urlBase = '/' + $urlBase }
    [void]$script:LoadedKey.Add($apiKey)

    @{ BaseUrl = 'http://127.0.0.1:{0}{1}' -f $port, $urlBase; ApiKey = $apiKey }
}

function Select-ArrSafeProperty {
    # Keeps only the listed properties of each object. $null keeps the full object.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$InputItem,
        [AllowNull()][string[]]$Keep
    )
    foreach ($item in $InputItem) {
        if ($null -eq $item) { continue }
        if ($null -eq $Keep) { $item; continue }
        $safe = [ordered]@{}
        foreach ($name in $Keep) {
            $property = $item.PSObject.Properties[$name]
            if ($null -eq $property) { continue }
            if ($script:NestedKeep.ContainsKey($name) -and $null -ne $property.Value) {
                if ($property.Value -is [array]) {
                    $safe[$name] = @($property.Value | Select-Object -Property $script:NestedKeep[$name])
                } else {
                    $safe[$name] = $property.Value | Select-Object -Property $script:NestedKeep[$name]
                }
            } else {
                $safe[$name] = $property.Value
            }
        }
        [pscustomobject]$safe
    }
}

function Assert-ArrNoSecret {
    # Stops if a text has a loaded API key or a secret in a URL or a JSON property.
    # The error gives no part of the text.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($key in $script:LoadedKey) {
        if ($Text.Contains($key)) { throw "Leak check: an API key is in the data of $Label. Nothing was written for it." }
    }
    if ($Text -match '(?i)[?&](apikey|api_key|passkey|torrent_pass|rsskey|authkey|token)=[^&"\s]{6,}') {
        throw "Leak check: a URL with a secret parameter is in the data of $Label. Nothing was written for it."
    }
    if ($Text -match '(?i)"(apikey|api_key|password|passkey|cookie|token|secret)"\s*:\s*"[^"*]{4,}"') {
        throw "Leak check: a secret property is in the data of $Label. Nothing was written for it."
    }
}

function Get-ArrStatusCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($responseProperty -and $responseProperty.Value) { return [int]$responseProperty.Value.StatusCode }
    'no HTTP status'
}

function Get-ArrServerMessage {
    # The validation texts of the app, or an empty text. Only "errorMessage" values go out.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        if ($null -eq $ErrorRecord.ErrorDetails) { return '' }
        $entries = @($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop)
        $texts = foreach ($entry in $entries) {
            $property = $entry.PSObject.Properties['errorMessage']
            if ($property) { [string]$property.Value }
        }
        $message = @($texts) -join ' / '
        if (-not $message) { return '' }
        Assert-ArrNoSecret -Text $message -Label 'error message'
        if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
        " Message of the app: $message"
    } catch {
        ''
    }
}

function Get-ArrResourceJson {
    # Reads one resource and returns it as safe JSON text.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('sonarr', 'radarr', 'prowlarr')][string]$App,
        [Parameter(Mandatory)][string]$Name,
        [string]$QueryValue
    )
    $appSetting = $script:ResourceByApp[$App]
    # Check the name and the query value BEFORE the module reads a key.
    if (-not $appSetting.Resource.Contains($Name)) { throw "The resource '$Name' is not in the list of $App." }
    $resource = $appSetting.Resource[$Name]
    $queryName = if ($resource.ContainsKey('Query')) { $resource['Query'] } else { $null }
    if ($queryName) {
        if ([string]::IsNullOrWhiteSpace($QueryValue)) { throw "The resource '$Name' of $App needs a value for '$queryName'." }
        if ($queryName -ne 'title' -and $QueryValue -notmatch '\A\d{1,9}\z') { throw "The value of '$queryName' must be a number." }
    } elseif ($PSBoundParameters.ContainsKey('QueryValue')) {
        throw "The resource '$Name' of $App accepts no query value."
    }

    $connection = Get-ArrConnection -App $App
    $uri = '{0}{1}/{2}' -f $connection.BaseUrl, $appSetting.ApiBase, $resource.Path
    if ($queryName) { $uri += '?{0}={1}' -f $queryName, [uri]::EscapeDataString($QueryValue) }
    try {
        # A redirect stops the request, thus the key does not go to a second address.
        $data = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'X-Api-Key' = $connection.ApiKey } `
            -MaximumRedirection 0 -TimeoutSec 120 -ErrorAction Stop
    } catch {
        throw "GET $($resource.Path) of $App failed ($(Get-ArrStatusCode $_))."
    }

    $items = @(Select-ArrSafeProperty -InputItem @($data) -Keep $resource.Keep)
    $json = if ($resource.List) {
        ConvertTo-Json -InputObject $items -Depth 32
    } else {
        ConvertTo-Json -InputObject $items[0] -Depth 32
    }
    Assert-ArrNoSecret -Text $json -Label "$App/$Name"
    [pscustomobject]@{ App = $App; Name = $Name; Count = $items.Count; Json = $json }
}

function Assert-ArrJsonShape {
    # Not exported. Compares one JSON element with a shape. The names are case sensitive:
    # PowerShell ignores the case, and the apps also ignore it.
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][object]$Shape,
        [Parameter(Mandatory)][string]$Location
    )
    $kind = $Element.ValueKind.ToString()
    if ($Shape -is [System.Collections.IDictionary]) {
        if ($Shape.Contains('[]')) {
            if ($kind -ne 'Array') { throw "Body check: $Location must be a list." }
            if ($Element.GetArrayLength() -eq 0) { throw "Body check: $Location is an empty list." }
            $index = 0
            foreach ($entry in $Element.EnumerateArray()) {
                Assert-ArrJsonShape -Element $entry -Shape $Shape['[]'] -Location "$Location[$index]"
                $index++
            }
            return
        }
        if ($kind -ne 'Object') { throw "Body check: $Location must be an object." }
        $allowed = [string[]]@($Shape.Keys)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if ($allowed -cnotcontains $property.Name) { throw "Body check: the key '$($property.Name)' is not permitted at $Location." }
            if (-not $seen.Add($property.Name)) { throw "Body check: the key '$($property.Name)' occurs two times at $Location." }
            Assert-ArrJsonShape -Element $property.Value -Shape $Shape[$property.Name] -Location "$Location.$($property.Name)"
        }
        foreach ($key in $allowed) {
            if (-not $seen.Contains($key)) { throw "Body check: the key '$key' is missing at $Location." }
        }
        return
    }
    $number = 0
    $isInteger = $kind -eq 'Number' -and $Element.TryGetInt32([ref]$number)
    $valid = switch ($Shape) {
        'int' { $isInteger }
        'id' { $isInteger -and $number -gt 0 }
        'bool' { $kind -in 'True', 'False' }
        'text' { $kind -eq 'String' }
        'scalar' { $kind -in 'String', 'Number', 'True', 'False' }
        'array' { $kind -eq 'Array' }
        'object' { $kind -eq 'Object' }
        default { $false }
    }
    if (-not $valid) { throw "Body check: $Location does not have the type '$Shape'." }
}

function Invoke-ArrWrite {
    # Sends one write operation of the table. It is the only function that changes data.
    # Use it only through Invoke-ArrPlan.ps1, which does the checks and the rollback.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('sonarr', 'radarr')][string]$App,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$BodyJson,
        [int]$Id
    )
    $writes = $script:WriteByApp[$App]
    # Do each check BEFORE the module reads a key.
    if ([string[]]@($writes.Keys) -cnotcontains $Operation) { throw "The operation '$Operation' is not in the write list of $App." }
    $write = $writes[$Operation]
    $needsId = $write.Path.Contains('{id}')
    if ($needsId -and $Id -lt 1) { throw "The operation '$Operation' needs -Id." }
    if (-not $needsId -and $PSBoundParameters.ContainsKey('Id')) { throw "The operation '$Operation' accepts no -Id." }

    try { $document = [System.Text.Json.JsonDocument]::Parse($BodyJson) }
    catch { throw 'Body check: the body is not valid JSON.' }
    try {
        Assert-ArrJsonShape -Element $document.RootElement -Shape $write.Shape -Location 'body'
        if ($needsId -and $document.RootElement.GetProperty('id').GetInt32() -ne $Id) { throw 'Body check: body.id is not equal to -Id.' }
    } finally {
        $document.Dispose()
    }

    $connection = Get-ArrConnection -App $App
    Assert-ArrNoSecret -Text $BodyJson -Label "$App/$Operation body"
    $relativePath = $write.Path.Replace('{id}', [string]$Id)
    $uri = '{0}{1}/{2}' -f $connection.BaseUrl, $script:ResourceByApp[$App].ApiBase, $relativePath
    $headers = @{ 'X-Api-Key' = $connection.ApiKey }
    $contentType = 'application/json; charset=utf-8'
    try {
        # Two literal commands and no splat, thus a static test can read each method.
        $response = switch -CaseSensitive ($write.Method) {
            'Post' {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $BodyJson -ContentType $contentType `
                    -MaximumRedirection 0 -TimeoutSec 120 -ErrorAction Stop
            }
            'Put' {
                Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $BodyJson -ContentType $contentType `
                    -MaximumRedirection 0 -TimeoutSec 120 -ErrorAction Stop
            }
            default { throw 'The write table has a method that is not permitted.' }
        }
    } catch {
        throw "$($write.Method.ToUpperInvariant()) $relativePath of $App failed ($(Get-ArrStatusCode $_)).$(Get-ArrServerMessage $_)"
    }

    $newId = $null
    if ($Operation -ceq 'customformat.create' -and $null -ne $response) {
        $property = $response.PSObject.Properties['id']
        if ($property) { $newId = [int]$property.Value }
    }
    [pscustomobject]@{ App = $App; Operation = $Operation; NewId = $newId }
}

Export-ModuleMember -Function Get-ArrResourceName, Get-ArrResourceJson, Select-ArrSafeProperty, Assert-ArrNoSecret,
    Invoke-ArrWrite, Get-ArrWriteOperation, Get-ArrVerifiedVersion
