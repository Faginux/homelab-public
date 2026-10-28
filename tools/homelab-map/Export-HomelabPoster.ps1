#Requires -Version 7.0
<#
  Export-HomelabPoster.ps1  -  v1.0  (2026-10-26)
  Makes docs/map/homelab-poster.svg: one page with all the homelab, in the
  style of a poster. The data comes from the inventory (docs/map/inventory.psd1),
  the icons from docs/map/icons, the colours from the theme of HomelabMap.psm1.
  The pages of homelab-map.drawio keep the details (routes, media flow).

  The layout of the poster, from the top:
    header   title and four numbers (hosts, RAM, containers, routes)
    network  the chain of Hosts links to the router (ISP, ONT), the router,
             then the switch and the Wi-Fi
    access   one chip for each kind of route, with the number of routes
    hosts    one card for each server: hardware, then the services by kind
             (containers, bare metal, jobs, Scheduled Tasks)
    backup   the jobs of Backups, under the host of Layout.Poster.BackupUnder
    pipeline the steps of Layout.Poster.Pipeline, in the shortest column
    devices  the clients and devices, in one row
    footer   date and source
  The last card of each column becomes taller, so that the columns end on one line.

  The SVG has the SHA-256 of the inventory in a comment. Test-HomelabMap.ps1
  compares it with the inventory: an old poster gives a warning.

  The poster is public (2026-10-26): it shows no IP address and no path.
  -ShowAddress  adds the LAN and tailnet addresses, for a private copy. Do not
                write that copy into the repo.

  Read only, except for the output file. Needs no network and no draw.io.

  Created with Claude Code (Anthropic).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot '..\..\docs\map\inventory.psd1'),
    [string]$IconDirectory = (Join-Path $PSScriptRoot '..\..\docs\map\icons'),
    [string]$OutputPath    = (Join-Path $PSScriptRoot '..\..\docs\map\homelab-poster.svg'),
    [switch]$ShowAddress
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HomelabMap.psm1') -Force

$Theme     = Get-HomelabTheme
$LightTile = Get-HomelabLightTileIcon -IconDirectory $IconDirectory
$inventory = Import-HomelabInventory -Path $InventoryPath

# Sizes in pixels. Three columns: two wide, one narrow.
$Width       = 1460
$Margin      = 50
$ColumnGap   = 30
$ColumnWidth = @(460, 460, 380)
$CardFill    = '#10303F'
$Sans        = "'Segoe UI', Inter, 'Helvetica Neue', Arial, sans-serif"
$Mono        = "'Cascadia Mono', Consolas, 'DejaVu Sans Mono', monospace"
$TileHeight  = 70
$TileGap     = 8

$svg = [System.Text.StringBuilder]::new()
$script:CardFrame = [System.Collections.Generic.List[object]]::new()

