#Requires -Version 7.0
<#
.SYNOPSIS
    Install Ollama as a Windows service: NSSM, NT AUTHORITY\LocalService, 127.0.0.1 only.
    Step M2 of PLAN-LOCAL-LLM.md.

.DESCRIPTION
    Dry run by default: the script checks the input files and the system, and shows each
    change. With -Apply (elevated terminal) it makes the changes. It does not start the service.

    Changes with -Apply, in this sequence:
      1. Data folders C:\ollama\{models,logs,staging,inbox,eval,bin}.
         LocalService gets Modify on models and logs.
      2. The files of the release zip go into C:\Program Files\Ollama.
      3. nssm.exe goes into C:\Program Files\NSSM. Only an administrator can write there.
      4. The service Ollama (NSSM): Automatic (Delayed), restart 60 s after an exit,
         log file with rotation, environment.
      5. The service account becomes NT AUTHORITY\LocalService.
      6. Windows Firewall: one inbound block rule for each .exe file of Ollama.

    Before a change, the script stops if one of these items is already on the system.
    If a step fails (or you push Ctrl+C), the script removes the items that this run made,
    in the reverse sequence, and then stops.
    To remove a good installation, use Uninstall-OllamaService.ps1.

    The service environment has no secret by design. Never add a secret to it.

.PARAMETER ZipPath
    The release file ollama-windows-amd64.zip. Its SHA256 must agree with the value in this script.

.PARAMETER NssmSource
    The nssm.exe to copy. Default: the target of the WinGet link of nssm.exe.
    Its SHA256 must agree with the value in this script.

.PARAMETER Apply
    Make the changes. Without -Apply the script changes nothing.

.EXAMPLE
    pwsh -NoProfile -File .\Install-OllamaService.ps1 -ZipPath "$HOME\Downloads\ollama-v0.40.13\ollama-windows-amd64.zip"

    Dry run: checks and the list of changes.

.EXAMPLE
    pwsh -NoProfile -File .\Install-OllamaService.ps1 -ZipPath "$HOME\Downloads\ollama-v0.40.13\ollama-windows-amd64.zip" -Apply

    Installation. Use an elevated terminal.

.NOTES
    v1.0 (2026-11-11). Created with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ZipPath,

    [string]$NssmSource,

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Pinned values -----------------------------------------------------------------------------

$OllamaVersion   = 'v0.40.13'
# SHA256 of ollama-windows-amd64.zip. The GitHub asset digest and sha256sum.txt of the release
# agree (checked on 2026-11-11).
$OllamaZipSha256 = '7AFA38624FA62EE5D8293422D0AB084C1BB4603134C7F4DAFCE11A033B57CC19'
# SHA256 of win64\nssm.exe in nssm-2.24-101-g897c7ad.zip. The zip agrees with the WinGet
# manifest (99F5045F...07B8), and this entry agrees with the WinGet copy (checked on 2026-11-11).
$NssmSha256      = 'EEE9C44C29C2BE011F1F1E43BB8C3FCA888CB81053022EC5A0060035DE16D848'

$ServiceName     = 'Ollama'
$ServiceAccount  = 'NT AUTHORITY\LocalService'
$LocalServiceSid = 'S-1-5-19'
$Port            = 11434
$InstallDir      = 'C:\Program Files\Ollama'
$NssmDir         = 'C:\Program Files\NSSM'
$NssmTarget      = Join-Path $NssmDir 'nssm.exe'
$OllamaExe       = Join-Path $InstallDir 'ollama.exe'
$DataRoot        = 'C:\ollama'
$DataFolders     = @('models', 'logs', 'staging', 'inbox', 'eval', 'bin')
# Only the service writes to these folders. The other folders are for localllm, which runs as the user.
$ServiceFolders  = @('models', 'logs')
$LogFile         = Join-Path $DataRoot 'logs\server.log'
$LogRotateBytes  = 10MB
$RestartDelayMs  = 60000
$FirewallGroup   = 'localllm'

# Relative to $InstallDir. Ollama starts llama-server.exe as its model runner.
$ProgramFiles = @('ollama.exe', 'lib\ollama\llama-server.exe', 'lib\ollama\llama-quantize.exe')

