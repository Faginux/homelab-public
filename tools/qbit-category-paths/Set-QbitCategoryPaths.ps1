<#
.SYNOPSIS
    Point the Sonarr and Radarr categories of qBittorrent to a new save path on S:.

.DESCRIPTION
    Dry run by default: the script only reads and prints the plan.
    With -Apply it does these steps. It stops at the first check that fails.

    1. Check that no torrent is downloading, moving, or checking.
    2. Save the categories and the torrents to a backup file.
    3. Turn OFF "category_changed_tmm_enabled". Without this, a change of
       the save path of a category moves all its Automatic Torrent Management
       torrents to the new path.
    4. Change ONE category first (canary). Check that its torrent stays in place,
       is now in manual mode, and that no other field of the category changed.
    5. Change the other categories. Check all torrents again.
    6. Turn "category_changed_tmm_enabled" ON again.

    The PrivateTrackerA_* categories are not touched.
    The script does not delete anything and does not move any file by itself.

    Rollback: run the script with -RestoreFrom and the backup file of the run.
    It sets the old save paths again, with the same preference trick. Torrents
    that already finished on S: stay there and finish their seeding.

.EXAMPLE
    .\Set-QbitCategoryPaths.ps1            # dry run, read only
    .\Set-QbitCategoryPaths.ps1 -Apply     # make the change

.EXAMPLE
    .\Set-QbitCategoryPaths.ps1 -RestoreFrom S:\docker-appdata\qbit_manage\category-backups\<file>.json -Apply
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8082',
    [string]$NewRoot = 'S:/Downloads_torrent/complete',
    [string]$CanaryCategory = 'Radarr Anime',
    [string[]]$OtherCategory = @('Radarr 1080p', 'Radarr 4K', 'Sonarr 1080p', 'Sonarr 4K', 'Sonarr anime'),
    [string]$BackupDir = 'S:\docker-appdata\qbit_manage\category-backups',
    [string]$RestoreFrom,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-QbitData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $result = Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/v2/$Path"
    # PowerShell 7 returns a JSON array as ONE object. Send the items one by one.
    if ($result -is [System.Array]) {
        foreach ($item in $result) { $item }
    }
    else {
        $result
    }
}

function Invoke-QbitPost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Body
    )
    # The qBittorrent API takes form fields, not JSON, in the request body.
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/v2/$Path" -Body $Body | Out-Null
}

function ConvertTo-PathKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-TorrentSnapshot {
    [CmdletBinding()]
    param()
    Get-QbitData -Path 'torrents/info' |
        Select-Object hash, name, category, save_path, auto_tmm, state
}

function Get-CategoryObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $all = Get-QbitData -Path 'torrents/categories'
    $property = $all.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Category '$Name' does not exist." }
    $property.Value
}

function Get-CategoryFingerprint {
    # All fields of a category except the save path, as one string.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Category)
    $Category | Select-Object -Property * -ExcludeProperty savePath | ConvertTo-Json -Compress
}

function Wait-NoMovingTorrent {
    [CmdletBinding()]
    param([int]$MaxSeconds = 20)
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    do {
        Start-Sleep -Seconds 2
        $moving = @(Get-TorrentSnapshot | Where-Object { $_.state -eq 'moving' })
    } while ($moving.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($moving.Count -gt 0) { throw "$($moving.Count) torrent(s) are still moving after $MaxSeconds s." }
}

function Test-TorrentsInPlace {
    # Return a list of problems. An empty list means all torrents are in place.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Before,
        [Parameter(Mandatory)][string[]]$Categories
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $now = Get-TorrentSnapshot
    foreach ($old in $Before) {
        $new = $now | Where-Object { $_.hash -eq $old.hash }
        if ($null -eq $new) { $problems.Add("Torrent '$($old.name)' is gone."); continue }
        if ((ConvertTo-PathKey $new.save_path) -ne (ConvertTo-PathKey $old.save_path)) {
            $problems.Add("Torrent '$($old.name)' moved: $($old.save_path) -> $($new.save_path)")
        }
        if ($new.state -eq 'moving') { $problems.Add("Torrent '$($old.name)' is moving.") }
        if ($old.category -in $Categories -and $new.auto_tmm) {
            $problems.Add("Torrent '$($old.name)' is still in automatic mode.")
        }
    }
    , $problems
}

function Set-CategoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SavePath
    )
    Invoke-QbitPost -Path 'torrents/editCategory' -Body @{
        category = $Name
        savePath = $SavePath
    }
}

