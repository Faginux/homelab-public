<#
  Export-ArrCfState.ps1  -  v1.0  (2026-11-21).
  Reads the custom formats (CF) and the quality profiles of Radarr and Sonarr
  on ARCADE and writes a baseline for PLAN-RECYCLARR.md (step R2).
  For each app it writes these files:
    - <app>-customformat.json    the raw response of GET /api/v3/customformat
    - <app>-qualityprofile.json  the raw response of GET /api/v3/qualityprofile
    - <app>-scores.csv           the score matrix: profile,cf_name,cf_id,score
  It also writes manifest.json: app versions, counts and the SHA-256 of each file.

  The script only reads from the apps (GET). It writes only into a new folder
  below -OutputRoot, outside the repo. It does not overwrite a folder.

  Secrets: the API key goes from config.xml into a variable. The script never
  prints the key and never puts it in a URL (it is in the X-Api-Key header).
  At the end it searches the new files for each key and gives only a count.
  Expect 0.

  Runs on Windows PowerShell 5.1 and PowerShell 7.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    # The parent folder of the baseline. The script makes a new subfolder for each run.
    [string]$OutputRoot = 'S:\docker-appdata\recyclarr\baseline',

    # The apps to export.
    [ValidateSet('radarr', 'sonarr')]
    [string[]]$App = @('radarr', 'sonarr')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ConfigPathByApp = @{
    radarr = 'C:\ProgramData\Radarr\config.xml'
    sonarr = 'C:\ProgramData\Sonarr\config.xml'
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-XmlNodeText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][xml]$Document,
        [Parameter(Mandatory)][string]$XPath
    )
    # SelectSingleNode returns $null for a missing element. Strict mode does not stop on it.
    $node = $Document.SelectSingleNode($XPath)
    if ($null -eq $node) { return '' }
    return $node.InnerText.Trim()
}

function Get-ArrConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    # Read only the three keys that the script needs. Never print the document.
    [xml]$document = Get-Content -LiteralPath $ConfigPath -Raw
    $port = Get-XmlNodeText -Document $document -XPath '/Config/Port'
    $urlBase = (Get-XmlNodeText -Document $document -XPath '/Config/UrlBase').Trim('/')
    $apiKey = Get-XmlNodeText -Document $document -XPath '/Config/ApiKey'

    if ($port -notmatch '^\d+$') { throw "No valid Port in $ConfigPath." }
    if ($apiKey.Length -lt 20) { throw "No valid ApiKey in $ConfigPath." }
    if ($urlBase) { $urlBase = '/' + $urlBase }

    # 127.0.0.1 is in the Allowed Hosts list of the two apps.
    [pscustomobject]@{
        BaseUrl = 'http://127.0.0.1:{0}{1}' -f $port, $urlBase
        ApiKey  = $apiKey
    }
}

