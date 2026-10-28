<#
.SYNOPSIS
    Switch the Windows service "Glances" to the launcher with the CPU temperature, or back.

.DESCRIPTION
    The service runs Glances through NSSM as LocalSystem. "Enable" does these steps:
      1. Copy glances_lhm.py and the DLL files of LibreHardwareMonitor to InstallDir
         (C:\Program Files\GlancesLhm by default). LocalSystem loads this code, so
         the directory must not be writable by a normal user.
      2. Check the permissions of InstallDir. The script stops if a user other than
         SYSTEM, Administrators or TrustedInstaller can write there.
      3. Set the parameters of the service to the copy of glances_lhm.py, and restart
         the service.
    "Disable" sets the parameters back to "-m glances". The files in InstallDir stay.
    Then the script waits for the API and, for "Enable", reads the sensors.
    If the API does not come back in time, the script restores the old parameters.

    Use -WhatIf to see the steps without a change. Run it in an elevated PowerShell.
    Run "Enable" again after an update of LibreHardwareMonitor, to refresh the copy.

.EXAMPLE
    pwsh -NoProfile -File .\Set-GlancesLauncher.ps1 -WhatIf

.EXAMPLE
    pwsh -NoProfile -File .\Set-GlancesLauncher.ps1 -Mode Disable
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Enable', 'Disable')]
    [string]$Mode = 'Enable',

    # The Tailscale IP of ARCADE. The service listens on this address only.
    [string]$BindAddress = '198.51.100.10',

    # Not 61208: Windows reserves ranges of ports above 49152 at each boot (Hyper-V, Docker),
    # and on 2026-10-17 it reserved 61195 to 61294. Glances could not bind, and NSSM restarted it
    # every 11 seconds. Ports below 49152 are never in these ranges.
    [int]$Port = 18208,

    [int]$TimeoutSeconds = 60,

    # Where the service loads the launcher and the library. Admin-write only.
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'GlancesLhm'),

    # The WinGet package of LibreHardwareMonitor. This is the source of the DLL files.
    [string]$LibrarySource = (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceName = 'Glances'
$parametersKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName\Parameters"
$launcherSource = Join-Path $PSScriptRoot 'glances_lhm.py'
$launcher = Join-Path $InstallDir 'glances_lhm.py'
$libraryDir = Join-Path $InstallDir 'lib'

function Get-AppParameter {
    [CmdletBinding()]
    param()
    (Get-ItemProperty -Path $parametersKey).AppParameters
}

function Wait-GlancesApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-RestMethod -Uri "http://${Address}:$Port/api/4/version" -TimeoutSec 5
            return $true
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Assert-AdminOnlyWrite {
    <# Stop if a user other than SYSTEM, Administrators or TrustedInstaller can change the tree. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # Compare SIDs, not names: some names are translated by Windows.
    $trustedSids = @(
        'S-1-5-18'                                                            # SYSTEM
        'S-1-5-32-544'                                                        # Administrators
        'S-1-3-0'                                                             # CREATOR OWNER
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'      # TrustedInstaller
    )
    # Only the bits that change a file. The composite rights "Modify" and "FullControl"
    # also hold the read bits, so they must not be in this mask. 0x50000000 is
    # GENERIC_ALL and GENERIC_WRITE, which appear in the entries that children inherit.
    $rights = [System.Security.AccessControl.FileSystemRights]
    $writeMask = [int]($rights::WriteData -bor $rights::AppendData -bor $rights::WriteExtendedAttributes `
            -bor $rights::WriteAttributes -bor $rights::DeleteSubdirectoriesAndFiles -bor $rights::Delete `
            -bor $rights::ChangePermissions -bor $rights::TakeOwnership) -bor 0x50000000

    $items = @(Get-Item -LiteralPath $Path -Force) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $trustedSids) {
            throw "Unsafe owner on '$($item.FullName)': $owner. Only SYSTEM, Administrators or TrustedInstaller may own it."
        }
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            if (([int]$rule.FileSystemRights -band $writeMask) -eq 0) { continue }
            $sid = if ($rule.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
                $rule.IdentityReference.Value
            }
            else {
                $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            if ($sid -in $trustedSids) { continue }
            throw "Unsafe permission on '$($item.FullName)': $($rule.IdentityReference) has $($rule.FileSystemRights). LocalSystem loads this code."
        }
    }
}

