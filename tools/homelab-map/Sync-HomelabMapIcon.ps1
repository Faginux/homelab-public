#Requires -Version 7.0
<#
  Sync-HomelabMapIcon.ps1  -  v1.0  (2026-10-20)
  Downloads the icons of docs/map/icons/icons.psd1 from the pinned commits of
  their source repositories into docs/map/icons.

  Each file goes to a temporary directory first. The script rejects an SVG with
  active content (script, event handler, javascript: URL, foreignObject,
  external link or external CSS) and a PNG with no PNG signature. Only a
  file that passes goes into docs/map/icons. The script does not delete
  files: a file that is not in the manifest gets the status "not-in-manifest".

  Tests:  -WhatIf   download and check, but do not write into docs/map/icons

  Created with Claude Code (Anthropic).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath  = (Join-Path $PSScriptRoot '..\..\docs\map\icons\icons.psd1'),
    [string]$IconDirectory = (Join-Path $PSScriptRoot '..\..\docs\map\icons'),
    [int]$MaxBytes         = 200KB
)

$ErrorActionPreference = 'Stop'

# Active content that has no place in an icon. The map embeds the icons in the
# drawing and in the exported SVG, and a browser can open both.
$UnsafeSvgPattern = '(?i)<script|\son[a-z]+\s*=|javascript:|<foreignObject|(xlink:)?href\s*=\s*["'']\s*https?:|url\(\s*["'']?\s*https?:|@import'

$manifest = Import-PowerShellDataFile -LiteralPath $ManifestPath
$staging  = Join-Path ([System.IO.Path]::GetTempPath()) "homelab-map-icons-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging | Out-Null

try {
    foreach ($icon in $manifest.Icons) {
        $source   = $manifest.Sources[$icon.Source]
        $fileName = "$($icon.Name).$($icon.Format)"
        $result   = [ordered]@{ Name = $icon.Name; Status = $null; Source = $icon.Source; Bytes = 0; Detail = $null }

        if (-not $source) {
            $result.Status = 'rejected'; $result.Detail = "unknown source '$($icon.Source)'"
            [pscustomobject]$result; continue
        }

        $path   = $source.PathFormat -f $icon.File, $icon.Format
        $uri    = "https://raw.githubusercontent.com/$($source.Repository)/$($source.Commit)/$path"
        $staged = Join-Path $staging $fileName
        try {
            Invoke-WebRequest -Uri $uri -OutFile $staged -TimeoutSec 30 | Out-Null
        }
        catch {
            $result.Status = 'rejected'; $result.Detail = "download failed: $($_.Exception.Message)"
            [pscustomobject]$result; continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($staged)
        $result.Bytes = $bytes.Length
        if ($bytes.Length -gt $MaxBytes) {
            $result.Status = 'rejected'; $result.Detail = "larger than $MaxBytes bytes"
            [pscustomobject]$result; continue
        }
        if ($icon.Format -eq 'svg') {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($text -notmatch '<svg[\s>]') {
                $result.Status = 'rejected'; $result.Detail = 'no <svg> element'
                [pscustomobject]$result; continue
            }
            $unsafe = [regex]::Match($text, $UnsafeSvgPattern)
            if ($unsafe.Success) {
                $result.Status = 'rejected'; $result.Detail = "active content: '$($unsafe.Value)'"
                [pscustomobject]$result; continue
            }
        }
        elseif ($icon.Format -eq 'png') {
            $signature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
            if ($bytes.Length -lt 8 -or (Compare-Object $signature $bytes[0..7])) {
                $result.Status = 'rejected'; $result.Detail = 'no PNG signature'
                [pscustomobject]$result; continue
            }
        }
        else {
            $result.Status = 'rejected'; $result.Detail = "unknown format '$($icon.Format)'"
            [pscustomobject]$result; continue
        }

        $target = Join-Path $IconDirectory $fileName
        if (Test-Path -LiteralPath $target) {
            $same = (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $staged).Hash
            $result.Status = if ($same) { 'same' } else { 'updated' }
        }
        else {
            $result.Status = 'added'
        }
        if ($result.Status -ne 'same' -and $PSCmdlet.ShouldProcess($target, "Write icon ($($result.Status))")) {
            Copy-Item -LiteralPath $staged -Destination $target -Force
        }
        [pscustomobject]$result
    }

    $known = @($manifest.Icons | ForEach-Object { "$($_.Name).$($_.Format)" })
    Get-ChildItem -LiteralPath $IconDirectory -File |
        Where-Object { $_.Extension -in '.svg', '.png' -and $_.Name -notin $known } |
        ForEach-Object { [pscustomobject]@{ Name = $_.BaseName; Status = 'not-in-manifest'; Source = $null; Bytes = $_.Length; Detail = 'not deleted' } }
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