function ConvertTo-XmlText {
    [CmdletBinding()]
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function Get-TextWidth {
    <# Approximate width of a text. The SVG has no font metrics, so the factor is an average. #>
    [CmdletBinding()]
    param([string]$Text, [double]$Size, [switch]$Bold, [switch]$Monospace, [double]$Spacing = 0)

    $factor = if ($Monospace) { 0.6 } elseif ($Bold) { 0.52 } else { 0.5 }
    return $Text.Length * ($Size * $factor + $Spacing)
}

function Get-FitText {
    <# Cuts a text with an ellipsis, so that it fits in MaxWidth. #>
    [CmdletBinding()]
    param([string]$Text, [double]$Size, [double]$MaxWidth, [switch]$Bold, [switch]$Monospace, [double]$Spacing = 0)

    $measure = @{ Size = $Size; Bold = $Bold; Monospace = $Monospace; Spacing = $Spacing }
    if ((Get-TextWidth -Text $Text @measure) -le $MaxWidth) { return $Text }
    $cut = $Text
    while ($cut.Length -gt 1 -and (Get-TextWidth -Text "$cut…" @measure) -gt $MaxWidth) { $cut = $cut.Substring(0, $cut.Length - 1) }
    return "$($cut.TrimEnd())…"
}

function Get-FitSize {
    <# The largest font size from Sizes that fits the text in MaxWidth, else the smallest. #>
    [CmdletBinding()]
    param([string]$Text, [double]$MaxWidth, [double[]]$Sizes = @(12, 11, 10), [switch]$Bold)

    foreach ($size in $Sizes) {
        if ((Get-TextWidth -Text $Text -Size $size -Bold:$Bold) -le $MaxWidth) { return $size }
    }
    return $Sizes[-1]
}

function Add-Text {
    [CmdletBinding()]
    param(
        [double]$X, [double]$Y, [string]$Text, [double]$Size = 14, [string]$Color = $Theme.Text,
        [string]$Weight = '400', [ValidateSet('start', 'middle', 'end')][string]$Anchor = 'start',
        [switch]$Monospace, [double]$Spacing = 0, [double]$Opacity = 1
    )

    $family = if ($Monospace) { $Mono } else { $Sans }
    $extra  = ''
    if ($Spacing) { $extra += " letter-spacing=`"$Spacing`"" }
    if ($Opacity -lt 1) { $extra += " opacity=`"$Opacity`"" }
    [void]$svg.AppendLine("<text x=`"$X`" y=`"$Y`" font-family=`"$family`" font-size=`"$Size`" font-weight=`"$Weight`" fill=`"$Color`" text-anchor=`"$Anchor`"$extra>$(ConvertTo-XmlText $Text)</text>")
}

function Add-Box {
    [CmdletBinding()]
    param(
        [double]$X, [double]$Y, [double]$Width, [double]$Height, [double]$Radius = 10,
        [string]$Fill = 'none', [string]$Stroke = 'none', [double]$StrokeWidth = 1,
        [string]$Dash = '', [double]$Opacity = 1
    )

    $extra = ''
    if ($Dash) { $extra += " stroke-dasharray=`"$Dash`"" }
    if ($Opacity -lt 1) { $extra += " opacity=`"$Opacity`"" }
    [void]$svg.AppendLine("<rect x=`"$X`" y=`"$Y`" width=`"$Width`" height=`"$Height`" rx=`"$Radius`" fill=`"$Fill`" stroke=`"$Stroke`" stroke-width=`"$StrokeWidth`"$extra/>")
}

function Add-Line {
    [CmdletBinding()]
    param([double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [string]$Color = $Theme.TileBorder, [double]$Width = 1.5)
    [void]$svg.AppendLine("<line x1=`"$X1`" y1=`"$Y1`" x2=`"$X2`" y2=`"$Y2`" stroke=`"$Color`" stroke-width=`"$Width`"/>")
}

function Add-Arrow {
    <# A horizontal arrow from X1 to X2 at Y. #>
    [CmdletBinding()]
    param([double]$X1, [double]$X2, [double]$Y, [string]$Color = $Theme.Primary)
    Add-Line -X1 $X1 -Y1 $Y -X2 ($X2 - 2) -Y2 $Y -Color $Color -Width 2
    [void]$svg.AppendLine("<path d=`"M $($X2 - 9) $($Y - 5) L $X2 $Y L $($X2 - 9) $($Y + 5)`" fill=`"none`" stroke=`"$Color`" stroke-width=`"2`"/>")
}

function Get-Initial {
    <#
    Two letters for an item with no icon: the first letter and the next capital
    (tinyMediaManager -> TM, NoMachine -> NM), else the first two letters.
    #>
    [CmdletBinding()]
    param([string]$Name)

    $clean    = ($Name -replace '\(.*\)', '').Trim()
    $capitals = -join ($clean.Substring(1).ToCharArray() | Where-Object { [char]::IsUpper($_) })
    if ($capitals.Length -ge 1) { return ($clean.Substring(0, 1) + $capitals.Substring(0, 1)).ToUpperInvariant() }
    return $clean.Substring(0, [math]::Min(2, $clean.Length)).ToUpperInvariant()
}

function Add-Icon {
    <#
    An icon of docs/map/icons in a square of Size. A dark icon (Tile = 'light')
    gets a light square behind it. With no icon file: two letters in a frame.
    #>
    [CmdletBinding()]
    param([string]$Name, [string]$Label, [double]$X, [double]$Y, [double]$Size, [string]$Color = $Theme.Accent)

    $uri = if ($Name) { Get-HomelabIconDataUri -IconDirectory $IconDirectory -Name $Name } else { $null }
    if (-not $uri) {
        Add-Box -X $X -Y $Y -Width $Size -Height $Size -Radius ($Size / 4) -Stroke $Color -StrokeWidth 1.5
        Add-Text -X ($X + $Size / 2) -Y ($Y + $Size * 0.66) -Text (Get-Initial -Name $Label) -Size ($Size * 0.42) -Color $Color -Weight '700' -Anchor middle -Monospace
        return
    }
    # SVG wants ";base64," in a data URI. The module gives the draw.io form (no ";base64").
    $href = $uri -replace '^data:([^,]+),', 'data:$1;base64,'
    if ($LightTile.ContainsKey($Name)) {
        $pad = [math]::Round($Size * 0.12)
        Add-Box -X ($X - $pad) -Y ($Y - $pad) -Width ($Size + 2 * $pad) -Height ($Size + 2 * $pad) -Radius ($Size / 4) -Fill $Theme.LightTile
    }
    [void]$svg.AppendLine("<image x=`"$X`" y=`"$Y`" width=`"$Size`" height=`"$Size`" preserveAspectRatio=`"xMidYMid meet`" href=`"$href`"/>")
}

function Add-WifiMark {
    <# A Wi-Fi mark: a dot and two arcs, in a square of Size. #>
    [CmdletBinding()]
    param([double]$X, [double]$Y, [double]$Size, [string]$Color)

    $cx = $X + $Size / 2
    $cy = $Y + $Size * 0.8
    [void]$svg.AppendLine("<circle cx=`"$cx`" cy=`"$cy`" r=`"$($Size * 0.07)`" fill=`"$Color`"/>")
    foreach ($radius in @(($Size * 0.3), ($Size * 0.55))) {
        $dx = [math]::Round($radius * 0.7071, 2)
        [void]$svg.AppendLine("<path d=`"M $($cx - $dx) $($cy - $dx) A $radius $radius 0 0 1 $($cx + $dx) $($cy - $dx)`" fill=`"none`" stroke=`"$Color`" stroke-width=`"$([math]::Max(2, $Size * 0.08))`" stroke-linecap=`"round`"/>")
    }
}

function Get-ShortName {
    <# The name of a service on a tile: no "(host)" part, because the card names the host. #>
    [CmdletBinding()]
    param([string]$Name)
    return ($Name -replace '\s*\(.*\)\s*$', '').Trim()
}

function Get-ServiceStopped {
    [CmdletBinding()]
    param([hashtable]$Service)
    $containers = @($Service.Containers | Where-Object { $_ })
    return ($containers.Count -gt 0 -and @($containers | Where-Object { $_.State -eq 'stopped' }).Count -eq $containers.Count)
}

function Add-ServiceGrid {
    <# The tiles of a group of services. Returns the Y below the grid. #>
    [CmdletBinding()]
    param([object[]]$Service, [double]$X, [double]$Y, [double]$Width, [int]$PerRow, [string]$Accent)

    $tileWidth = ($Width - ($PerRow - 1) * $TileGap) / $PerRow
    for ($index = 0; $index -lt $Service.Count; $index++) {
        $item    = $Service[$index]
        $tileX   = $X + ($index % $PerRow) * ($tileWidth + $TileGap)
        $tileY   = $Y + [math]::Floor($index / $PerRow) * ($TileHeight + $TileGap)
        $stopped = Get-ServiceStopped -Service $item
        $count   = @($item.Containers | Where-Object { $_ }).Count
        $name    = Get-ShortName -Name $item.Name
        $suffix  = if ($count -gt 1) { " ×$count" } else { '' }
        $size    = Get-FitSize -Text "$name$suffix" -MaxWidth ($tileWidth - 8) -Bold
        $label   = Get-FitText -Text "$name$suffix" -Size $size -MaxWidth ($tileWidth - 8) -Bold

        $dash    = if ($stopped) { '4 3' } else { '' }
        $opacity = if ($stopped) { 0.5 } else { 1 }
        [void]$svg.AppendLine("<g opacity=`"$opacity`">")
        Add-Box -X $tileX -Y $tileY -Width $tileWidth -Height $TileHeight -Radius 8 -Fill $Theme.Panel -Stroke $Theme.TileBorder -Dash $dash
        Add-Icon -Name $item.Icon -Label $item.Name -X ($tileX + $tileWidth / 2 - 15) -Y ($tileY + 10) -Size 30 -Color $Accent
        Add-Text -X ($tileX + $tileWidth / 2) -Y ($tileY + 59) -Text $label -Size $size -Weight '600' -Anchor middle
        [void]$svg.AppendLine('</g>')
    }
    $rows = [math]::Ceiling($Service.Count / $PerRow)
    return $Y + $rows * ($TileHeight + $TileGap) - $TileGap
}

function Add-SectionLabel {
    [CmdletBinding()]
    param([double]$X, [double]$Y, [string]$Text, [string]$Color)
    Add-Text -X $X -Y $Y -Text $Text.ToUpperInvariant() -Size 12 -Color $Color -Weight '700' -Monospace -Spacing 2
}

function Add-HostCard {
    <# One card for a server: name, hardware, then its services by kind. Returns the height of the card. #>
    [CmdletBinding()]
    param([hashtable]$Item, [double]$X, [double]$Y, [double]$Width, [string]$Accent, [int]$PerRow)

    $pad    = 22
    $inner  = $Width - 2 * $pad
    $start  = $svg.Length
    $cursor = $Y + 34

    # Header: OS / tagline, name, OS icon. The label stops before the icon.
    $label = (@(($Item.Os -replace '\s*\(.*\)', ''), $Item.Tagline) | Where-Object { $_ }) -join ' / '
    $label = Get-FitText -Text $label.ToUpperInvariant() -Size 12 -MaxWidth ($inner - 56) -Monospace -Spacing 2
    Add-Box -X ($X - 1) -Y ($Y + 20) -Width 4 -Height 20 -Radius 1 -Fill $Accent
    Add-SectionLabel -X ($X + $pad) -Y $cursor -Text $label -Color $Accent
    $main = ($Item.Name -replace '\s*\(.*\)\s*$', '').Trim()
    $sub  = if ($Item.Name -match '\((.*)\)') { $Matches[1] } else { '' }
    $cursor += 44
    Add-Text -X ($X + $pad) -Y $cursor -Text $main -Size 40 -Weight '800'
    if ($sub) { Add-Text -X ($X + $pad + (Get-TextWidth -Text $main -Size 40 -Bold) + 12) -Y $cursor -Text $sub -Size 17 -Color $Theme.Muted }
    if ($Item.Icon) { Add-Icon -Name $Item.Icon -Label $Item.Name -X ($X + $Width - $pad - 40) -Y ($Y + 24) -Size 40 }

    $hardware = $Item.Hardware
    if ($hardware) {
        # One line if it fits, else the CPU on a line and the cores and the RAM below.
        $cursor += 30
        $ram   = if ($hardware.RamGb) { "$($hardware.RamGb) GB RAM" } else { $null }
        $facts = (@($hardware.Cpu, $hardware.Cores, $ram) | Where-Object { $_ }) -join ' · '
        $lines = @(if ((Get-TextWidth -Text $facts -Size 15) -le $inner) { $facts } else { $hardware.Cpu; ((@($hardware.Cores, $ram) | Where-Object { $_ }) -join ' · ') })
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($index -gt 0) { $cursor += 21 }
            Add-Text -X ($X + $pad) -Y $cursor -Text (Get-FitText -Text $lines[$index] -Size 15 -MaxWidth $inner) -Size 15 -Color $Theme.Muted
        }
    }
    if ($ShowAddress -and ($Item.Lan -or $Item.Tailnet)) {
        $cursor += 22
        $address = @($(if ($Item.Lan) { "LAN $($Item.Lan)" }), $(if ($Item.Tailnet) { "TAILNET $($Item.Tailnet)" })) | Where-Object { $_ }
        Add-Text -X ($X + $pad) -Y $cursor -Text ($address -join '  ·  ') -Size 11.5 -Color $Theme.Muted -Monospace -Opacity 0.85
    }

    # Hardware box: GPU and disks, one row each.
    $rows = @()
    if ($hardware.Gpu) { $rows += @{ Label = 'GPU'; Value = $hardware.Gpu } }
    foreach ($disk in @($hardware.Disks | Where-Object { $_ })) { $rows += $disk }
    if ($rows.Count -gt 0) {
        $cursor += 16
        $boxHeight = 14 + $rows.Count * 24
        Add-Box -X ($X + $pad) -Y $cursor -Width $inner -Height $boxHeight -Radius 8 -Stroke $Theme.TileBorder
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $rowY = $cursor + 26 + $index * 24
            Add-Text -X ($X + $pad + 14) -Y $rowY -Text $rows[$index].Label -Size 13 -Color $Accent -Monospace
            Add-Text -X ($X + $pad + 118) -Y $rowY -Text (Get-FitText -Text $rows[$index].Value -Size 14 -MaxWidth ($inner - 130)) -Size 14
        }
        $cursor += $boxHeight
    }

    # Services by kind. Scheduled Tasks are chips, the other kinds are tiles.
    $services = @($inventory.Services | Where-Object { $_.Host -eq $Item.Id })
    $groups   = [ordered]@{ container = 'Containers'; baremetal = 'Bare metal'; job = 'Jobs · run --rm' }
    foreach ($kind in $groups.Keys) {
        $members = @($services | Where-Object { $_.Kind -eq $kind })
        if ($members.Count -eq 0) { continue }
        $cursor += 32
        Add-SectionLabel -X ($X + $pad) -Y $cursor -Text $groups[$kind] -Color $Accent
        if ($kind -eq 'container') { Add-Icon -Name 'docker' -Label 'Docker' -X ($X + $Width - $pad - 20) -Y ($cursor - 15) -Size 20 }
        $cursor = Add-ServiceGrid -Service $members -X ($X + $pad) -Y ($cursor + 12) -Width $inner -PerRow $PerRow -Accent $Accent
    }
    $tasks = @($services | Where-Object { $_.Kind -eq 'task' })
    if ($tasks.Count -gt 0) {
        $cursor += 32
        Add-SectionLabel -X ($X + $pad) -Y $cursor -Text 'Scheduled Tasks' -Color $Theme.Task
        $chipX = $X + $pad
        $chipY = $cursor + 12
        foreach ($task in $tasks) {
            $chipWidth = (Get-TextWidth -Text $task.Name -Size 12.5 -Bold) + 26
            if ($chipX + $chipWidth -gt $X + $Width - $pad) { $chipX = $X + $pad; $chipY += 38 }
            Add-Box -X $chipX -Y $chipY -Width $chipWidth -Height 30 -Radius 15 -Fill $Theme.Panel -Stroke $Theme.Task -StrokeWidth 1.5 -Dash '5 3'
            Add-Text -X ($chipX + $chipWidth / 2) -Y ($chipY + 20) -Text $task.Name -Size 12.5 -Weight '600' -Anchor middle
            $chipX += $chipWidth + 8
        }
        $cursor = $chipY + 30
    }

    return Add-CardFrame -Start $start -X $X -Y $Y -Width $Width -Height ($cursor + $pad - $Y) -Stroke $Theme.Group
}

function Add-CardFrame {
    <#
    Puts the frame of a card before its content (Start = the length of the SVG
    text when the card began), so that the content is on top. The height is a
    token: the layout can make the card taller later (Set-CardHeight).
    Returns @{ Token; Y; Height }.
    #>
    [CmdletBinding()]
    param([int]$Start, [double]$X, [double]$Y, [double]$Width, [double]$Height, [string]$Stroke = $Theme.TileBorder)

    $token = "@@CARD$($script:CardFrame.Count)@@"
    [void]$svg.Insert($Start, "<rect x=`"$X`" y=`"$Y`" width=`"$Width`" height=`"$token`" rx=`"14`" fill=`"$CardFill`" stroke=`"$Stroke`" stroke-width=`"1.5`"/>`n")
    $card = @{ Token = $token; Y = $Y; Height = $Height }
    $script:CardFrame.Add($card)
    return $card
}

function Get-HostShortName {
    <# The name of a host with no "(...)" part: "the-grid" -> "the-grid". #>
    [CmdletBinding()]
    param([string]$Id)
    $item = $inventory.Hosts | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $item) { return $Id }
    return ($item.Name -replace '\s*\(.*\)\s*$', '').Trim()
}

function Add-BackupCard {
    <# The card "Backup": one row for each job of Backups, in the order of the inventory. #>
    [CmdletBinding()]
    param([double]$X, [double]$Y, [double]$Width)

    $backups = @($inventory['Backups'] | Where-Object { $_ })
    if ($backups.Count -eq 0) { return $null }
    $pad   = 22
    $color = $Theme.Private
    $start = $svg.Length
    Add-Box -X ($X - 1) -Y ($Y + 20) -Width 4 -Height 20 -Radius 1 -Fill $color
    Add-SectionLabel -X ($X + $pad) -Y ($Y + 34) -Text 'Backup' -Color $color
    Add-Text -X ($X + $Width - $pad) -Y ($Y + 34) -Text 'TIMES: EUROPE/ROME' -Size 10.5 -Color $Theme.Muted -Anchor end -Monospace -Spacing 1
    $cursor = $Y + 50
    $textX  = $X + $pad + 122
    foreach ($backup in $backups) {
        Add-Text -X ($X + $pad) -Y ($cursor + 17) -Text $backup.Schedule.ToUpperInvariant() -Size 11.5 -Color $color -Weight '700' -Monospace
        Add-Text -X $textX -Y ($cursor + 17) -Text (Get-FitText -Text $backup.Name -Size 14 -MaxWidth ($X + $Width - $pad - 60 - $textX) -Bold) -Size 14 -Weight '600'
        # A copy on the same host: "on the-grid". A copy to another host: "the-grid → ARCADE".
        $route = if ($backup.From -eq $backup.To) { "on $(Get-HostShortName -Id $backup.From)" } else { "$(Get-HostShortName -Id $backup.From) → $(Get-HostShortName -Id $backup.To)" }
        if ($backup.Detail) { $route += " · $($backup.Detail)" }
        $reserve = if ($backup.Retention) { 70 } else { 0 }
        Add-Text -X $textX -Y ($cursor + 35) -Text (Get-FitText -Text $route -Size 12 -MaxWidth ($X + $Width - $pad - $reserve - $textX)) -Size 12 -Color $Theme.Muted
        if ($backup.Encrypted) {
            Add-Box -X ($X + $Width - $pad - 38) -Y ($cursor + 4) -Width 38 -Height 18 -Radius 9 -Stroke $color
            Add-Text -X ($X + $Width - $pad - 19) -Y ($cursor + 17) -Text 'age' -Size 11 -Color $color -Weight '700' -Anchor middle -Monospace
        }
        if ($backup.Retention) {
            Add-Text -X ($X + $Width - $pad) -Y ($cursor + 35) -Text $backup.Retention -Size 11 -Color $Theme.Muted -Anchor end -Monospace
        }
        $cursor += 48
    }
    return Add-CardFrame -Start $start -X $X -Y $Y -Width $Width -Height ($cursor - $Y + $pad - 12)
}

function Add-DeviceStrip {
    <# The clients and devices in one row, across the poster. Returns the height. #>
    [CmdletBinding()]
    param([double]$X, [double]$Y, [double]$Width)

    $devices = @($inventory.Hosts | Where-Object { $_.Kind -in 'client', 'device' })
    if ($devices.Count -eq 0) { return 0 }
    $pad   = 22
    $start = $svg.Length
    Add-Box -X ($X - 1) -Y ($Y + 20) -Width 4 -Height 20 -Radius 1 -Fill $Theme.Primary
    Add-SectionLabel -X ($X + $pad) -Y ($Y + 34) -Text 'Clients + devices' -Color $Theme.Primary
    $slot = ($Width - 2 * $pad) / $devices.Count
    for ($index = 0; $index -lt $devices.Count; $index++) {
        $device = $devices[$index]
        $slotX  = $X + $pad + $index * $slot
        $uplink = Get-UplinkName -Id $device.Uplink
        if ($device.Tailnet) { $uplink += ' · TAILNET' }
        Add-Icon -Name $device.Icon -Label $device.Name -X $slotX -Y ($Y + 54) -Size 28 -Color $Theme.Primary
        $size = Get-FitSize -Text $device.Name -MaxWidth ($slot - 52) -Sizes @(14, 13, 12) -Bold
        Add-Text -X ($slotX + 40) -Y ($Y + 67) -Text (Get-FitText -Text $device.Name -Size $size -MaxWidth ($slot - 52) -Bold) -Size $size -Weight '600'
        Add-Text -X ($slotX + 40) -Y ($Y + 85) -Text $uplink -Size 10.5 -Color $Theme.Muted -Monospace
    }
    $height = 108
    [void]$svg.Insert($start, "<rect x=`"$X`" y=`"$Y`" width=`"$Width`" height=`"$height`" rx=`"14`" fill=`"$CardFill`" stroke=`"$($Theme.TileBorder)`" stroke-width=`"1.5`"/>`n")
    return $height
}

function Add-PipelineCard {
    <#
    The card "Media pipeline": the steps of Layout.Poster.Pipeline from the top
    to the bottom, each with its services. Returns the height, or 0 with no steps.
    #>
    [CmdletBinding()]
    param([double]$X, [double]$Y, [double]$Width)

    $steps = @($inventory.Layout['Poster'].Pipeline | Where-Object { $_ })
    if ($steps.Count -eq 0) { return $null }
    $pad   = 22
    $start = $svg.Length
    Add-Box -X ($X - 1) -Y ($Y + 20) -Width 4 -Height 20 -Radius 1 -Fill $Theme.Primary
    Add-SectionLabel -X ($X + $pad) -Y ($Y + 34) -Text 'Media pipeline' -Color $Theme.Primary
    $cursor = $Y + 52
    for ($index = 0; $index -lt $steps.Count; $index++) {
        if ($index -gt 0) {
            # A short yellow arrow down, under the step names.
            $arrowX = $X + $pad + 30
            Add-Line -X1 $arrowX -Y1 ($cursor - 12) -X2 $arrowX -Y2 ($cursor - 1) -Color $Theme.Primary -Width 1.5
            [void]$svg.AppendLine("<path d=`"M $($arrowX - 4) $($cursor - 5) L $arrowX $($cursor) L $($arrowX + 4) $($cursor - 5)`" fill=`"none`" stroke=`"$($Theme.Primary)`" stroke-width=`"1.5`"/>")
        }
        Add-Text -X ($X + $pad) -Y ($cursor + 20) -Text $steps[$index].Step.ToUpperInvariant() -Size 11 -Color $Theme.Muted -Weight '700' -Monospace -Spacing 1
        $itemX = $X + $pad + 96
        foreach ($id in @($steps[$index].Items)) {
            $service = $inventory.Services | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            $name    = Get-ShortName -Name $service.Name
            Add-Icon -Name $service.Icon -Label $service.Name -X $itemX -Y ($cursor + 3) -Size 24 -Color $Theme.Primary
            Add-Text -X ($itemX + 32) -Y ($cursor + 20) -Text $name -Size 13.5 -Weight '600'
            $itemX += 32 + (Get-TextWidth -Text $name -Size 13.5 -Bold) + 22
        }
        $cursor += 44
    }
    return Add-CardFrame -Start $start -X $X -Y $Y -Width $Width -Height ($cursor - $Y + $pad - 14)
}

function Get-UplinkName {
    [CmdletBinding()]
    param([string]$Id)
    $node = @($inventory.Nodes) + @($inventory.Hosts) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $node) { return '' }
    if ($node.Kind -eq 'wireless') { return 'WI-FI' }
    if ($node.Kind -eq 'network') { return 'SWITCH' }
    return $node.Name.ToUpperInvariant()
}

# --- Data for the header and the network ---

$servers    = @($inventory.Hosts | Where-Object { $_.Kind -eq 'server' })
$laneOrder  = @($inventory.Layout.Edge.Lanes)
$servers    = @($servers | Sort-Object { $index = [array]::IndexOf($laneOrder, $_.Id); if ($index -lt 0) { 99 } else { $index } })
$ramTotal   = ($servers | ForEach-Object { [int]$_.Hardware.RamGb } | Measure-Object -Sum).Sum
$containers = ($inventory.Services | ForEach-Object { @($_.Containers | Where-Object { $_ }).Count } | Measure-Object -Sum).Sum
$allItems   = @($inventory.Hosts) + @($inventory.Nodes)
# The router: a network host with no Uplink that is the Uplink of other items.
$router     = $inventory.Hosts | Where-Object { $_.Kind -eq 'network' -and -not $_.Uplink -and ($allItems.Uplink -contains $_.Id) } | Select-Object -First 1
$switch     = $inventory.Hosts | Where-Object { $_.Kind -eq 'network' -and $_.Uplink -eq $router.Id } | Select-Object -First 1
$wifi       = $inventory.Nodes | Where-Object { $_.Kind -eq 'wireless' } | Select-Object -First 1
$cloudflare = $inventory.Nodes | Where-Object { $_.Id -eq 'cloudflare' } | Select-Object -First 1
$tailscale  = $inventory.Nodes | Where-Object { $_.Id -eq 'tailscale' } | Select-Object -First 1
$routeKind  = @{}
foreach ($route in $inventory.Routes) {
    $key = if ($route.Via -eq 'direct') { 'direct' } else { $route.Exposure }
    $routeKind[$key] = 1 + [int]$routeKind[$key]
}

# The chain of Hosts links that ends at the router (ISP -> ONT), with no cloud.
$chain   = [System.Collections.Generic.List[object]]::new()
$current = $router.Id
while ($true) {
    $link = $inventory.Links | Where-Object { $_.View -eq 'Hosts' -and $_.To -eq $current } | Select-Object -First 1
    if (-not $link) { break }
    $item = $allItems | Where-Object { $_.Id -eq $link.From } | Select-Object -First 1
    if (-not $item -or $item.Shape -eq 'cloud' -or $chain.Contains($item)) { break }
    $chain.Insert(0, $item)
    $current = $item.Id
}
$chain.Add($router)

# --- Header ---

$y = 40
Add-Box -X $Margin -Y ($y + 6) -Width 36 -Height 3 -Radius 1 -Fill $Theme.Primary
Add-Text -X ($Margin + 50) -Y ($y + 12) -Text 'ARCADE · HOMELAB' -Size 12 -Color $Theme.Muted -Weight '700' -Monospace -Spacing 2
Add-Text -X ($Margin - 3) -Y ($y + 82) -Text 'Homelab' -Size 68 -Weight '800'

$stats = @(
    @{ Value = $servers.Count; Label = 'HOSTS'; Color = $Theme.Primary }
    @{ Value = $ramTotal; Label = 'GB RAM'; Color = $Theme.Text }
    @{ Value = $containers; Label = 'CONTAINERS'; Color = $Theme.Text }
    @{ Value = @($inventory.Routes).Count; Label = 'ROUTES'; Color = $Theme.Text }
)
for ($index = 0; $index -lt $stats.Count; $index++) {
    $statX = $Width - $Margin - (($stats.Count - 1 - $index) * 170) - 120
    Add-Text -X $statX -Y ($y + 60) -Text ('{0:00}' -f $stats[$index].Value) -Size 50 -Color $stats[$index].Color -Weight '700'
    Add-Text -X ($statX + 2) -Y ($y + 88) -Text $stats[$index].Label -Size 11 -Color $Theme.Muted -Weight '700' -Monospace -Spacing 2
}

# --- Network row: the chain to the router, then the switch and the Wi-Fi ---

$y          = 175
$rowHeight  = 84
$arrowGap   = 40
$groupWidth = 440
$cardWidth  = ($Width - 2 * $Margin - $groupWidth - $chain.Count * $arrowGap) / $chain.Count
$cardX      = $Margin
foreach ($item in $chain) {
    Add-Box -X $cardX -Y $y -Width $cardWidth -Height $rowHeight -Radius 12 -Fill $CardFill -Stroke $Theme.TileBorder -StrokeWidth 1.5
    Add-Icon -Name $item.Icon -Label $item.Name -X ($cardX + 20) -Y ($y + 22) -Size 40 -Color $Theme.Primary
    $titleSize = Get-FitSize -Text $item.Name -MaxWidth ($cardWidth - 90) -Sizes @(19, 17, 16) -Bold
    Add-Text -X ($cardX + 76) -Y ($y + 38) -Text (Get-FitText -Text $item.Name -Size $titleSize -MaxWidth ($cardWidth - 90) -Bold) -Size $titleSize -Weight '700'
    $sub = @($(if ($item.Detail) { $item.Detail } else { $item.Os }), $(if ($ShowAddress) { $item.Lan })) | Where-Object { $_ }
    Add-Text -X ($cardX + 76) -Y ($y + 61) -Text (Get-FitText -Text ($sub -join ' · ') -Size 13 -MaxWidth ($cardWidth - 90)) -Size 13 -Color $Theme.Muted
    Add-Arrow -X1 ($cardX + $cardWidth + 6) -X2 ($cardX + $cardWidth + $arrowGap - 6) -Y ($y + $rowHeight / 2)
    $cardX += $cardWidth + $arrowGap
}
$groupX = $cardX
Add-Box -X $groupX -Y $y -Width $groupWidth -Height $rowHeight -Radius 12 -Fill $CardFill -Stroke $Theme.TileBorder -StrokeWidth 1.5
$wifiCount = @($inventory.Hosts | Where-Object { $_.Uplink -eq $wifi.Id }).Count
$switchSub = if ($switch.Detail) { $switch.Detail.ToUpperInvariant() } else { 'SWITCH' }
$network = @(
    @{ Icon = $switch.Icon; Name = $switch.Name; Sub = $switchSub; Wifi = $false }
    @{ Icon = $null; Name = $wifi.Name; Sub = "WI-FI · $wifiCount DEVICES"; Wifi = $true }
)
$slot = ($groupWidth - 20) / $network.Count
for ($index = 0; $index -lt $network.Count; $index++) {
    $slotX = $groupX + 20 + $index * $slot
    if ($network[$index].Wifi) { Add-WifiMark -X $slotX -Y ($y + 22) -Size 36 -Color $Theme.Network }
    else { Add-Icon -Name $network[$index].Icon -Label $network[$index].Name -X $slotX -Y ($y + 24) -Size 34 }
    Add-Text -X ($slotX + 50) -Y ($y + 40) -Text (Get-FitText -Text $network[$index].Name -Size 16 -MaxWidth ($slot - 60) -Bold) -Size 16 -Weight '700'
    Add-Text -X ($slotX + 50) -Y ($y + 60) -Text (Get-FitText -Text $network[$index].Sub -Size 10.5 -MaxWidth ($slot - 60) -Monospace -Spacing 1) -Size 10.5 -Color $Theme.Muted -Weight '700' -Monospace -Spacing 1
}

# --- Access row: one chip for each kind of route ---

$busY = $y + $rowHeight + 22
$y    = $busY + 22
$chips = @(
    @{ Key = 'public-crowdsec';  Color = $Theme.Primary; Icon = $cloudflare.Icon; Text = 'Public · Cloudflare + CrowdSec' }
    @{ Key = 'tailnet-enforced'; Color = $Theme.Private; Icon = $tailscale.Icon;  Text = 'Tailnet only · remote_ip' }
    @{ Key = 'direct';           Color = $Theme.Accent;  Icon = $tailscale.Icon;  Text = 'Direct DNS · no Caddy' }
    @{ Key = 'dns-only';         Color = $Theme.Alarm;   Icon = $null;            Text = 'Private by DNS only' }
)
$chipWidth = ($Width - 2 * $Margin - ($chips.Count - 1) * 20) / $chips.Count
Add-Line -X1 ($groupX + $groupWidth / 2) -Y1 ($y - 44) -X2 ($groupX + $groupWidth / 2) -Y2 $busY
Add-Line -X1 ($Margin + $chipWidth / 2) -Y1 $busY -X2 ($Width - $Margin - $chipWidth / 2) -Y2 $busY
for ($index = 0; $index -lt $chips.Count; $index++) {
    $chipX = $Margin + $index * ($chipWidth + 20)
    $count = [int]$routeKind[$chips[$index].Key]
    $faded = if ($count -eq 0) { 0.45 } else { 1 }
    Add-Line -X1 ($chipX + $chipWidth / 2) -Y1 $busY -X2 ($chipX + $chipWidth / 2) -Y2 $y
    [void]$svg.AppendLine("<g opacity=`"$faded`">")
    Add-Box -X $chipX -Y $y -Width $chipWidth -Height 46 -Radius 10 -Fill $CardFill -Stroke $chips[$index].Color -StrokeWidth 1.5
    Add-Text -X ($chipX + 16) -Y ($y + 29) -Text ('{0:00}' -f $count) -Size 15 -Color $chips[$index].Color -Weight '700' -Monospace
    $textX = $chipX + 50
    if ($chips[$index].Icon) {
        Add-Icon -Name $chips[$index].Icon -Label $chips[$index].Text -X ($chipX + 50) -Y ($y + 12) -Size 22
        $textX = $chipX + 82
    }
    Add-Text -X $textX -Y ($y + 29) -Text $chips[$index].Text -Size 14.5 -Weight '600'
    [void]$svg.AppendLine('</g>')
}

# --- Host cards, the backup card and the pipeline card ---

$y          = $y + 46
$busY       = $y + 22
$cardsTop   = $busY + 22
$columnX    = @($Margin, ($Margin + $ColumnWidth[0] + $ColumnGap), ($Margin + $ColumnWidth[0] + $ColumnWidth[1] + 2 * $ColumnGap))
$accents    = @($Theme.Accent, $Theme.Secondary, $Theme.Private)
$columnEnd  = @($cardsTop, $cardsTop, $cardsTop)
$columnLast = @($null, $null, $null)
Add-Line -X1 ($columnX[0] + $ColumnWidth[0] / 2) -Y1 $busY -X2 ($columnX[2] + $ColumnWidth[2] / 2) -Y2 $busY
for ($index = 0; $index -lt [math]::Min(3, $servers.Count); $index++) {
    $centerX = $columnX[$index] + $ColumnWidth[$index] / 2
    Add-Line -X1 $centerX -Y1 $busY -X2 $centerX -Y2 $cardsTop
}
$columnOfHost = @{}
for ($index = 0; $index -lt $servers.Count; $index++) {
    $column = $index % 3
    $perRow = if ($ColumnWidth[$column] -ge 440) { 4 } else { 3 }
    $card   = Add-HostCard -Item $servers[$index] -X $columnX[$column] -Y $columnEnd[$column] -Width $ColumnWidth[$column] -Accent $accents[$column] -PerRow $perRow
    $columnEnd[$column] += $card.Height + $ColumnGap
    $columnLast[$column] = $card
    $columnOfHost[$servers[$index].Id] = $column
}

# The backup card goes under its host (Layout.Poster.BackupUnder), the pipeline in the shortest column.
$backupUnder = $inventory.Layout['Poster'].BackupUnder
$column = if ($backupUnder -and $columnOfHost.ContainsKey($backupUnder)) { $columnOfHost[$backupUnder] } else { 0 }
$card = Add-BackupCard -X $columnX[$column] -Y $columnEnd[$column] -Width $ColumnWidth[$column]
if ($card) { $columnEnd[$column] += $card.Height + $ColumnGap; $columnLast[$column] = $card }
$column = [array]::IndexOf($columnEnd, ($columnEnd | Measure-Object -Minimum).Minimum)
$card = Add-PipelineCard -X $columnX[$column] -Y $columnEnd[$column] -Width $ColumnWidth[$column]
if ($card) { $columnEnd[$column] += $card.Height + $ColumnGap; $columnLast[$column] = $card }

# The last card of each column ends on the line of the longest column.
$bottom = ($columnEnd | Measure-Object -Maximum).Maximum - $ColumnGap
foreach ($card in $columnLast) {
    if ($card) { $card.Height = $bottom - $card.Y }
}
foreach ($card in $script:CardFrame) { [void]$svg.Replace($card.Token, [string]$card.Height) }

# --- Clients and devices, then the footer ---

$y = $bottom + $ColumnGap
$y += (Add-DeviceStrip -X $Margin -Y $y -Width ($Width - 2 * $Margin)) + $ColumnGap

$y -= 10
Add-Line -X1 $Margin -Y1 $y -X2 ($Width - $Margin) -Y2 $y -Color $Theme.TileBorder -Width 1
$stamp = (Get-Date).ToString('dd MMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
Add-Text -X $Margin -Y ($y + 32) -Text "$stamp · POSTER UPDATED" -Size 12 -Color $Theme.Muted -Monospace -Spacing 1
Add-Text -X ($Width / 2) -Y ($y + 32) -Text 'Made from docs/map/inventory.psd1 · routes and media flow: homelab-map.drawio' -Size 13 -Color $Theme.Muted -Anchor middle
$right = if ($ShowAddress) { 'Private copy: addresses shown' } else { 'Private addresses hidden' }
Add-Text -X ($Width - $Margin) -Y ($y + 32) -Text $right -Size 13 -Color $Theme.Muted -Anchor end
$totalHeight = $y + 60

# --- Write the file ---

$inventoryHash = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$document = [System.Text.StringBuilder]::new()
[void]$document.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$Width`" height=`"$totalHeight`" viewBox=`"0 0 $Width $totalHeight`">")
[void]$document.AppendLine("<!-- Made by tools/homelab-map/Export-HomelabPoster.ps1. Do not change by hand. inventory-sha256: $inventoryHash -->")
[void]$document.AppendLine('<title>Homelab poster</title>')
[void]$document.AppendLine("<rect width=`"100%`" height=`"100%`" fill=`"$($Theme.Background)`"/>")
[void]$document.Append($svg.ToString())
[void]$document.AppendLine('</svg>')

if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the poster')) {
    $text = $document.ToString() -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $text, [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ File = (Resolve-Path -LiteralPath $OutputPath).Path; Width = $Width; Height = $totalHeight; Bytes = (Get-Item -LiteralPath $OutputPath).Length }
}