# No secret here, by design (PLAN-LOCAL-LLM.md, section 3).
$ServiceEnvironment = @(
    "OLLAMA_HOST=127.0.0.1:$Port"
    "OLLAMA_MODELS=$(Join-Path $DataRoot 'models')"
    'OLLAMA_KEEP_ALIVE=2m'
    'OLLAMA_MAX_LOADED_MODELS=1'
    'OLLAMA_NUM_PARALLEL=1'
    'OLLAMA_CONTEXT_LENGTH=8192'
    'OLLAMA_KV_CACHE_TYPE=q8_0'
    'OLLAMA_NO_CLOUD=1'
    'OLLAMA_MAX_QUEUE=16'
)

# --- Functions ---------------------------------------------------------------------------------

function Test-Administrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PortExcluded {
    <#
    .SYNOPSIS
        True if the TCP port is in a Windows excluded port range (IPv4).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$PortNumber)
    $lines = & netsh.exe int ipv4 show excludedportrange protocol=tcp
    foreach ($line in $lines) {
        if ($line -match '^\s*(\d+)\s+(\d+)') {
            if ($PortNumber -ge [int]$Matches[1] -and $PortNumber -le [int]$Matches[2]) { return $true }
        }
    }
    $false
}

function Resolve-NssmSource {
    <#
    .SYNOPSIS
        The real file behind the WinGet link of nssm.exe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $command = Get-Command -Name 'nssm.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) { throw 'nssm.exe is not on the PATH. Use -NssmSource.' }
    $item = Get-Item -LiteralPath $command.Source
    if ($item.LinkType) { $item.ResolvedTarget } else { $item.FullName }
}

function Assert-FileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected) {
        throw "$Label has the wrong SHA256. Expected $Expected, found $actual ($Path)."
    }
    "OK    $Label SHA256 $actual"
}

function Invoke-Nssm {
    <#
    .SYNOPSIS
        Run the NSSM copy in Program Files. Show its output only when it fails.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & $NssmTarget @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "nssm $($Arguments[0]) $($Arguments[1]) $($Arguments[2]) failed (exit code $LASTEXITCODE): $($output -join ' ')"
    }
}

# --- Preflight (dry run and -Apply) ------------------------------------------------------------

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN' }
"Install-OllamaService $OllamaVersion - $mode"
''

if ($Apply -and -not (Test-Administrator)) {
    throw 'Use an elevated terminal for -Apply.'
}

Assert-FileHash -Path $ZipPath -Expected $OllamaZipSha256 -Label 'Ollama zip'
# .NET methods resolve a relative path from the process folder, not from the PowerShell location.
$ZipPath = (Resolve-Path -LiteralPath $ZipPath).ProviderPath

if (-not $NssmSource) { $NssmSource = Resolve-NssmSource }
Assert-FileHash -Path $NssmSource -Expected $NssmSha256 -Label 'NSSM source'

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $entryNames = $zip.Entries.FullName | ForEach-Object { $_ -replace '/', '\' }
    foreach ($file in $ProgramFiles) {
        if ($file -notin $entryNames) { throw "The zip has no entry $file." }
    }
    $exeEntries = @($entryNames | Where-Object { $_ -like '*.exe' })
    $unknownExe = @($exeEntries | Where-Object { $_ -notin $ProgramFiles })
    if ($unknownExe) {
        throw "The zip has .exe files with no firewall rule in this script: $($unknownExe -join ', ')"
    }
    "OK    Zip has $($zip.Entries.Count) entries. Its .exe files: $($exeEntries -join ', ')"
}
finally {
    $zip.Dispose()
}

$blockers = [System.Collections.Generic.List[string]]::new()
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { $blockers.Add("Service $ServiceName exists.") }
if (Test-Path -LiteralPath $InstallDir) { $blockers.Add("$InstallDir exists.") }
if (Test-Path -LiteralPath $DataRoot) { $blockers.Add("$DataRoot exists.") }
if (Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue) {
    $blockers.Add("Firewall rules of the group '$FirewallGroup' exist.")
}
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    $blockers.Add("A process listens on port $Port.")
}
if (Test-PortExcluded -PortNumber $Port) { $blockers.Add("Port $Port is in a Windows excluded port range.") }