if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
    throw 'nssm was not found in the PATH.'
}
if ($Mode -eq 'Enable') {
    if (-not (Test-Path -LiteralPath $launcherSource)) {
        throw "Launcher not found: $launcherSource"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $LibrarySource 'LibreHardwareMonitorLib.dll'))) {
        throw "LibreHardwareMonitorLib.dll not found in: $LibrarySource"
    }
}

$oldParameters = Get-AppParameter
$newParameters = if ($Mode -eq 'Enable') {
    '"{0}" -w -B {1} -p {2}' -f $launcher, $BindAddress, $Port
}
else {
    '-m glances -w -B {0} -p {1}' -f $BindAddress, $Port
}

Write-Host "Service:         $serviceName"
if ($Mode -eq 'Enable') {
    Write-Host "Copy to:         $InstallDir (launcher and the DLL files from $LibrarySource)"
}
Write-Host "Old parameters:  $oldParameters"
Write-Host "New parameters:  $newParameters"

if (-not $PSCmdlet.ShouldProcess($serviceName, "Copy the files, set AppParameters and restart ($Mode)")) {
    return
}

if ($Mode -eq 'Enable') {
    New-Item -ItemType Directory -Path $libraryDir -Force | Out-Null
    Copy-Item -LiteralPath $launcherSource -Destination $launcher -Force

    # The running service holds the DLL files open. Copy only the files that differ,
    # and stop the service first if there are any.
    $changed = @(Get-ChildItem -LiteralPath $LibrarySource -Filter '*.dll' -File | Where-Object {
            $target = Join-Path $libraryDir $_.Name
            -not (Test-Path -LiteralPath $target) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        })
    if ($changed.Count -gt 0) {
        Write-Host "Stopping the service to copy $($changed.Count) DLL file(s)."
        Stop-Service -Name $serviceName
        try {
            $changed | Copy-Item -Destination $libraryDir -Force
        }
        catch {
            Start-Service -Name $serviceName
            throw
        }
    }
    Assert-AdminOnlyWrite -Path $InstallDir
    $libraryHash = (Get-FileHash -LiteralPath (Join-Path $libraryDir 'LibreHardwareMonitorLib.dll') -Algorithm SHA256).Hash
    Write-Host "Files copied. Permissions are safe. SHA256 of LibreHardwareMonitorLib.dll: $libraryHash"
}

& nssm set $serviceName AppParameters $newParameters | Out-Null
Restart-Service -Name $serviceName
$isUp = Wait-GlancesApi -Address $BindAddress -Port $Port -TimeoutSeconds $TimeoutSeconds

if (-not $isUp) {
    Write-Warning "The API did not answer in $TimeoutSeconds s. Restoring the old parameters."
    & nssm set $serviceName AppParameters $oldParameters | Out-Null
    Restart-Service -Name $serviceName
    $isBack = Wait-GlancesApi -Address $BindAddress -Port $Port -TimeoutSeconds $TimeoutSeconds
    throw "Rollback done. The API is back: $isBack. Read the log of the service."
}

Write-Host "The API answers on ${BindAddress}:$Port."
if ($Mode -eq 'Enable') {
    $sensors = @(Invoke-RestMethod -Uri "http://${BindAddress}:$Port/api/4/sensors" -TimeoutSec 30)
    $tctl = $sensors | Where-Object { $_.label -eq 'Tctl' }
    if ($tctl) {
        Write-Host "Tctl: $($tctl.value) C. The Homepage widget can show it."
    }
    else {
        Write-Warning 'The API gives no Tctl sensor. Glances still runs. Read README.md, "Problems".'
    }
}
