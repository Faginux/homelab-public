<#
.SYNOPSIS
    Calls the Komodo API with the key of the service user `claude-ops`.

.DESCRIPTION
    Claude Code uses it to manage the Stacks of ARCADE without the UI
    (PIANO-KOMODO-SECRETS-GATE.md §2b.3). The key is in a file that the operator wrote,
    outside the repo. The script never prints the key: it reads it, puts it in the headers
    and returns only the response.

    The script always deletes from the response the fields that can contain the resolved
    config or the secrets (the same discipline as the gate). It puts "<redatto: N caratteri>"
    in their place, so you can see if they are empty, but not their contents.

    Permissions of the user (decided on 2026-10-02): Read + Attach + Logs on the Server
    arcade only. It can create Stacks and attach them to arcade. It has Write on
    the Stacks that it creates. It does not see or change the Stacks of the-grid. The
    "Regola numero uno" (rule number one) of CLAUDE.md does not change: Deploy, Destroy
    and Delete only after the operator confirms.

.PARAMETER Kind
    Endpoint of the API: read, write or execute.

.PARAMETER Type
    Name of the request, for example ListStacks, CreateStack, DeployStack.

.PARAMETER Params
    Parameters of the request.

.PARAMETER CredentialPath
    JSON file with url, key and secret. Default: %USERPROFILE%\.config\komodo-claude\credentials.json

.EXAMPLE
    .\Invoke-KomodoApi.ps1 -Kind read -Type ListServers

.EXAMPLE
    .\Invoke-KomodoApi.ps1 -Kind execute -Type DeployStack -Params @{ stack = 'cleanuparr' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('read', 'write', 'execute')]
    [string]$Kind,

    [Parameter(Mandatory)]
    [string]$Type,

    [hashtable]$Params = @{},

    [string]$CredentialPath = (Join-Path $env:USERPROFILE '.config\komodo-claude\credentials.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fields never returned in clear text: resolved compose config, file contents,
# environment (it must stay empty in the UI, here only the length shows).
$CampiRedatti = @(
    'deployed_config', 'deployed_contents', 'remote_contents', 'file_contents',
    'environment', 'contents', 'secret'
)

function Hide-SensitiveField {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Node)

    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in @($Node.PSObject.Properties)) {
            if ($p.Name -in $CampiRedatti -and $null -ne $p.Value) {
                $len = ($p.Value | ConvertTo-Json -Depth 50 -Compress).Length
                $p.Value = "<redatto: $len caratteri>"
            } else {
                $p.Value = Hide-SensitiveField -Node $p.Value
            }
        }
        return $Node
    }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        return , @($Node | ForEach-Object { Hide-SensitiveField -Node $_ })
    }
    return $Node
}

if (-not (Test-Path -LiteralPath $CredentialPath)) {
    throw "File credenziali non trovato: $CredentialPath (lo scrive Faginux, vedi tools/komodo-api/README.md)"
}
$cred = Get-Content -LiteralPath $CredentialPath -Raw | ConvertFrom-Json

$request = @{
    Uri         = '{0}/{1}' -f $cred.url.TrimEnd('/'), $Kind
    Method      = 'Post'
    ContentType = 'application/json'
    Headers     = @{ 'x-api-key' = $cred.key; 'x-api-secret' = $cred.secret }
    Body        = @{ type = $Type; params = $Params } | ConvertTo-Json -Depth 20 -Compress
}

try {
    $response = Invoke-RestMethod @request
} catch {
    # The body of a Komodo error is a message: it does not contain the key
    $detail = $_.ErrorDetails.Message
    throw "Komodo $Kind/$Type fallita: $($_.Exception.Message) $detail"
} finally {
    $request.Headers = $null
    $cred = $null
}

# ForEach-Object unrolls the lists (ListStacks and others): an empty list must not
# become an empty item
Hide-SensitiveField -Node $response | ForEach-Object { $_ }