# An NSSM copy with the pinned SHA256 can stay. The run does not remove it at a rollback.
$reuseNssm = $false
if (Test-Path -LiteralPath $NssmTarget) {
    if ((Get-FileHash -LiteralPath $NssmTarget -Algorithm SHA256).Hash -eq $NssmSha256) {
        $reuseNssm = $true
    }
    else {
        $blockers.Add("$NssmTarget exists with a different SHA256.")
    }
}

if ($blockers.Count -gt 0) {
    $blockers | ForEach-Object { "STOP  $_" }
    throw 'The system is not clean. The script made no change. Read the STOP lines.'
}
"OK    No item of this installation is on the system. Port $Port is free."
''

# --- Steps -------------------------------------------------------------------------------------

$serviceFolderList = ($ServiceFolders | ForEach-Object { Join-Path $DataRoot $_ }) -join ', '
$nssmStepText = if ($reuseNssm) { "Keep $NssmTarget (the SHA256 agrees)" } else { "Copy nssm.exe to $NssmTarget" }
$steps = @(
    "1. Make $DataRoot\{$($DataFolders -join ',')}. LocalService gets Modify on $serviceFolderList"
    "2. Extract the zip to $InstallDir"
    "3. $nssmStepText"
    "4. Install the service ${ServiceName}: $OllamaExe serve, Automatic (Delayed), restart after $($RestartDelayMs / 1000) s, log $LogFile (rotation at $($LogRotateBytes / 1MB) MB)"
    "5. Set the service account to $ServiceAccount"
    "6. Add inbound block rules (group '$FirewallGroup', all profiles) for: $($ProgramFiles -join ', ')"
)
$steps
''
'Service environment:'
$ServiceEnvironment | ForEach-Object { "    $_" }
''

if (-not $Apply) {
    'DRY RUN: no change. Run again with -Apply in an elevated terminal. The service does not start.'
    return
}

# Each step adds its undo action here before it changes something.
$undo = [System.Collections.Generic.List[pscustomobject]]::new()
$completed = $false

