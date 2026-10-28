#Requires -Version 7.0
<#
  Export-HomelabMap.ps1  -  v1.1  (2026-10-26)
  Exports each page of docs/map/homelab-map.drawio to an SVG file in docs/map
  (homelab-map-<page>.svg) with the draw.io Desktop command line. Then it makes
  the poster (Export-HomelabPoster.ps1, -SkipPoster to skip it). README files
  show these SVG files. Run it after each change to the drawing or to the
  inventory, and commit the drawing and the SVG files together.

  The SVG keeps the links of the services. GitHub shows the SVG as an image,
  so the links work only when you open the SVG file itself in a browser.

  Needs draw.io Desktop (winget: JGraph.Draw).

  Created with Claude Code (Anthropic).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DrawingPath     = (Join-Path $PSScriptRoot '..\..\docs\map\homelab-map.drawio'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\docs\map'),
    [string]$DrawioPath      = (Join-Path $env:LOCALAPPDATA 'Programs\draw.io\draw.io.exe'),
    [switch]$SkipPoster
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DrawioPath)) {
    throw "draw.io Desktop not found at '$DrawioPath'. Install it with: winget install --id JGraph.Draw --exact"
}

$drawing = (Resolve-Path -LiteralPath $DrawingPath).Path
$pages   = @(([xml](Get-Content -LiteralPath $drawing -Raw)).SelectNodes('/mxfile/diagram'))

for ($index = 0; $index -lt $pages.Count; $index++) {
    $name   = $pages[$index].GetAttribute('name').ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $target = Join-Path ([System.IO.Path]::GetFullPath($OutputDirectory)) "homelab-map-$name.svg"
    if ($PSCmdlet.ShouldProcess($target, "Export page $($index + 1)")) {
        # draw.io is a GUI program: "&" does not wait for it. Start-Process -Wait does.
        # --page-index is 1-based. --theme light: the colours of the drawing, no dark-mode change.
        # --embed-svg-fonts false: the fonts make the file 3.5 times larger, the browser has a sans-serif font.
        $arguments = @(
            '--export', '--format', 'svg', '--page-index', ($index + 1), '--border', '20',
            '--theme', 'light', '--embed-svg-fonts', 'false', '--output', "`"$target`"", "`"$drawing`""
        )
        $process = Start-Process -FilePath $DrawioPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $target)) {
            throw "draw.io export of page $($index + 1) failed (exit code $($process.ExitCode))"
        }
        [pscustomobject]@{ Page = $pages[$index].GetAttribute('name'); File = $target; Bytes = (Get-Item -LiteralPath $target).Length }
    }
}

# The poster comes from the inventory, not from the drawing. It needs no draw.io.
if (-not $SkipPoster -and $PSCmdlet.ShouldProcess('homelab-poster.svg', 'Make the poster')) {
    $poster = & (Join-Path $PSScriptRoot 'Export-HomelabPoster.ps1') -OutputPath (Join-Path ([System.IO.Path]::GetFullPath($OutputDirectory)) 'homelab-poster.svg')
    [pscustomobject]@{ Page = 'Poster'; File = $poster.File; Bytes = $poster.Bytes }
}
