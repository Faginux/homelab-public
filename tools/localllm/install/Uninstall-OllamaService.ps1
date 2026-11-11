#Requires -Version 7.0
<#
.SYNOPSIS
    Remove the Ollama service of Install-OllamaService.ps1. This is the rollback of step M2 of
    PLAN-LOCAL-LLM.md.

.DESCRIPTION
    Dry run by default: the script shows what it finds and what it removes. With -Apply
    (elevated terminal) it makes the changes, in this sequence:
      1. If the service Ollama runs, stop it. Stop Ollama processes from C:\Program Files\Ollama
         that are still there.
      2. Remove the service Ollama.
      3. Remove the firewall rules of the group 'localllm'.
      4. Remove C:\Program Files\Ollama.

    These items stay, if you do not give a switch:
      -RemoveData                 C:\ollama (models, logs, staging, inbox, eval, bin).
      -RemoveNssm                 C:\Program Files\NSSM\nssm.exe. Step M7 uses this copy for other
                                  services. The script refuses if another service uses it.
      -RemoveServiceProfileData   The folder .ollama in the profile of LocalService. Ollama makes a
                                  key pair there at the first start. The script never shows the
                                  content of these files.

.PARAMETER Apply
    Make the changes. Without -Apply the script changes nothing.

.EXAMPLE
    pwsh -NoProfile -File .\Uninstall-OllamaService.ps1

    Dry run.

.EXAMPLE
    pwsh -NoProfile -File .\Uninstall-OllamaService.ps1 -Apply

    Removal. The models stay. Use an elevated terminal.

.NOTES
    v1.0 (2026-11-11). Created with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$RemoveData,
    [switch]$RemoveNssm,
    [switch]$RemoveServiceProfileData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The same values as Install-OllamaService.ps1. The paths are constants, so a parameter cannot
# send a recursive removal to a different folder.
$ServiceName    = 'Ollama'
$InstallDir     = 'C:\Program Files\Ollama'
$NssmDir        = 'C:\Program Files\NSSM'
$NssmTarget     = Join-Path $NssmDir 'nssm.exe'
$DataRoot       = 'C:\ollama'
$FirewallGroup  = 'localllm'
$ProfileData    = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\.ollama'
$StopTimeoutSec = 60

function Test-Administrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FolderSummary {
    <#
    .SYNOPSIS
        Number of files and total size of a folder. No file names, no content.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'not found' }
    try {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Stop)
        $bytes = ($files | Measure-Object -Property Length -Sum).Sum
        '{0} files, {1:N2} GB' -f $files.Count, ($bytes / 1GB)
    }
    catch {
        'found, but not readable (use an elevated terminal)'
    }
}

function Get-OllamaProcess {
    [CmdletBinding()]
    param()
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase) }
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN' }
"Uninstall-OllamaService - $mode"
''

if ($Apply -and -not (Test-Administrator)) {
    throw 'Use an elevated terminal for -Apply.'
}

# --- What is on the system ---------------------------------------------------------------------

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$rules = @(Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue)
$otherNssmUsers = @(
    Get-CimInstance -ClassName Win32_Service |
        Where-Object { $_.Name -ne $ServiceName -and $_.PathName -and $_.PathName -like "*$NssmTarget*" } |
        Select-Object -ExpandProperty Name
)

$serviceText = if ($service) { "$($service.Status), start type $($service.StartType)" } else { 'not found' }
"Service $ServiceName :  $serviceText"
"Ollama processes:   $(@(Get-OllamaProcess).Count)"
"Firewall rules:     $($rules.Count) in the group '$FirewallGroup'"
"Program files:      $InstallDir - $(Get-FolderSummary -Path $InstallDir)"
"Data:               $DataRoot - $(Get-FolderSummary -Path $DataRoot)"
"NSSM copy:          $NssmTarget - $(if (Test-Path -LiteralPath $NssmTarget) { 'found' } else { 'not found' })"
"Other NSSM users:   $(if ($otherNssmUsers) { $otherNssmUsers -join ', ' } else { 'none' })"
"Profile data:       $ProfileData - $(Get-FolderSummary -Path $ProfileData)"
''

$keep = [System.Collections.Generic.List[string]]::new()
if (-not $RemoveData) { $keep.Add("$DataRoot (use -RemoveData)") }
if (-not $RemoveNssm) { $keep.Add("$NssmTarget (use -RemoveNssm)") }
if (-not $RemoveServiceProfileData) { $keep.Add("$ProfileData (use -RemoveServiceProfileData)") }
if ($RemoveNssm -and $otherNssmUsers) {
    throw "Do not use -RemoveNssm: these services use $NssmTarget : $($otherNssmUsers -join ', '). The script made no change."
}
'Stays: ' + $(if ($keep.Count) { $keep -join '; ' } else { 'nothing' })
''

if (-not $Apply) {
    'DRY RUN: no change. Run again with -Apply in an elevated terminal.'
    return
}

# --- Removal -----------------------------------------------------------------------------------

# Step 1: stop. NSSM stops the process tree of Ollama with the service.
if ($service -and $service.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName
    $service.WaitForStatus('Stopped', [timespan]::FromSeconds($StopTimeoutSec))
    'DONE  1. Service stopped'
}
$leftover = @(Get-OllamaProcess)
if ($leftover) {
    $leftover | Stop-Process -Force
    "DONE  1. Stopped $($leftover.Count) Ollama processes that were still there"
}

# Step 2: service. If a program keeps a handle on it (for example services.msc), Windows removes
# it when that program closes.
if ($service) {
    Remove-Service -Name $ServiceName
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        "WARN  2. The service is marked for removal. Close services.msc and the Event Viewer, then run Get-Service $ServiceName again."
    }
    else {
        'DONE  2. Service removed'
    }
}

# Step 3: firewall.
if ($rules) {
    $rules | Remove-NetFirewallRule
    "DONE  3. Removed $($rules.Count) firewall rules"
}

# Step 4: program files.
if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    "DONE  4. Removed $InstallDir"
}

# Optional items.
if ($RemoveData -and (Test-Path -LiteralPath $DataRoot)) {
    Remove-Item -LiteralPath $DataRoot -Recurse -Force
    "DONE  Removed $DataRoot"
}
if ($RemoveNssm -and (Test-Path -LiteralPath $NssmTarget)) {
    Remove-Item -LiteralPath $NssmTarget -Force
    if (-not (Get-ChildItem -LiteralPath $NssmDir -Force)) { Remove-Item -LiteralPath $NssmDir -Force }
    "DONE  Removed $NssmTarget"
}
if ($RemoveServiceProfileData -and (Test-Path -LiteralPath $ProfileData)) {
    Remove-Item -LiteralPath $ProfileData -Recurse -Force
    "DONE  Removed $ProfileData"
}

''
'Removed. Check: Get-Service Ollama gives an error, and port 11434 has no listener.'