try {
    # Step 1: data folders.
    New-Item -ItemType Directory -Path $DataRoot | Out-Null
    $undo.Add([pscustomobject]@{ Text = "Remove $DataRoot"; Action = { Remove-Item -LiteralPath $DataRoot -Recurse -Force } })
    foreach ($folder in $DataFolders) {
        New-Item -ItemType Directory -Path (Join-Path $DataRoot $folder) | Out-Null
    }
    foreach ($folder in $ServiceFolders) {
        # The SID, not the name: the name of the account can change with the language of Windows.
        $null = & icacls.exe (Join-Path $DataRoot $folder) /grant "*${LocalServiceSid}:(OI)(CI)M"
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $folder (exit code $LASTEXITCODE)." }
    }
    'DONE  1. Data folders'

    # Step 2: program files. .NET refuses zip entries that point outside the target folder.
    $undo.Add([pscustomobject]@{ Text = "Remove $InstallDir"; Action = { Remove-Item -LiteralPath $InstallDir -Recurse -Force } })
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $InstallDir)
    foreach ($file in $ProgramFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $file) -PathType Leaf)) {
            throw "After the extraction, $file is not in $InstallDir."
        }
    }
    "DONE  2. Program files. ollama.exe SHA256 $((Get-FileHash -LiteralPath $OllamaExe -Algorithm SHA256).Hash)"

    # Step 3: NSSM copy that only an administrator can change (PLAN-LOCAL-LLM.md, decision D4).
    if (-not $reuseNssm) {
        $nssmDirExisted = Test-Path -LiteralPath $NssmDir
        $undo.Add([pscustomobject]@{
                Text   = "Remove $NssmTarget"
                Action = {
                    Remove-Item -LiteralPath $NssmTarget -Force -ErrorAction SilentlyContinue
                    if (-not $nssmDirExisted) { Remove-Item -LiteralPath $NssmDir -Recurse -Force -ErrorAction SilentlyContinue }
                }.GetNewClosure()
            })
        if (-not $nssmDirExisted) { New-Item -ItemType Directory -Path $NssmDir | Out-Null }
        Copy-Item -LiteralPath $NssmSource -Destination $NssmTarget
        Assert-FileHash -Path $NssmTarget -Expected $NssmSha256 -Label 'NSSM copy' | Out-Null
    }
    'DONE  3. NSSM'

    # Step 4: the service. 'nssm install' does not start it.
    Invoke-Nssm -Arguments @('install', $ServiceName, $OllamaExe, 'serve')
    $undo.Add([pscustomobject]@{ Text = "Remove the service $ServiceName"; Action = { Invoke-Nssm -Arguments @('remove', $ServiceName, 'confirm') } })
    Invoke-Nssm -Arguments @('set', $ServiceName, 'DisplayName', 'Ollama')
    Invoke-Nssm -Arguments @('set', $ServiceName, 'Description', "Ollama $OllamaVersion, local LLM engine on 127.0.0.1:$Port (tools/localllm).")
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppDirectory', $InstallDir)
    Invoke-Nssm -Arguments @('set', $ServiceName, 'Start', 'SERVICE_DELAYED_AUTO_START')
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppStdout', $LogFile)
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppStderr', $LogFile)
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppRotateFiles', '1')
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppRotateOnline', '1')
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppRotateBytes', [string]$LogRotateBytes)
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppExit', 'Default', 'Restart')
    Invoke-Nssm -Arguments @('set', $ServiceName, 'AppRestartDelay', [string]$RestartDelayMs)
    # One KEY=VALUE pair in each argument (NSSM command line docs).
    Invoke-Nssm -Arguments (@('set', $ServiceName, 'AppEnvironmentExtra') + $ServiceEnvironment)
    'DONE  4. Service'

    # Step 5: account. Win32_Service.Change: these built-in accounts need an empty password string.
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
    $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{
        StartName     = $ServiceAccount
        StartPassword = ''
    }
    if ($result.ReturnValue -ne 0) { throw "Win32_Service.Change returned $($result.ReturnValue)." }
    'DONE  5. Account'

    # Step 6: firewall. Loopback traffic does not go through these rules.
    foreach ($file in $ProgramFiles) {
        $leaf = [IO.Path]::GetFileNameWithoutExtension($file)
        $ruleName = "Ollama-BlockInbound-$leaf"
        $undo.Add([pscustomobject]@{
                Text   = "Remove the firewall rule $ruleName"
                Action = { Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue }.GetNewClosure()
            })
        New-NetFirewallRule -Name $ruleName -DisplayName "Ollama: block inbound ($leaf)" -Group $FirewallGroup `
            -Direction Inbound -Action Block -Profile Any -Program (Join-Path $InstallDir $file) `
            -Description 'Second layer after the 127.0.0.1 bind (tools/localllm).' | Out-Null
    }
    'DONE  6. Firewall'

    # Check the result.
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
    $rules = @(Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue)
    $check = [pscustomobject]@{
        Service          = $service.Name
        State            = $service.State
        StartMode        = $service.StartMode
        DelayedAutoStart = $service.DelayedAutoStart
        Account          = $service.StartName
        UsesNssmCopy     = $service.PathName -like "*$NssmTarget*"
        FirewallRules    = $rules.Count
    }
    $problems = @(
        if ($check.State -ne 'Stopped') { "state is $($check.State), not Stopped" }
        if ($check.StartMode -ne 'Auto' -or -not $check.DelayedAutoStart) { 'start type is not Automatic (Delayed)' }
        if ($check.Account -ne $ServiceAccount) { "account is $($check.Account)" }
        if (-not $check.UsesNssmCopy) { "the service binary is not $NssmTarget" }
        if ($check.FirewallRules -ne $ProgramFiles.Count) { "found $($check.FirewallRules) firewall rules, not $($ProgramFiles.Count)" }
    )
    if ($problems) { throw "Final check failed: $($problems -join '; ')." }

    $completed = $true
    ''
    $check
    "Installed. The service is stopped. Start it only with a separate OK: Start-Service $ServiceName"
}
finally {
    if (-not $completed) {
        ''
        'ROLLBACK: remove the items of this run, in the reverse sequence.'
        for ($i = $undo.Count - 1; $i -ge 0; $i--) {
            try {
                & $undo[$i].Action
                "UNDONE  $($undo[$i].Text)"
            }
            catch {
                "FAILED  $($undo[$i].Text): $($_.Exception.Message). Remove it by hand."
            }
        }
    }
}
