#Requires -Version 7.0
<#
  New-HomelabMap.ps1  -  v1.2  (2026-10-21)
  Makes the pages of docs/map/homelab-map.drawio from the inventory
  (docs/map/inventory.psd1):
    Edge   the paths of a request from a client to a service, through
           Cloudflare, the router, Tailscale and Caddy
    Hosts  the network as a tree (internet, router, switch, Wi-Fi) and all
           the services of each host
    Media  the media pipeline, from a request to the film in Plex

  A page that is not in the drawing: the script makes the full page.
  A page that is in the drawing: the script only adds the items that are
  missing, and refreshes the tooltip of the items that are there. It does
  not move them and does not change their size or label, because Faginux
  arranges the layout by hand in draw.io. New items go in one row below
  the page. Move them into place in draw.io.

  -Restyle applies $Theme (below) to the pages of -View that are there: the
  style and the label of each item, the title, the legend and the
  background. It does not move an item, does not change a size and does not
  change the bend points of a line. A style or a label that you changed by
  hand in draw.io goes back to the theme.

  -Force makes the pages of -View again from zero. The changes by hand on
  these pages are lost. The other pages do not change. -Force needs -View,
  so that a run cannot delete the changes by hand on all the pages.

  Each item has the custom property "map_id" (Edit Data in draw.io, Ctrl+M).
  Test-HomelabMap.ps1 uses it to compare the drawing with the inventory. Do
  not remove it or change it.

  Tests:  -WhatIf   show what the script adds, write nothing

  Created with Claude Code (Anthropic).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot '..\..\docs\map\inventory.psd1'),
    [string]$OutputPath    = (Join-Path $PSScriptRoot '..\..\docs\map\homelab-map.drawio'),
    [string]$IconDirectory = (Join-Path $PSScriptRoot '..\..\docs\map\icons'),

    [ValidateSet('Edge', 'Hosts', 'Media')]
    [string[]]$View = @('Edge', 'Hosts', 'Media'),

    # Layout of draw.io for the page Media (a preset name or a JSON array, read
    # "draw.io --help"). An empty value keeps the simple layout of the script.
    [string]$MediaLayout = 'horizontalFlow',

    [switch]$Restyle,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HomelabMap.psm1') -Force

if ($Force -and -not $PSBoundParameters.ContainsKey('View')) {
    throw '-Force needs -View: name the pages to make again (for example -View Hosts). The other pages keep the changes by hand.'
}

# The order of the pages in the file.
$PageOrder = @('Edge', 'Hosts', 'Media')

# Theme of the map (synthwave). The colours are in HomelabMap.psm1, so that the
# drawing and the poster (Export-HomelabPoster.ps1) use the same values. To
# change a colour, change it there, then run: New-HomelabMap.ps1 -Restyle
$Theme = Get-HomelabTheme

# Colours of the route edges (page Edge). The legend uses the same values.
$RouteLook = [ordered]@{
    'public-crowdsec'  = @{ Color = $Theme.Primary; Dashed = '0'; Text = 'CrowdSec checks the request in Caddy' }
    'tailnet-enforced' = @{ Color = $Theme.Private; Dashed = '0'; Text = 'Caddy accepts only the tailnet (remote_ip)' }
    'dns-only'         = @{ Color = $Theme.Alarm;   Dashed = '1'; Text = 'no CrowdSec, no remote_ip: private by DNS only' }
    'direct'           = @{ Color = $Theme.Accent;  Dashed = '1'; Text = 'direct DNS record to a tailnet IP, no Caddy' }
}
$LinkStyle = "endArrow=block;endFill=1;html=1;rounded=0;strokeWidth=1.5;strokeColor=$($Theme.Secondary);" +
    "fontSize=10;fontColor=$($Theme.Text);labelBackgroundColor=$($Theme.Background);"

# Cables of the page Hosts: from the bottom of the parent to the top of the
# child, with right angles. A tree drawn like this has no crossing lines.
$TreeStyle = "edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=none;strokeWidth=2;strokeColor=$($Theme.Primary);" +
    "fontSize=10;fontColor=$($Theme.Text);labelBackgroundColor=$($Theme.Background);exitX=0.5;exitY=1;exitDx=0;exitDy=0;entryX=0.5;entryY=0;entryDx=0;entryDy=0;"

# Lines of the page Media, one look for each Kind of link. The legend uses the same values.
$MediaEdgeBase = "edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;endFill=1;strokeWidth=2;fontSize=10;fontColor=$($Theme.Text);labelBackgroundColor=$($Theme.Background);"
$MediaLinkLook = [ordered]@{
    'data'    = @{ Style = $MediaEdgeBase + "strokeColor=$($Theme.Primary);"; Color = $Theme.Primary; Mark = '———'; Text = 'files or requests go from source to target' }
    'control' = @{ Style = $MediaEdgeBase + "strokeColor=$($Theme.Secondary);dashed=1;"; Color = $Theme.Secondary; Mark = '- - - -'; Text = 'a script or a task starts the target' }
    'read'    = @{ Style = $MediaEdgeBase + "strokeColor=$($Theme.Accent);dashed=1;dashPattern=1 3;"; Color = $Theme.Accent; Mark = '· · · ·'; Text = 'the target reads the source' }
}

# Icons that get a light tile (Tile = 'light' in icons.psd1).
$LightTileIcon = Get-HomelabLightTileIcon -IconDirectory $IconDirectory

# Sizes in pixels.
$Top              = 90
$IconSize         = 56
$PlainWidth       = 130
$PlainHeight      = 60
$ColumnWidth      = 220
$ColumnX          = @(40, 300, 560, 820)
$LaneX            = 1110
$SlotWidth        = 190
$SlotHeight       = 150
$SlotsPerRow      = 4
$LaneHeader       = 36
$LanePadding      = 24
$LaneGap          = 40
$HostsSlotWidth   = 180
$HostsSlotHeight  = 140
$HostsSlotsPerRow = 4
$WifiSlotsPerRow  = 2
$HostsNodeWidth   = 170

function Get-InventoryItem {
    [CmdletBinding()]
    param([hashtable]$Inventory, [string]$Id)

    foreach ($group in 'Hosts', 'Nodes', 'Services') {
        $item = $Inventory[$group] | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
        if ($item) { return $item }
    }
    return $null
}

