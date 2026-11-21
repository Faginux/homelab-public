<#
  New-RecyclarrSecretsFile.ps1  -  v1.1  (2026-11-21).
  v1.1: the summary line shows also when the tests pass (v1.0 lost it: the
  table of the first object type hid the second object type).
  Writes secrets.yml for the Recyclarr stack (PLAN-RECYCLARR.md, step R3, D6
  and D12). The file has four keys: radarr_url, radarr_api_key, sonarr_url and
  sonarr_api_key.

  The script reads the port, the URL base and the API key of each app from its
  config.xml. The URL uses -HostAddress, the LAN address of this host, because
  Allowed Hosts rejects host.docker.internal (D12). The address is a parameter,
  thus the repo does not keep it.

  Before it writes the file, the script does two tests for each app on the new URL:
    - GET /ping with no key. Expect 200: Allowed Hosts accepts the address.
    - GET /api/v3/system/status with the key. Expect 200: the key is correct.
  If a test fails, the script stops and does not write the file.

  Secrets: the script never prints a key and never prints the file. It prints
  only the URL, the two HTTP codes for each app, the key names and the file size.

  It does not overwrite secrets.yml. Use -Force to write the file again (for
  example after a key rotation).

  Runs on Windows PowerShell 5.1 and PowerShell 7.

  Made with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    # The LAN IPv4 address of ARCADE. It must be in Allowed Hosts of the two apps.
    [Parameter(Mandatory)]
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string]$HostAddress,

    # The file that Recyclarr reads as /config/secrets.yml.
    [string]$OutputPath = 'S:\docker-appdata\recyclarr\config\secrets.yml',

    # Write the file also if it exists.
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ConfigPathByApp = [ordered]@{
    radarr = 'C:\ProgramData\Radarr\config.xml'
    sonarr = 'C:\ProgramData\Sonarr\config.xml'
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-XmlNodeText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][xml]$Document,
        [Parameter(Mandatory)][string]$XPath
    )
    # SelectSingleNode returns $null for a missing element. Strict mode does not stop on it.
    $node = $Document.SelectSingleNode($XPath)
    if ($null -eq $node) { return '' }
    return $node.InnerText.Trim()
}

function Get-ArrSetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    # Read only the three keys that the script needs. Never print the document.
    [xml]$document = Get-Content -LiteralPath $ConfigPath -Raw
    $port = Get-XmlNodeText -Document $document -XPath '/Config/Port'
    $urlBase = (Get-XmlNodeText -Document $document -XPath '/Config/UrlBase').Trim('/')
    $apiKey = Get-XmlNodeText -Document $document -XPath '/Config/ApiKey'

    if ($port -notmatch '^\d+$') { throw "No valid Port in $ConfigPath." }
    # Letters and digits only: then the value is safe in single quotes in YAML.
    if ($apiKey -notmatch '^[A-Za-z0-9]{20,}$') { throw "No valid ApiKey in $ConfigPath." }
    if ($urlBase) { $urlBase = '/' + $urlBase }

    [pscustomobject]@{
        Port    = $port
        UrlBase = $urlBase
        ApiKey  = $apiKey
    }
}

function Get-HttpStatusCode {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{}
    )
    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 30
        return [int]$response.StatusCode
    } catch {
        # For an HTTP error, PowerShell 5.1 and 7 both keep the response in the exception.
        # Do not print the exception: give the code only. 0 = no HTTP response.
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            return [int]$responseProperty.Value.StatusCode
        }
        return 0
    }
}

# 1. Check the target before the script reads a key.
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    throw "The folder $outputDir does not exist. Make it first (PLAN-RECYCLARR.md, R3 step 3)."
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "The file $OutputPath exists. The script does not overwrite it. Use -Force to write it again."
}

# 2. Read each app and test the new URL. The lines stay in memory until all tests pass.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Recyclarr secrets (PLAN-RECYCLARR.md, D6). New-RecyclarrSecretsFile.ps1 writes this file.')
$lines.Add('# Do not put this file in git.')
$keyNames = New-Object System.Collections.Generic.List[string]
$results = foreach ($appName in $ConfigPathByApp.Keys) {
    $setting = Get-ArrSetting -ConfigPath $ConfigPathByApp[$appName]
    $url = 'http://{0}:{1}{2}' -f $HostAddress, $setting.Port, $setting.UrlBase

    $pingCode = Get-HttpStatusCode -Uri "$url/ping"
    $statusCode = Get-HttpStatusCode -Uri "$url/api/v3/system/status" -Headers @{ 'X-Api-Key' = $setting.ApiKey }

    # Single quotes in YAML: the value stays a string, also if it has only digits.
    $lines.Add(("{0}_url: '{1}'" -f $appName, $url))
    $lines.Add(("{0}_api_key: '{1}'" -f $appName, $setting.ApiKey))
    $keyNames.Add("${appName}_url")
    $keyNames.Add("${appName}_api_key")

    [pscustomobject]@{
        App        = $appName
        Url        = $url
        PingCode   = $pingCode
        StatusCode = $statusCode
    }
}

$failed = @($results | Where-Object { $_.PingCode -ne 200 -or $_.StatusCode -ne 200 })
if ($failed.Count -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Output
    $lines.Clear()
    throw 'A test did not give HTTP 200. The script did not write the file.'
}

# 3. Write the file (UTF-8 with no BOM, LF line ends).
[IO.File]::WriteAllText($OutputPath, (($lines -join "`n") + "`n"), $Utf8NoBom)
$lines.Clear()

# Two object types: format each one, else the first table hides the second type.
$results | Format-Table -AutoSize | Out-String -Stream | Write-Output
[pscustomobject]@{
    File  = $OutputPath
    Keys  = $keyNames -join ', '
    Bytes = (Get-Item -LiteralPath $OutputPath).Length
} | Format-List | Out-String -Stream | Write-Output