function Invoke-ArrGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][string]$Path
    )
    $uri = '{0}{1}' -f $Connection.BaseUrl, $Path
    $response = Invoke-WebRequest -Uri $uri -Headers @{ 'X-Api-Key' = $Connection.ApiKey } `
        -UseBasicParsing -TimeoutSec 60
    # Keep the raw bytes: the JSON file is the exact response, not a new serialization.
    [byte[]]$bytes = $response.RawContentStream.ToArray()
    [pscustomobject]@{
        Bytes = $bytes
        Data  = ($Utf8NoBom.GetString($bytes) | ConvertFrom-Json)
    }
}

function Get-ScoreMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CustomFormat,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$QualityProfile
    )
    $nameById = @{}
    foreach ($format in $CustomFormat) { $nameById[[int]$format.id] = [string]$format.name }

    $orphanCount = 0
    $rows = foreach ($qualityProfile in $QualityProfile) {
        foreach ($item in @($qualityProfile.formatItems)) {
            $id = [int]$item.format
            if ($nameById.ContainsKey($id)) {
                $cfName = $nameById[$id]
            } else {
                # A profile item with no CF of the same ID. Keep the row and count it.
                $cfName = [string]$item.name
                $orphanCount++
            }
            [pscustomobject]@{
                profile = [string]$qualityProfile.name
                cf_name = $cfName
                cf_id   = $id
                score   = [int]$item.score
            }
        }
    }
    [pscustomobject]@{
        Rows        = @($rows | Sort-Object -Property profile, cf_name)
        OrphanCount = $orphanCount
    }
}

# 1. Make the output folder. Stop if it is there already.
$outputDir = Join-Path $OutputRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss')
if (Test-Path -LiteralPath $outputDir) { throw "The folder $outputDir exists. The script does not overwrite it." }
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$apiKeyByApp = @{}
$appSummary = [ordered]@{}

# 2. Export each app.
foreach ($appName in $App) {
    $connection = Get-ArrConnection -ConfigPath $ConfigPathByApp[$appName]
    $apiKeyByApp[$appName] = $connection.ApiKey

    $status = (Invoke-ArrGet -Connection $connection -Path '/api/v3/system/status').Data
    $formatResponse = Invoke-ArrGet -Connection $connection -Path '/api/v3/customformat'
    $profileResponse = Invoke-ArrGet -Connection $connection -Path '/api/v3/qualityprofile'

    # Windows PowerShell 5.1 gives a JSON array as one object, PowerShell 7 gives its items.
    # PowerShell 7 gives $null for an empty array. The filter makes the two the same.
    $customFormats = @($formatResponse.Data | Where-Object { $null -ne $_ })
    $qualityProfiles = @($profileResponse.Data | Where-Object { $null -ne $_ })
    $matrix = Get-ScoreMatrix -CustomFormat $customFormats -QualityProfile $qualityProfiles

    [IO.File]::WriteAllBytes((Join-Path $outputDir "$appName-customformat.json"), $formatResponse.Bytes)
    [IO.File]::WriteAllBytes((Join-Path $outputDir "$appName-qualityprofile.json"), $profileResponse.Bytes)
    if ($matrix.Rows.Count -gt 0) {
        $csvLines = [string[]]($matrix.Rows | ConvertTo-Csv -NoTypeInformation)
    } else {
        $csvLines = [string[]]@('"profile","cf_name","cf_id","score"')
    }
    [IO.File]::WriteAllLines((Join-Path $outputDir "$appName-scores.csv"), $csvLines, $Utf8NoBom)

    $appSummary[$appName] = [ordered]@{
        version          = [string]$status.version
        base_url         = $connection.BaseUrl
        custom_formats   = $customFormats.Count
        quality_profiles = $qualityProfiles.Count
        score_rows       = $matrix.Rows.Count
        orphan_items     = $matrix.OrphanCount
    }
}

# 3. Write the manifest with the SHA-256 of each data file.
$fileHashes = [ordered]@{}
Get-ChildItem -LiteralPath $outputDir -File | Sort-Object -Property Name | ForEach-Object {
    $fileHashes[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest = [ordered]@{
    script  = 'Export-ArrCfState.ps1 v1.0'
    created = (Get-Date).ToString('o')
    apps    = $appSummary
    files   = $fileHashes
}
[IO.File]::WriteAllText((Join-Path $outputDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), $Utf8NoBom)

# 4. Search the new files for each API key. Give a count only.
$newFiles = @(Get-ChildItem -LiteralPath $outputDir -File)
foreach ($appName in $App) {
    $key = $apiKeyByApp[$appName]
    $hits = @($newFiles | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains($key) }).Count
    $summary = $appSummary[$appName]
    [pscustomobject]@{
        App             = $appName
        Version         = $summary.version
        CustomFormats   = $summary.custom_formats
        QualityProfiles = $summary.quality_profiles
        ScoreRows       = $summary.score_rows
        OrphanItems     = $summary.orphan_items
        ApiKeyHits      = $hits
        OutputDir       = $outputDir
    }
}
$apiKeyByApp.Clear()