function ConvertTo-HtmlText {
    [CmdletBinding()]
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-ServiceKindText {
    <# The kind of a service in a few words, for the tiles of the page Hosts. #>
    [CmdletBinding()]
    param([hashtable]$Item)

    switch ($Item.Kind) {
        'job' { return 'job (run --rm)' }
        'baremetal' { return 'bare metal' }
    }
    $containers = @($Item.Containers | Where-Object { $_ })
    $stopped    = @($containers | Where-Object { $_.State -eq 'stopped' })
    if ($containers.Count -gt 0 -and $stopped.Count -eq $containers.Count) {
        if ($containers.Count -eq 1) { return 'stopped container' }
        return "stopped ($($containers.Count) containers)"
    }
    if ($containers.Count -le 1) { return 'container' }
    return "$($containers.Count) containers"
}

function Get-NodeLabel {
    <# The HTML label of a node or a tile: the name in bold, the details below in the muted colour of the theme. #>
    [CmdletBinding()]
    param([hashtable]$Inventory, [hashtable]$Item, [string]$View = 'Edge')

    $detail = '<font style="font-size:10px" color="' + $Theme.Muted + '">{0}</font>'
    $lines  = @("<b>$(ConvertTo-HtmlText $Item.Name)</b>")
    $routes = @($Inventory.Routes | Where-Object { $_.Service -eq $Item.Id })
    $isService = [bool]($Inventory.Services | Where-Object { $_.Id -eq $Item.Id })

    if ($View -eq 'Media') {
        if ($Item.Kind -eq 'task') { $lines += $detail -f 'Scheduled Task' }
        elseif ($Item.Host) {
            $hostItem = Get-InventoryItem -Inventory $Inventory -Id $Item.Host
            $lines += $detail -f "on $(ConvertTo-HtmlText $hostItem.Name)"
        }
        return ($lines -join '<br>')
    }

    if ($View -eq 'Hosts' -and $isService) {
        $lines += $detail -f (ConvertTo-HtmlText (Get-ServiceKindText -Item $Item))
        if ($routes.Count -gt 0) { $lines += $detail -f (ConvertTo-HtmlText $routes[0].Hostname) }
        elseif ($Item.Endpoint) { $lines += $detail -f (ConvertTo-HtmlText $Item.Endpoint) }
        return ($lines -join '<br>')
    }

    if ($routes.Count -gt 0) {
        foreach ($route in $routes) {
            $lines += $detail -f "$(ConvertTo-HtmlText $route.Hostname)<br>$(ConvertTo-HtmlText $route.Backend)"
        }
    }
    elseif ($Item.Lan -or $Item.Tailnet) {
        $address = @($Item.Lan, $Item.Tailnet) | Where-Object { $_ }
        $lines += $detail -f (ConvertTo-HtmlText ($address -join ' / '))
    }
    elseif ($Item.Host) {
        $hostItem = Get-InventoryItem -Inventory $Inventory -Id $Item.Host
        $lines += $detail -f "on $(ConvertTo-HtmlText $hostItem.Name)"
    }
    return ($lines -join '<br>')
}

function Get-NodeTooltip {
    <# Plain text that draw.io shows when the pointer is on the item. #>
    [CmdletBinding()]
    param([hashtable]$Inventory, [hashtable]$Item)

    $lines = @()
    if ($Item.Role) { $lines += $Item.Role }
    if ($Item.Host) {
        $hostItem = Get-InventoryItem -Inventory $Inventory -Id $Item.Host
        $lines += "Host: $($hostItem.Name)"
    }
    if ($Item.Kind) { $lines += "Kind: $($Item.Kind)" }
    if ($Item.Stack) { $lines += "Stack: $($Item.Stack)" }
    $containers = @($Item.Containers | Where-Object { $_ } | ForEach-Object { if ($_.Name) { $_.Name } else { $_.Pattern } })
    if ($containers.Count -gt 0) { $lines += "Containers: $($containers -join ', ')" }
    foreach ($route in @($Inventory.Routes | Where-Object { $_.Service -eq $Item.Id })) {
        $dnsKind = Get-HomelabRouteDnsKind -Route $route
        $lines += "Route: $($route.Hostname) -> $($route.Backend) ($($route.Exposure)$(if ($dnsKind) { ", DNS $dnsKind" }))"
    }
    if ($Item.Endpoint) { $lines += "Endpoint: $($Item.Endpoint)" }
    if ($Item.Uplink) {
        $uplinkItem = Get-InventoryItem -Inventory $Inventory -Id $Item.Uplink
        $lines += "Connection: $($uplinkItem.Name)$(if ($Item.UplinkLabel) { " ($($Item.UplinkLabel))" })"
    }
    if ($Item.Note) { $lines += $Item.Note }
    return ($lines -join "`n")
}

function New-MapObject {
    <#
    Adds one draw.io cell as <object><mxCell/></object>. The <object> keeps the
    custom properties (map_id, tooltip, link). -Behind puts the cell first in
    the layer, so draw.io draws it below the other cells (used for edges).
    Returns the cell id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$MapId,
        [string]$Label = '',
        [Parameter(Mandatory)][string]$Style,
        [string]$Parent = '1',
        [double]$X, [double]$Y, [double]$Width, [double]$Height,
        [string]$Source,
        [string]$Target,
        [hashtable]$Property = @{},
        [switch]$Behind
    )

    $document = $Context.Document
    $baseId   = if ($MapId) { 'map-' + ($MapId -replace '[^A-Za-z0-9_-]', '-') } else { 'deco' }
    $id       = $baseId
    $counter  = 2
    while ($Context.UsedIds.Contains($id)) { $id = "$baseId-$counter"; $counter++ }
    [void]$Context.UsedIds.Add($id)

    $object = $document.CreateElement('object')
    $object.SetAttribute('label', $Label)
    if ($MapId) { $object.SetAttribute('map_id', $MapId) }
    foreach ($key in $Property.Keys) {
        if ($Property[$key]) { $object.SetAttribute($key, [string]$Property[$key]) }
    }
    $object.SetAttribute('id', $id)

    $cell = $document.CreateElement('mxCell')
    $cell.SetAttribute('style', $Style)
    $geometry = $document.CreateElement('mxGeometry')
    if ($Source -or $Target) {
        $cell.SetAttribute('edge', '1')
        $cell.SetAttribute('parent', $Parent)
        $cell.SetAttribute('source', $Source)
        $cell.SetAttribute('target', $Target)
        $geometry.SetAttribute('relative', '1')
    }
    else {
        $cell.SetAttribute('vertex', '1')
        $cell.SetAttribute('parent', $Parent)
        $geometry.SetAttribute('x', ([int][math]::Round($X)).ToString())
        $geometry.SetAttribute('y', ([int][math]::Round($Y)).ToString())
        $geometry.SetAttribute('width', ([int][math]::Round($Width)).ToString())
        $geometry.SetAttribute('height', ([int][math]::Round($Height)).ToString())
    }
    $geometry.SetAttribute('as', 'geometry')
    [void]$cell.AppendChild($geometry)
    [void]$object.AppendChild($cell)

    if ($Behind) { [void]$Context.Root.InsertAfter($object, $Context.Layer) }
    else { [void]$Context.Root.AppendChild($object) }
    return $id
}

function Get-VertexLook {
    <# Style and size of a node or a tile: the icon if there is one, else a box. #>
    [CmdletBinding()]
    param([hashtable]$Item, [string]$IconDirectory)

    $box = "whiteSpace=wrap;html=1;fillColor=$($Theme.Panel);fontColor=$($Theme.Text);strokeWidth=2;"
    if ($Item.Shape -eq 'cloud') {
        return @{ Style = "ellipse;shape=cloud;$($box)strokeColor=$($Theme.Accent);fontSize=12;"; Width = 150; Height = 90 }
    }
    if ($Item.Kind -eq 'task') {
        return @{ Style = "rounded=1;dashed=1;$($box)strokeColor=$($Theme.Task);fontSize=11;"; Width = 150; Height = 60 }
    }
    if ($Item.Kind -eq 'storage') {
        return @{ Style = "shape=cylinder3;boundedLbl=1;backgroundOutline=1;size=10;$($box)strokeColor=$($Theme.Accent);fontSize=11;"; Width = 150; Height = 80 }
    }
    $tile = if ($Item.Icon) { Get-IconTileStyle -Name $Item.Icon -ImageSize 40 } else { $null }
    if ($tile) {
        return @{
            # The label background has the colour of the page: it hides the edges that go behind the label.
            Style  = "$($tile)verticalLabelPosition=bottom;verticalAlign=top;labelBackgroundColor=$($Theme.Background);fontColor=$($Theme.Text);fontSize=11;"
            Width  = $IconSize
            Height = $IconSize
        }
    }
    return @{ Style = "rounded=1;$($box)strokeWidth=1.5;strokeColor=$($Theme.TileBorder);fontSize=11;"; Width = $PlainWidth; Height = $PlainHeight }
}