function Set-MoveOnCategoryChange {
    # Turn the preference ON or OFF, then read it back. Stop if it did not change.
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled)
    $value = $Enabled.ToString().ToLowerInvariant()
    Invoke-QbitPost -Path 'app/setPreferences' -Body @{ json = "{`"category_changed_tmm_enabled`":$value}" }
    if ([bool](Get-QbitData -Path 'app/preferences').category_changed_tmm_enabled -ne $Enabled) {
        throw "category_changed_tmm_enabled is not $Enabled after the change. Check it by hand."
    }
}

$allNames = @($CanaryCategory) + $OtherCategory

# --- Rollback mode -------------------------------------------------------
if ($RestoreFrom) {
    $backup = Get-Content -Raw -Path $RestoreFrom | ConvertFrom-Json
    $plan = foreach ($name in $allNames) {
        [pscustomobject]@{
            Name     = $name
            Current  = (Get-CategoryObject -Name $name).savePath
            SavePath = $backup.categories.PSObject.Properties[$name].Value.savePath
        }
    }
    Write-Host 'Restore plan (current path -> saved path):'
    foreach ($item in $plan) {
        '  {0,-14} {1}  ->  {2}' -f $item.Name, $item.Current, $item.SavePath
    }
    if (-not $Apply) {
        Write-Host 'Dry run: nothing was changed. Add -Apply to restore.'
        return
    }
    Set-MoveOnCategoryChange -Enabled $false
    foreach ($item in $plan) {
        Set-CategoryPath -Name $item.Name -SavePath $item.SavePath
        Write-Host "Category '$($item.Name)' restored."
    }
    Wait-NoMovingTorrent
    Set-MoveOnCategoryChange -Enabled $true
    Write-Host 'Restore done. category_changed_tmm_enabled is ON again.'
    return
}

# --- Step 1: read the state and check it ---------------------------------
$torrents = @(Get-TorrentSnapshot)
$busy = @($torrents | Where-Object { $_.state -notmatch '^(uploading|stalledUP|queuedUP|forcedUP|pausedUP|stoppedUP)$' })
$preferences = Get-QbitData -Path 'app/preferences'

Write-Host "qBittorrent API $(Get-QbitData -Path 'app/webapiVersion') at $BaseUrl"
Write-Host "Torrents: $($torrents.Count). Not only seeding: $($busy.Count)."
Write-Host "category_changed_tmm_enabled now: $($preferences.category_changed_tmm_enabled)"
Write-Host ''
Write-Host 'Plan (old path -> new path):'
foreach ($name in $allNames) {
    $cat = Get-CategoryObject -Name $name
    $count = @($torrents | Where-Object { $_.category -eq $name }).Count
    '  {0,-14} {1}  ->  {2}/{0}   ({3} torrent(s))' -f $name, $cat.savePath, $NewRoot, $count
}
Write-Host ''

if ($busy.Count -gt 0) {
    $busy | Format-Table name, state -AutoSize | Out-String | Write-Host
    throw 'A torrent is downloading, moving, or checking. Try again when all torrents only seed.'
}
if (-not $Apply) {
    Write-Host 'Dry run: nothing was changed. Add -Apply to make the change.'
    return
}

# --- Step 2: backup ------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$backupFile = Join-Path $BackupDir "qbit-categories-backup-$stamp.json"
[pscustomobject]@{
    categories = Get-QbitData -Path 'torrents/categories'
    torrents   = $torrents
} | ConvertTo-Json -Depth 6 | Set-Content -Path $backupFile -Encoding utf8
Write-Host "Backup written: $backupFile"

# --- Step 3: turn the move-on-category-change preference OFF --------------
Set-MoveOnCategoryChange -Enabled $false
Write-Host 'category_changed_tmm_enabled is OFF.'

# --- Step 4: canary ------------------------------------------------------
$canaryBefore = Get-CategoryObject -Name $CanaryCategory
Set-CategoryPath -Name $CanaryCategory -SavePath "$NewRoot/$CanaryCategory"
Wait-NoMovingTorrent
$canaryAfter = Get-CategoryObject -Name $CanaryCategory
if ((Get-CategoryFingerprint $canaryBefore) -ne (Get-CategoryFingerprint $canaryAfter)) {
    throw "Canary: a field other than savePath changed. Before: $(Get-CategoryFingerprint $canaryBefore) After: $(Get-CategoryFingerprint $canaryAfter). Stop. The preference is still OFF."
}
$problems = Test-TorrentsInPlace -Before $torrents -Categories @($CanaryCategory)
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "  PROBLEM: $_" }
    throw 'Canary failed. Stop. The preference is still OFF. Do not change other categories.'
}
Write-Host "Canary '$CanaryCategory' OK: torrent in place, manual mode, other fields unchanged."

# --- Step 5: the other categories ----------------------------------------
foreach ($name in $OtherCategory) {
    $before = Get-CategoryObject -Name $name
    Set-CategoryPath -Name $name -SavePath "$NewRoot/$name"
    $after = Get-CategoryObject -Name $name
    if ((Get-CategoryFingerprint $before) -ne (Get-CategoryFingerprint $after)) {
        throw "Category '$name': a field other than savePath changed. Stop. The preference is still OFF."
    }
    Write-Host "Category '$name' changed."
}
Wait-NoMovingTorrent
$problems = Test-TorrentsInPlace -Before $torrents -Categories $allNames
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "  PROBLEM: $_" }
    throw 'Check after the change failed. Stop. The preference is still OFF.'
}
Write-Host "All $($torrents.Count) torrents are in place."

# --- Step 6: turn the preference ON again --------------------------------
Set-MoveOnCategoryChange -Enabled $true
Write-Host 'category_changed_tmm_enabled is ON again.'
Write-Host ''
Write-Host 'Final categories:'
foreach ($name in $allNames) {
    '  {0,-14} {1}' -f $name, (Get-CategoryObject -Name $name).savePath
}
Write-Host "Rollback data: $backupFile"