function Get-IconTileStyle {
    <#
    The style of an icon on a rounded tile (shape=label: the image in the
    middle of a box). A dark icon (Tile = 'light' in icons.psd1) gets a light
    tile, the other icons a dark tile. Returns $null when the icon file is missing.
    #>
    [CmdletBinding()]
    param([string]$Name, [int]$ImageSize = 40)

    $uri = Get-HomelabIconDataUri -IconDirectory $IconDirectory -Name $Name
    if (-not $uri) { return $null }
    $fill = if ($LightTileIcon.ContainsKey($Name)) { $Theme.LightTile } else { $Theme.Panel }
    return "shape=label;html=1;rounded=1;arcSize=18;aspect=fixed;fillColor=$fill;strokeColor=$($Theme.TileBorder);strokeWidth=1.5;" +
        "imageWidth=$ImageSize;imageHeight=$ImageSize;imageAlign=center;imageVerticalAlign=middle;image=$uri;"
}

function Get-LaneLook {
    <# Style and label of a lane (a host box), and the style of the icon in its header. #>
    [CmdletBinding()]
    param([hashtable]$Item)

    $details = @()
    if ($Item.Os) { $details += ConvertTo-HtmlText $Item.Os }
    $address = (@($Item.Lan, $Item.Tailnet) | Where-Object { $_ }) -join ' / '
    if ($address) { $details += ConvertTo-HtmlText $address }
    $label = "<b>$(ConvertTo-HtmlText $Item.Name)</b>"
    if ($details.Count -gt 0) { $label += "  <font color=`"$($Theme.Muted)`">·  $($details -join '  ·  ')</font>" }

    $iconStyle = if ($Item.Icon) { Get-IconTileStyle -Name $Item.Icon -ImageSize 20 } else { $null }
    $spacing   = if ($iconStyle) { 44 } else { 12 }
    # A Wi-Fi box is part of the network (green). A host box is purple.
    $border = if ($Item.Kind -eq 'wireless') { $Theme.Network } else { $Theme.Group }
    $header = if ($Item.Kind -eq 'wireless') { $Theme.NetworkFill } else { $Theme.GroupFill }
    $style  = "swimlane;html=1;startSize=$LaneHeader;rounded=1;arcSize=3;fillColor=$header;swimlaneFillColor=none;" +
        "strokeColor=$border;strokeWidth=2;fontColor=$($Theme.Text);fontSize=12;align=left;spacingLeft=$spacing;collapsible=0;"
    return @{ Style = $style; Label = $label; IconStyle = $iconStyle }
}

function Get-RouteLook {
    [CmdletBinding()]
    param([hashtable]$Route)

    $key  = if ($Route.Via -eq 'direct') { 'direct' } else { $Route.Exposure }
    $look = $RouteLook[$key]
    return "endArrow=block;endFill=1;html=1;rounded=0;strokeWidth=2;strokeColor=$($look.Color);dashed=$($look.Dashed);"
}

function Add-NodeItem {
    <#
    Adds one node, tile or lane. For a node or a tile, X is the centre and Y
    the top. For a lane, X and Y are the top-left corner. Returns the cell id.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Context, [hashtable]$Inventory, [string]$MapId, [string]$Parent = '1',
        [double]$X, [double]$Y, [double]$Width = 0, [double]$Height = 0, [switch]$Lane,
        [string]$View = 'Edge'
    )

    $item = Get-InventoryItem -Inventory $Inventory -Id $MapId
    $property = @{ tooltip = (Get-NodeTooltip -Inventory $Inventory -Item $item) }
    $webRoute = @($Inventory.Routes | Where-Object { $_.Service -eq $MapId -and $_.Via -eq 'caddy' }) | Select-Object -First 1
    if ($webRoute) { $property['link'] = "https://$($webRoute.Hostname)" }

    if ($Lane) {
        $laneLook = Get-LaneLook -Item $item
        $laneId   = New-MapObject -Context $Context -MapId $MapId -Label $laneLook.Label -Style $laneLook.Style -Parent $Parent -X $X -Y $Y -Width $Width -Height $Height -Property $property
        if ($laneLook.IconStyle) {
            [void](New-MapObject -Context $Context -Style $laneLook.IconStyle -Parent $laneId -X 10 -Y 5 -Width 26 -Height 26 -Property @{ map_deco = 'lane-icon' })
        }
        return $laneId
    }

    $look = Get-VertexLook -Item $item -IconDirectory $IconDirectory
    $label = Get-NodeLabel -Inventory $Inventory -Item $item -View $View
    return New-MapObject -Context $Context -MapId $MapId -Label $label -Style $look.Style -Parent $Parent `
        -X ($X - $look.Width / 2) -Y $Y -Width $look.Width -Height $look.Height -Property $property
}

function Get-EdgeItemLook {
    <# Style, label and tooltip of one route, link or uplink edge. #>
    [CmdletBinding()]
    param([hashtable]$Inventory, [pscustomobject]$ViewItem, [string]$View = 'Edge')

    switch ($ViewItem.Type) {
        'route' {
            $hostname = $ViewItem.MapId.Substring('route:'.Length)
            $route    = $Inventory.Routes | Where-Object { $_.Hostname -eq $hostname } | Select-Object -First 1
            $style    = Get-RouteLook -Route $route
            $label    = ''
            $dnsKind  = Get-HomelabRouteDnsKind -Route $route
            $tooltip  = "$($route.Hostname) -> $($route.Backend) ($($route.Exposure), via $($route.Via)$(if ($dnsKind) { ", DNS $dnsKind" }))"
        }
        'uplink' {
            $itemId   = $ViewItem.MapId.Substring('uplink:'.Length)
            $item     = Get-InventoryItem -Inventory $Inventory -Id $itemId
            $style    = $TreeStyle
            $label    = ConvertTo-HtmlText $item.UplinkLabel
            $fromItem = Get-InventoryItem -Inventory $Inventory -Id $ViewItem.From
            $tooltip  = "$($fromItem.Name) -> $($item.Name)$(if ($item.UplinkLabel) { " ($($item.UplinkLabel))" })"
        }
        default {
            $linkId  = $ViewItem.MapId.Substring('link:'.Length)
            $link    = $Inventory.Links | Where-Object { $_.Id -eq $linkId } | Select-Object -First 1
            $style   = switch ($View) {
                'Hosts' { $TreeStyle }
                'Media' {
                    $kind = if ($link.Kind) { $link.Kind } else { 'data' }
                    $MediaLinkLook[$kind].Style
                }
                default { $LinkStyle }
            }
            $label   = ConvertTo-HtmlText $link.Label
            $tooltip = $link.Label
        }
    }
    return @{ Style = $style; Label = $label; Tooltip = $tooltip }
}

function Add-EdgeItem {
    <# Adds one route, link or uplink edge. Returns $null when an end is not in the page. #>
    [CmdletBinding()]
    param([hashtable]$Context, [hashtable]$Inventory, [pscustomobject]$ViewItem, [hashtable]$CellOfMapId, [string]$View = 'Edge')

    # Get-HomelabViewItem sets the two ends, so Test-HomelabMap.ps1 checks the same ends.
    $from = $ViewItem.From
    $to   = $ViewItem.To
    if (-not $CellOfMapId.ContainsKey($from) -or -not $CellOfMapId.ContainsKey($to)) { return $null }
    $look = Get-EdgeItemLook -Inventory $Inventory -ViewItem $ViewItem -View $View
    return New-MapObject -Context $Context -MapId $ViewItem.MapId -Label $look.Label -Style $look.Style `
        -Source $CellOfMapId[$from] -Target $CellOfMapId[$to] -Property @{ tooltip = $look.Tooltip } -Behind
}

function New-DrawioDocument {
    [CmdletBinding()]
    param()
    return [xml]'<mxfile host="homelab-map" agent="tools/homelab-map/New-HomelabMap.ps1" type="device"></mxfile>'
}

function New-DrawioPage {
    <# Makes an empty page with the two base cells (0 = root, 1 = default layer). The caller puts it in the file. #>
    [CmdletBinding()]
    param([xml]$Document, [string]$Name)

    $diagram = $Document.CreateElement('diagram')
    $diagram.SetAttribute('id', ($Name.ToLowerInvariant() -replace '[^a-z0-9]', '-'))
    $diagram.SetAttribute('name', $Name)
    $model = $Document.CreateElement('mxGraphModel')
    # The background of the theme goes into the exported SVG too.
    foreach ($pair in @{ dx = '1600'; dy = '1000'; grid = '1'; gridSize = '10'; guides = '1'; tooltips = '1'; connect = '1'; arrows = '1'; fold = '1'; page = '0'; pageScale = '1'; math = '0'; shadow = '0'; background = $Theme.Background }.GetEnumerator()) {
        $model.SetAttribute($pair.Key, $pair.Value)
    }
    $root = $Document.CreateElement('root')
    $cell0 = $Document.CreateElement('mxCell'); $cell0.SetAttribute('id', '0')
    $cell1 = $Document.CreateElement('mxCell'); $cell1.SetAttribute('id', '1'); $cell1.SetAttribute('parent', '0')
    [void]$root.AppendChild($cell0); [void]$root.AppendChild($cell1)
    [void]$model.AppendChild($root)
    [void]$diagram.AppendChild($model)
    return $diagram
}

function Get-DecorationLook {
    <#
    Style and label of the title or the legend of a page. The cells have the
    property map_deco ('title' or 'legend'), so that -Restyle finds them.
    #>
    [CmdletBinding()]
    param([ValidateSet('title', 'legend')][string]$Kind, [string]$Page)

    $note = "<font style=`"font-size:10px`" color=`"$($Theme.Muted)`">{0}</font>"
    if ($Kind -eq 'title') {
        $label = "<font color=`"$($Theme.Title)`"><b>Homelab map: $Page</b></font><br>" +
            ($note -f 'Made from docs/map/inventory.psd1 by tools/homelab-map/New-HomelabMap.ps1. Check it with Test-HomelabMap.ps1.')
        return @{ Style = "text;html=1;align=left;verticalAlign=top;fontSize=16;fontColor=$($Theme.Text);"; Label = $label }
    }

    $mark = { param($Color, $Text) "<font color=`"$Color`"><b>$Text</b></font>" }
    switch ($Page) {
        'Edge' {
            $lines = @('<b>Routes</b>')
            foreach ($entry in $RouteLook.GetEnumerator()) {
                $dash = if ($entry.Value.Dashed -eq '1') { '- - - -' } else { '———' }
                $lines += "$(& $mark $entry.Value.Color $dash)  $(ConvertTo-HtmlText $entry.Value.Text)"
            }
            $lines += "$(& $mark $Theme.Secondary '———')  other link (label on the line)"
            $lines += $note -f 'Click a service to open its URL. Hover for details.'
        }
        'Hosts' {
            $lines = @(
                '<b>Hosts</b>'
                "$(& $mark $Theme.Primary '———')  network cable (the text on the line tells the port)"
                "$(& $mark $Theme.Group '■')  host box: the host and all its services"
                "$(& $mark $Theme.Network '■')  Wi-Fi box: the devices on the Wi-Fi of the router"
                'Under each service: container, N containers, job (run --rm), bare metal or stopped'
                ($note -f 'Hover for details: stack, containers, route, connection.')
            )
        }
        'Media' {
            $lines = @('<b>Media pipeline</b>')
            foreach ($entry in $MediaLinkLook.GetEnumerator()) {
                $lines += "$(& $mark $entry.Value.Color $entry.Value.Mark)  $(ConvertTo-HtmlText $entry.Value.Text)"
            }
            $lines += "$(& $mark $Theme.Task '■')  dashed box: a Scheduled Task of ARCADE"
            $lines += "$(& $mark $Theme.Accent '■')  cylinder: the media library"
            $lines += $note -f 'Tdarr works on the Movies library only. Hover for details.'
        }
    }
    $style = "rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=top;spacing=10;fillColor=$($Theme.Panel);" +
        "strokeColor=$($Theme.Network);strokeWidth=2;fontColor=$($Theme.Text);fontSize=11;"
    return @{ Style = $style; Label = ($lines -join '<br>') }
}

function Add-PageDecoration {
    <# Title and legend: decoration with no map_id. The test ignores them. #>
    [CmdletBinding()]
    param([hashtable]$Context, [string]$Page, [double]$LegendY, [double]$LegendHeight)

    $title  = Get-DecorationLook -Kind title -Page $Page
    $legend = Get-DecorationLook -Kind legend -Page $Page
    [void](New-MapObject -Context $Context -Label $title.Label -Style $title.Style -X 40 -Y 20 -Width 900 -Height 50 -Property @{ map_deco = 'title' })
    [void](New-MapObject -Context $Context -Label $legend.Label -Style $legend.Style -X 40 -Y $LegendY -Width 470 -Height $LegendHeight -Property @{ map_deco = 'legend' })
}

function Add-EdgePage {
    <# Draws all the items of the page Edge on an empty page. #>
    [CmdletBinding()]
    param([hashtable]$Context, [hashtable]$Inventory, [object[]]$ViewItem)

    $cellOfMapId = @{}
    $layout = $Inventory.Layout['Edge']

    # Lanes on the right, one below the other.
    $laneY = $Top
    foreach ($laneHost in $layout.Lanes) {
        $tiles  = @($ViewItem | Where-Object { $_.Type -eq 'service' -and $_.Lane -eq $laneHost })
        $rows   = [math]::Max(1, [math]::Ceiling($tiles.Count / $SlotsPerRow))
        $width  = 2 * $LanePadding + $SlotsPerRow * $SlotWidth
        $height = $LaneHeader + $LanePadding + $rows * $SlotHeight
        $laneId = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $laneHost -X $LaneX -Y $laneY -Width $width -Height $height -Lane
        $cellOfMapId[$laneHost] = $laneId
        for ($index = 0; $index -lt $tiles.Count; $index++) {
            $column  = $index % $SlotsPerRow
            $row     = [math]::Floor($index / $SlotsPerRow)
            $centerX = $LanePadding + $column * $SlotWidth + $SlotWidth / 2
            $tileY   = $LaneHeader + $LanePadding + $row * $SlotHeight
            $cellOfMapId[$tiles[$index].MapId] = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $tiles[$index].MapId -Parent $laneId -X $centerX -Y $tileY
        }
        $laneY += $height + $LaneGap
    }
    $totalHeight = [math]::Max(600, $laneY - $LaneGap - $Top)

    # Columns on the left, over the height of the lanes. A node goes to its At
    # place, or the nodes of the column are spread evenly.
    for ($columnIndex = 0; $columnIndex -lt $layout.Columns.Count; $columnIndex++) {
        $column = @(Get-HomelabLayoutEntry -Column $layout.Columns[$columnIndex])
        for ($index = 0; $index -lt $column.Count; $index++) {
            $at      = if ($null -ne $column[$index].At) { [double]$column[$index].At } else { ($index + 1) / ($column.Count + 1) }
            $centerX = $ColumnX[$columnIndex] + $ColumnWidth / 2
            $nodeY   = $Top + $at * $totalHeight - 40
            $cellOfMapId[$column[$index].Id] = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $column[$index].Id -X $centerX -Y $nodeY
        }
    }

    # Edges last: they need the cell ids of both ends.
    foreach ($item in @($ViewItem | Where-Object { $_.Type -in 'route', 'link' })) {
        [void](Add-EdgeItem -Context $Context -Inventory $Inventory -ViewItem $item -CellOfMapId $cellOfMapId -View 'Edge')
    }

    Add-PageDecoration -Context $Context -Page 'Edge' -LegendY ($Top + $totalHeight + 30) -LegendHeight 140
}

function Get-HostsItemSize {
    <# Size of an item of the page Hosts: a lane with its tiles, or a node with its label. #>
    [CmdletBinding()]
    param([hashtable]$Item, [object[]]$ViewItem, [string[]]$Wireless)

    $entry = $ViewItem | Where-Object { $_.MapId -eq $Item.Id } | Select-Object -First 1
    if ($entry.Type -eq 'lane') {
        $perRow = if ($Item.Id -in $Wireless) { $WifiSlotsPerRow } else { $HostsSlotsPerRow }
        $count  = @($ViewItem | Where-Object { $_.Lane -eq $Item.Id }).Count
        $rows   = [math]::Max(1, [math]::Ceiling($count / $perRow))
        return @{ Lane = $true; PerRow = $perRow; Width = 2 * $LanePadding + $perRow * $HostsSlotWidth; Height = $LaneHeader + $LanePadding + $rows * $HostsSlotHeight }
    }
    $look = Get-VertexLook -Item $Item -IconDirectory $IconDirectory
    return @{ Lane = $false; Width = [math]::Max($look.Width, $HostsNodeWidth); Height = $look.Height + 40 }
}

function Add-HostsBlock {
    <# Adds a node (X = centre) or a lane with its tiles (X = left side) of the page Hosts. Returns the centre X. #>
    [CmdletBinding()]
    param([hashtable]$Context, [hashtable]$Inventory, [object[]]$ViewItem, [hashtable]$CellOfMapId, [hashtable]$Item, [hashtable]$Size, [double]$Left, [double]$Y)

    if (-not $Size.Lane) {
        $centerX = $Left + $Size.Width / 2
        $CellOfMapId[$Item.Id] = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $Item.Id -X $centerX -Y $Y -View 'Hosts'
        return $centerX
    }
    $laneId = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $Item.Id -X $Left -Y $Y -Width $Size.Width -Height $Size.Height -Lane -View 'Hosts'
    $CellOfMapId[$Item.Id] = $laneId
    $tiles = @($ViewItem | Where-Object { $_.Lane -eq $Item.Id })
    for ($index = 0; $index -lt $tiles.Count; $index++) {
        $column  = $index % $Size.PerRow
        $row     = [math]::Floor($index / $Size.PerRow)
        $centerX = $LanePadding + $column * $HostsSlotWidth + $HostsSlotWidth / 2
        $tileY   = $LaneHeader + $LanePadding + $row * $HostsSlotHeight
        $CellOfMapId[$tiles[$index].MapId] = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $tiles[$index].MapId -Parent $laneId -X $centerX -Y $tileY -View 'Hosts'
    }
    return $Left + $Size.Width / 2
}

function Add-HostsPage {
    <#
    Draws the page Hosts as a tree, from the top:
      row 0  the nodes with a link to the root (the internet)
      row 1  the root: the network host with no Uplink (the router)
      row 2  the children of the root: the switch, and the Wi-Fi box at the right
      row 3  the children of the switch: one box for each server with all its
             services, and the wired devices
    The Wi-Fi box is at the right of row 3, so the cables of the switch do not
    go below it. Items that do not fit this tree go in a row at the bottom.
    #>
    [CmdletBinding()]
    param([hashtable]$Context, [hashtable]$Inventory, [object[]]$ViewItem)

    $cellOfMapId = @{}
    $inView   = @{}
    foreach ($entry in $ViewItem) { $inView[$entry.MapId] = $entry }
    $wireless = @($Inventory.Nodes | Where-Object { $_.Kind -eq 'wireless' } | ForEach-Object { $_.Id })
    $all      = @($Inventory.Hosts) + @($Inventory.Nodes)
    $treeItem = @($all | Where-Object { $inView.ContainsKey($_.Id) -and $inView[$_.Id].Type -in 'node', 'lane' })

    # The root: a network host with no Uplink that is the Uplink of other items (the router).
    $root = $treeItem | Where-Object { $_.Kind -eq 'network' -and -not $_.Uplink -and ($all.Uplink -contains $_.Id) } | Select-Object -First 1
    if (-not $root) { throw "Page Hosts: no network host with no Uplink (the router) in the inventory" }

    # Above the root: the chain of Hosts links that ends at the root, for
    # example internet -> ISP -> ONT -> router. One row for each step, the far end on top.
    $upperLevels = [System.Collections.Generic.List[object]]::new()
    $inChain     = @{ $root.Id = $true }
    $current     = @($root.Id)
    while ($true) {
        $ids = @($Inventory.Links | Where-Object { $_.View -eq 'Hosts' -and $_.To -in $current -and -not $inChain.ContainsKey($_.From) } |
            ForEach-Object { $_.From } | Select-Object -Unique)
        if ($ids.Count -eq 0) { break }
        foreach ($id in $ids) { $inChain[$id] = $true }
        $upperLevels.Insert(0, $ids)
        $current = $ids
    }
    $level1         = @($treeItem | Where-Object { $_.Uplink -eq $root.Id })
    $level1Wired    = @($level1 | Where-Object { $_.Id -notin $wireless })
    $level1Wireless = @($level1 | Where-Object { $_.Id -in $wireless })

    $rowRootY = $Top + [math]::Max(1, $upperLevels.Count) * 170
    $rowL1Y   = $rowRootY + 170
    $l1Height = 110
    foreach ($item in $level1) {
        $l1Height = [math]::Max($l1Height, (Get-HostsItemSize -Item $item -ViewItem $ViewItem -Wireless $wireless).Height)
    }
    $rowL2Y = $rowL1Y + $l1Height + 90

    # Row 3 first: the position of each parent is the centre of its children.
    $x        = 40
    $centerOf = @{}
    $bottom   = $rowL2Y
    foreach ($parent in $level1Wired) {
        $children = @($treeItem | Where-Object { $_.Uplink -eq $parent.Id })
        $first = $null; $last = $null
        foreach ($child in $children) {
            $size   = Get-HostsItemSize -Item $child -ViewItem $ViewItem -Wireless $wireless
            $center = Add-HostsBlock -Context $Context -Inventory $Inventory -ViewItem $ViewItem -CellOfMapId $cellOfMapId -Item $child -Size $size -Left $x -Y $rowL2Y
            if ($null -eq $first) { $first = $center }
            $last   = $center
            $x     += $size.Width + 50
            $bottom = [math]::Max($bottom, $rowL2Y + $size.Height)
        }
        if ($null -eq $first) { $first = $x + $HostsNodeWidth / 2; $last = $first; $x += $HostsNodeWidth + 50 }
        $centerOf[$parent.Id] = ($first + $last) / 2
    }

    foreach ($parent in $level1Wired) {
        $size = Get-HostsItemSize -Item $parent -ViewItem $ViewItem -Wireless $wireless
        [void](Add-HostsBlock -Context $Context -Inventory $Inventory -ViewItem $ViewItem -CellOfMapId $cellOfMapId -Item $parent -Size $size -Left ($centerOf[$parent.Id] - $size.Width / 2) -Y $rowL1Y)
    }
    $wirelessX = [math]::Max($x + 30, 40)
    foreach ($lane in $level1Wireless) {
        $size = Get-HostsItemSize -Item $lane -ViewItem $ViewItem -Wireless $wireless
        $centerOf[$lane.Id] = Add-HostsBlock -Context $Context -Inventory $Inventory -ViewItem $ViewItem -CellOfMapId $cellOfMapId -Item $lane -Size $size -Left $wirelessX -Y $rowL1Y
        $wirelessX += $size.Width + 50
    }

    # The root above the middle of its children, and the chain of links above the root.
    $centers    = @($level1 | ForEach-Object { $centerOf[$_.Id] })
    $rootCenter = if ($centers.Count -gt 0) { (($centers | Measure-Object -Minimum).Minimum + ($centers | Measure-Object -Maximum).Maximum) / 2 } else { 400 }
    $rootSize   = Get-HostsItemSize -Item $root -ViewItem $ViewItem -Wireless $wireless
    [void](Add-HostsBlock -Context $Context -Inventory $Inventory -ViewItem $ViewItem -CellOfMapId $cellOfMapId -Item $root -Size $rootSize -Left ($rootCenter - $rootSize.Width / 2) -Y $rowRootY)
    for ($level = 0; $level -lt $upperLevels.Count; $level++) {
        $upperIds = @($upperLevels[$level])
        for ($index = 0; $index -lt $upperIds.Count; $index++) {
            $item = Get-InventoryItem -Inventory $Inventory -Id $upperIds[$index]
            if (-not $item -or $cellOfMapId.ContainsKey($item.Id)) { continue }
            $size = Get-HostsItemSize -Item $item -ViewItem $ViewItem -Wireless $wireless
            $centerX = $rootCenter + ($index - ($upperIds.Count - 1) / 2) * 220
            [void](Add-HostsBlock -Context $Context -Inventory $Inventory -ViewItem $ViewItem -CellOfMapId $cellOfMapId -Item $item -Size $size -Left ($centerX - $size.Width / 2) -Y ($Top + $level * 170))
        }
    }

    # The rest (items outside the tree) and all the edges.
    [void](Add-MissingItem -Context $Context -Inventory $Inventory -ViewItem $ViewItem -View 'Hosts')

    $lowest = $bottom
    foreach ($geometry in $Context.Model.SelectNodes(".//mxCell[@vertex='1' and @parent='1']/mxGeometry")) {
        $lowest = [math]::Max($lowest, [double]$geometry.GetAttribute('y') + [double]$geometry.GetAttribute('height'))
    }
    Add-PageDecoration -Context $Context -Page 'Hosts' -LegendY ($lowest + 40) -LegendHeight 120
}

function Add-MediaPage {
    <#
    Draws the page Media: the media pipeline from left to right. Each item
    goes in a column by its rank (the longest path from a source). A source
    goes one column before its first target, so it stays near it. Then
    Optimize-MediaLayout can move the items with the layered layout of draw.io.
    #>
    [CmdletBinding()]
    param([hashtable]$Context, [hashtable]$Inventory, [object[]]$ViewItem)

    $links = @($Inventory.Links | Where-Object { $_.View -eq 'Media' })
    $nodes = @($ViewItem | Where-Object { $_.Type -eq 'node' } | ForEach-Object { $_.MapId })
    $rank  = @{}
    foreach ($id in $nodes) { $rank[$id] = 0 }
    for ($pass = 0; $pass -lt $nodes.Count; $pass++) {
        $changed = $false
        foreach ($link in $links) {
            if ($rank[$link.To] -lt $rank[$link.From] + 1) { $rank[$link.To] = $rank[$link.From] + 1; $changed = $true }
        }
        if (-not $changed) { break }
    }
    foreach ($id in $nodes) {
        if (@($links | Where-Object { $_.To -eq $id }).Count -gt 0) { continue }
        $targetRanks = @($links | Where-Object { $_.From -eq $id } | ForEach-Object { $rank[$_.To] })
        if ($targetRanks.Count -gt 0) { $rank[$id] = [math]::Max(0, ($targetRanks | Measure-Object -Minimum).Minimum - 1) }
    }

    $cellOfMapId = @{}
    $lowest = $Top
    foreach ($group in ($nodes | Group-Object { $rank[$_] } | Sort-Object { [int]$_.Name })) {
        $row = 0
        foreach ($id in $group.Group) {
            $centerX = 40 + [int]$group.Name * 260 + 110
            $y       = $Top + $row * 150
            $cellOfMapId[$id] = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $id -X $centerX -Y $y -View 'Media'
            $lowest  = [math]::Max($lowest, $y + 110)
            $row++
        }
    }
    [void](Add-MissingItem -Context $Context -Inventory $Inventory -ViewItem $ViewItem -View 'Media')
}

function Optimize-MediaLayout {
    <#
    Moves the items of a page with a layout of draw.io Desktop (command line,
    --layout). The page goes alone into a temporary file, draw.io exports it
    again as plain XML after the layout, and the new page takes the place of
    the old one. With no draw.io, the page keeps its first layout.
    Returns the new mxGraphModel, or $null when the layout did not run.
    #>
    [CmdletBinding()]
    param([xml]$Document, [System.Xml.XmlElement]$Diagram, [string]$Layout)

    $drawio = Join-Path $env:LOCALAPPDATA 'Programs\draw.io\draw.io.exe'
    if (-not (Test-Path -LiteralPath $drawio)) {
        Write-Warning "draw.io Desktop not found: the page $($Diagram.GetAttribute('name')) keeps the simple layout."
        return $null
    }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) "homelab-map-layout-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $single = New-DrawioDocument
        [void]$single.DocumentElement.AppendChild($single.ImportNode($Diagram, $true))
        $inputFile  = Join-Path $work 'in.drawio'
        $outputFile = Join-Path $work 'out.drawio'
        $single.Save($inputFile)
        # Start-Process does not escape the quotes of a JSON value: the Windows command line needs \".
        $layoutArgument = if ($Layout.Contains('"')) { '"' + $Layout.Replace('"', '\"') + '"' } else { $Layout }
        $arguments = @('--export', '--format', 'xml', '--uncompressed', '--layout', $layoutArgument, '--output', "`"$outputFile`"", "`"$inputFile`"")
        $process = Start-Process -FilePath $drawio -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputFile)) {
            Write-Warning "draw.io layout failed (exit code $($process.ExitCode)): the page keeps the simple layout."
            return $null
        }
        $result  = [xml](Get-Content -LiteralPath $outputFile -Raw)
        $model   = ConvertFrom-HomelabDrawioPage -Diagram $result.SelectSingleNode('/mxfile/diagram')
        $newModel = $Document.ImportNode($model, $true)
        $oldModel = $Diagram.SelectSingleNode('mxGraphModel')

        # The layout makes the icons wider to fit the label. Give each icon its
        # first size again, with the same centre.
        $firstSize = @{}
        foreach ($cell in $oldModel.SelectNodes(".//mxCell[@vertex='1']")) {
            $owner = if ($cell.ParentNode.LocalName -eq 'object') { $cell.ParentNode } else { $cell }
            $geometry = $cell.SelectSingleNode('mxGeometry')
            if ($geometry) { $firstSize[$owner.GetAttribute('id')] = @{ Width = [double]$geometry.GetAttribute('width'); Height = [double]$geometry.GetAttribute('height') } }
        }
        foreach ($cell in $newModel.SelectNodes(".//mxCell[@vertex='1']")) {
            if ($cell.GetAttribute('style') -notmatch 'image=data:') { continue }
            $owner = if ($cell.ParentNode.LocalName -eq 'object') { $cell.ParentNode } else { $cell }
            $size  = $firstSize[$owner.GetAttribute('id')]
            $geometry = $cell.SelectSingleNode('mxGeometry')
            if (-not $size -or -not $geometry) { continue }
            $width  = [double]$geometry.GetAttribute('width')
            $height = [double]$geometry.GetAttribute('height')
            $geometry.SetAttribute('x', ([int][math]::Round([double]$geometry.GetAttribute('x') + ($width - $size.Width) / 2)).ToString())
            $geometry.SetAttribute('y', ([int][math]::Round([double]$geometry.GetAttribute('y') + ($height - $size.Height) / 2)).ToString())
            $geometry.SetAttribute('width', ([int]$size.Width).ToString())
            $geometry.SetAttribute('height', ([int]$size.Height).ToString())
        }

        [void]$Diagram.ReplaceChild($newModel, $oldModel)
        return $newModel
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-MissingItem {
    <# Adds the items of the view that the page does not have. Returns one line for each. #>
    [CmdletBinding()]
    param([hashtable]$Context, [hashtable]$Inventory, [object[]]$ViewItem, [string]$View = 'Edge')

    $cellOfMapId = @{}
    foreach ($node in $Context.Model.SelectNodes('.//*[@map_id]')) {
        $cellOfMapId[$node.GetAttribute('map_id')] = $node.GetAttribute('id')
    }

    # The new nodes go in one row below the lowest top-level cell.
    $bottom = $Top
    foreach ($geometry in $Context.Model.SelectNodes(".//mxCell[@vertex='1' and @parent='1']/mxGeometry")) {
        $bottomOfCell = [double]$geometry.GetAttribute('y') + [double]$geometry.GetAttribute('height')
        if ($bottomOfCell -gt $bottom) { $bottom = $bottomOfCell }
    }
    $rowY  = $bottom + 80
    $slotX = 40

    foreach ($item in @($ViewItem | Where-Object { $_.Type -in 'node', 'service', 'device', 'lane' })) {
        if ($cellOfMapId.ContainsKey($item.MapId)) {
            # The item is there: refresh its tooltip from the inventory. The script
            # does not change the place, the size or the label (Faginux can change them by hand).
            $node    = $Context.Model.SelectSingleNode(".//*[@map_id='$($item.MapId)']")
            $tooltip = Get-NodeTooltip -Inventory $Inventory -Item (Get-InventoryItem -Inventory $Inventory -Id $item.MapId)
            if ($node -and $node.GetAttribute('tooltip') -ne $tooltip) {
                $node.SetAttribute('tooltip', $tooltip)
                [pscustomobject]@{ Page = $View; MapId = $item.MapId; Type = $item.Type; Action = 'tooltip updated' }
            }
            continue
        }
        if ($item.Type -eq 'lane') {
            $cellOfMapId[$item.MapId] = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $item.MapId -X $slotX -Y $rowY -Width 380 -Height 200 -Lane -View $View
            $slotX += 420
        }
        else {
            $cellOfMapId[$item.MapId] = Add-NodeItem -Context $Context -Inventory $Inventory -MapId $item.MapId -X ($slotX + $SlotWidth / 2) -Y $rowY -View $View
            $slotX += $SlotWidth
        }
        [pscustomobject]@{ Page = $View; MapId = $item.MapId; Type = $item.Type; Action = 'added below the drawing: move it into place' }
    }

    foreach ($item in @($ViewItem | Where-Object { $_.Type -in 'route', 'link', 'uplink' })) {
        if ($cellOfMapId.ContainsKey($item.MapId)) { continue }
        $id = Add-EdgeItem -Context $Context -Inventory $Inventory -ViewItem $item -CellOfMapId $cellOfMapId -View $View
        $action = if ($id) { 'added' } else { 'not added: an end is not in the drawing' }
        if ($id) { $cellOfMapId[$item.MapId] = $id }
        [pscustomobject]@{ Page = $View; MapId = $item.MapId; Type = $item.Type; Action = $action }
    }
}

function Set-PageTheme {
    <#
    Applies $Theme to a page that is there (-Restyle): the background, and the
    style and the label of each item, line, title and legend. It does not
    change a place, a size or the bend points of a line. Only the legend can
    become taller, so that its text fits. Returns one line for the page.
    #>
    [CmdletBinding()]
    param([hashtable]$Context, [hashtable]$Inventory, [object[]]$ViewItem, [string]$View)

    $Context.Model.SetAttribute('background', $Theme.Background)
    $entryOf = @{}
    foreach ($entry in $ViewItem) { $entryOf[$entry.MapId] = $entry }
    $objectOf = @{}
    foreach ($object in $Context.Model.SelectNodes('.//object')) { $objectOf[$object.GetAttribute('id')] = $object }

    $changed = 0
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($object in @($Context.Model.SelectNodes('.//object'))) {
        $cell = $object.SelectSingleNode('mxCell')
        if (-not $cell) { continue }
        $mapId = $object.GetAttribute('map_id')
        $deco  = $object.GetAttribute('map_deco')
        $look  = $null

        if ($mapId) {
            $entry = $entryOf[$mapId]
            if (-not $entry) { $skipped.Add($mapId); continue }
            if ($entry.Type -in 'route', 'link', 'uplink') {
                $look = Get-EdgeItemLook -Inventory $Inventory -ViewItem $entry -View $View
            }
            else {
                $item = Get-InventoryItem -Inventory $Inventory -Id $mapId
                if ($entry.Type -eq 'lane') {
                    $look = Get-LaneLook -Item $item
                }
                else {
                    $look = @{
                        Style = (Get-VertexLook -Item $item -IconDirectory $IconDirectory).Style
                        Label = Get-NodeLabel -Inventory $Inventory -Item $item -View $View
                    }
                }
            }
        }
        else {
            # A decoration of v1.1 has no map_deco: find it by its place and text, then mark it.
            $parent = $objectOf[$cell.GetAttribute('parent')]
            $label  = $object.GetAttribute('label')
            if (-not $deco) {
                if ($parent -and $parent.GetAttribute('map_id') -and $cell.GetAttribute('style') -match 'image=data:') { $deco = 'lane-icon' }
                elseif ($label -match '^<b>Homelab map: ') { $deco = 'title' }
                elseif ($label -match '^<b>(Routes|Hosts|Media pipeline)</b>') { $deco = 'legend' }
                else { $skipped.Add($object.GetAttribute('id')); continue }
                $object.SetAttribute('map_deco', $deco)
            }
            switch ($deco) {
                'lane-icon' {
                    $laneItem = Get-InventoryItem -Inventory $Inventory -Id $parent.GetAttribute('map_id')
                    $style    = if ($laneItem -and $laneItem.Icon) { Get-IconTileStyle -Name $laneItem.Icon -ImageSize 20 } else { $null }
                    if ($style) { $look = @{ Style = $style; Label = '' } }
                }
                default { $look = Get-DecorationLook -Kind $deco -Page $View }
            }
            if ($deco -eq 'legend' -and $look) {
                $geometry = $cell.SelectSingleNode('mxGeometry')
                $needed   = 24 + 16 * ([regex]::Matches($look.Label, '<br>').Count + 1)
                if ($geometry -and [double]$geometry.GetAttribute('height') -lt $needed) { $geometry.SetAttribute('height', [string]$needed) }
            }
        }

        if (-not $look) { continue }
        if ($cell.GetAttribute('style') -ne $look.Style -or $object.GetAttribute('label') -ne $look.Label) {
            $cell.SetAttribute('style', $look.Style)
            $object.SetAttribute('label', $look.Label)
            $changed++
        }
    }
    $action = "theme applied: $changed cells changed"
    if ($skipped.Count -gt 0) { $action += "; not changed (not in the inventory or unknown): $($skipped -join ', ')" }
    [pscustomobject]@{ Page = $View; MapId = '*'; Type = 'theme'; Action = $action }
}

function Get-DocumentId {
    [CmdletBinding()]
    param([xml]$Document)

    $usedIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($node in $Document.SelectNodes('//*[@id]')) { [void]$usedIds.Add($node.GetAttribute('id')) }
    return , $usedIds
}

# --- Main ---

$inventory = Import-HomelabInventory -Path $InventoryPath
$document  = if (Test-Path -LiteralPath $OutputPath) { [xml](Get-Content -LiteralPath $OutputPath -Raw) } else { New-DrawioDocument }
$changes   = [System.Collections.Generic.List[object]]::new()

foreach ($pageName in @($PageOrder | Where-Object { $_ -in $View })) {
    $viewItem = @(Get-HomelabViewItem -Inventory $inventory -View $pageName)
    $diagram  = $document.SelectSingleNode("/mxfile/diagram[@name='$pageName']")
    $fullPage = $false

    if ($diagram -and $Force) {
        $newPage = New-DrawioPage -Document $document -Name $pageName
        [void]$document.DocumentElement.ReplaceChild($newPage, $diagram)
        $diagram  = $newPage
        $fullPage = $true
    }
    elseif ($diagram) {
        $model = ConvertFrom-HomelabDrawioPage -Diagram $diagram
        if ($model -and $model.OwnerDocument -ne $document) {
            # The page was compressed: keep it as plain XML from now on.
            $model = $document.ImportNode($model, $true)
            $diagram.InnerText = ''
            [void]$diagram.AppendChild($model)
        }
    }
    else {
        # A new page goes before the first page that comes after it in $PageOrder.
        $diagram = New-DrawioPage -Document $document -Name $pageName
        $later   = @($PageOrder | Select-Object -Skip ([array]::IndexOf($PageOrder, $pageName) + 1))
        $next    = $document.SelectNodes('/mxfile/diagram') | Where-Object { $_.GetAttribute('name') -in $later } | Select-Object -First 1
        if ($next) { [void]$document.DocumentElement.InsertBefore($diagram, $next) }
        else { [void]$document.DocumentElement.AppendChild($diagram) }
        $fullPage = $true
    }

    $model   = $diagram.SelectSingleNode('mxGraphModel')
    $root    = $model.SelectSingleNode('root')
    $context = @{
        Document = $document
        Model    = $model
        Root     = $root
        Layer    = $root.SelectSingleNode("mxCell[@id='1']")
        UsedIds  = (Get-DocumentId -Document $document)
    }

    if ($fullPage) {
        switch ($pageName) {
            'Edge' { Add-EdgePage -Context $context -Inventory $inventory -ViewItem $viewItem }
            'Hosts' { Add-HostsPage -Context $context -Inventory $inventory -ViewItem $viewItem }
            'Media' {
                Add-MediaPage -Context $context -Inventory $inventory -ViewItem $viewItem
                if ($MediaLayout) {
                    $laidOut = Optimize-MediaLayout -Document $document -Diagram $diagram -Layout $MediaLayout
                    if ($laidOut) {
                        $context.Model = $laidOut
                        $context.Root  = $laidOut.SelectSingleNode('root')
                        $context.Layer = $context.Root.SelectSingleNode("mxCell[@id='1']")
                        # The layout of draw.io writes a new model with no background: the page
                        # would be white in the PNG and in the SVG. Put the theme background back.
                        $laidOut.SetAttribute('background', $Theme.Background)
                    }
                }
                # Title and legend after the layout, so that the layout does not move them.
                $lowest = $Top
                foreach ($geometry in $context.Model.SelectNodes(".//mxCell[@vertex='1' and @parent='1']/mxGeometry")) {
                    $lowest = [math]::Max($lowest, [double]$geometry.GetAttribute('y') + [double]$geometry.GetAttribute('height'))
                }
                Add-PageDecoration -Context $context -Page 'Media' -LegendY ($lowest + 40) -LegendHeight 140
            }
        }
        $changes.Add([pscustomobject]@{ Page = $pageName; MapId = '*'; Type = 'page'; Action = "page made with $($viewItem.Count) items" })
    }
    else {
        foreach ($change in @(Add-MissingItem -Context $context -Inventory $inventory -ViewItem $viewItem -View $pageName)) { $changes.Add($change) }
        if ($Restyle) { $changes.Add((Set-PageTheme -Context $context -Inventory $inventory -ViewItem $viewItem -View $pageName)) }
    }
}

if ($changes.Count -eq 0) {
    Write-Information 'No change: the drawing has all the items of the inventory.' -InformationAction Continue
    return
}

if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the drawing')) {
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent             = $true
    $settings.Encoding           = [System.Text.UTF8Encoding]::new($false)
    $settings.OmitXmlDeclaration = $true
    # LF only: the repo keeps LF, and a CRLF file gives a full diff after each checkout.
    $settings.NewLineChars       = "`n"
    $writer = [System.Xml.XmlWriter]::Create([System.IO.Path]::GetFullPath($OutputPath), $settings)
    try { $document.Save($writer) } finally { $writer.Dispose() }
}
$changes
