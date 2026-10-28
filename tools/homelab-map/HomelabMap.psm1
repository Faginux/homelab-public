#Requires -Version 7.0
<#
  HomelabMap.psm1  -  v1.0  (2026-10-20)
  Shared functions for the homelab map (docs/map). New-HomelabMap.ps1 makes
  the draw.io file from the inventory. Test-HomelabMap.ps1 compares the
  inventory, the drawing and the real state of the homelab.

  All the functions read only. No function changes a host, a container or a
  file of the repo.

  Created with Claude Code (Anthropic).
#>

# Version 1 only: the inventory is a set of hashtables with optional keys
# (Endpoint, Note, From...). A higher version stops at each missing key.
Set-StrictMode -Version 1.0

$script:ServiceKinds    = @('container', 'baremetal', 'job', 'task')
$script:ContainerStates = @('running', 'stopped', 'job')
$script:Exposures       = @('public-crowdsec', 'tailnet-enforced', 'dns-only')
$script:Views           = @('Edge', 'Hosts', 'Media')
# Only these views read a Layout block. The script computes the layout of the other views.
$script:LayoutViews     = @('Edge')

# Theme of the map and of the poster: neon colours on a dark background
# (synthwave). Faginux chose the background and the main colours on 2026-10-21
# (pink-magenta for secondary lines, orange for Scheduled Tasks only). To change a
# colour, change it here, then run New-HomelabMap.ps1 -Restyle and Export-HomelabMap.ps1.
$script:Theme = @{
    Background  = '#0D2633'   # page (Faginux: keep this value)
    Text        = '#E6F1FF'   # names and labels
    Muted       = '#8FB8CC'   # the second line of a label: route, address, host
    Title       = '#FCD303'
    Primary     = '#FCD303'   # yellow: main lines (public routes, cables, media flow)
    Secondary   = '#FF3CAC'   # pink-magenta: secondary lines
    Task        = '#FC9803'   # orange: Scheduled Tasks only
    Private     = '#44C412'   # green: routes for the tailnet only
    Accent      = '#00E5FF'   # cyan: direct DNS records, reads, storage
    Alarm       = '#FF3B30'   # red: a risk (private by DNS only)
    Group       = '#D703FC'   # purple: border of a host box
    GroupFill   = '#2A0F45'   # header of a host box
    Network     = '#44C412'   # green: border of the Wi-Fi box and of the legend
    NetworkFill = '#0E3320'   # header of the Wi-Fi box
    Panel       = '#12384A'   # fill of tiles, boxes and the legend
    TileBorder  = '#2B6680'   # border of a tile
    LightTile   = '#C9DCE6'   # tile of a dark icon (Tile = 'light' in icons.psd1)
}

function Get-HomelabTheme {
    <#
    .SYNOPSIS
    Gives a copy of the theme (colour name -> #RRGGBB) of the map and the poster.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:Theme.Clone()
}

function Get-HomelabLightTileIcon {
    <#
    .SYNOPSIS
    Gives the icons that need a light tile (Tile = 'light' in icons.psd1), as
    a hashtable name -> $true. They are dark and not visible on the dark theme.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$IconDirectory
    )

    $result   = @{}
    $manifest = Join-Path $IconDirectory 'icons.psd1'
    if (Test-Path -LiteralPath $manifest) {
        foreach ($icon in (Import-PowerShellDataFile -LiteralPath $manifest).Icons) {
            if ($icon.Tile -eq 'light') { $result[$icon.Name] = $true }
        }
    }
    return $result
}

function Get-HomelabRouteSource {
    <#
    .SYNOPSIS
    Gives the map id of the node where the request of a route starts in the map.
    A Caddy route starts at "caddy". A direct DNS record sets "From".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Route
    )

    if ($Route.From) { return $Route.From }
    return 'caddy'
}

function Get-HomelabRouteDnsKind {
    <#
    .SYNOPSIS
    Gives the expected public DNS of a route: proxied (Cloudflare proxy),
    public-ip (DNS only, the public IP of the home) or tailnet (DNS only, a
    Tailscale IP). The key Dns of the route sets it. With no Dns key: a direct
    record and a dns-only route expect tailnet, a public-crowdsec route expects
    proxied, a tailnet-enforced route has no expectation ($null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Route
    )

    if ($Route.Dns) { return $Route.Dns }
    if ($Route.Via -eq 'direct') { return 'tailnet' }
    switch ($Route.Exposure) {
        'public-crowdsec' { return 'proxied' }
        'dns-only' { return 'tailnet' }
    }
    return $null
}

function Get-HomelabLayoutEntry {
    <#
    .SYNOPSIS
    Gives the entries of one layout column as objects with Id and At. An entry
    is an Id, or a hashtable @{ Id = '...'; At = 0.35 }. At is the vertical
    place, from 0 (top) to 1 (bottom). With no At, the nodes are spread evenly.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Column
    )

    foreach ($entry in $Column) {
        if ($entry -is [hashtable]) { [pscustomobject]@{ Id = [string]$entry.Id; At = $entry.At } }
        else { [pscustomobject]@{ Id = [string]$entry; At = $null } }
    }
}

function Import-HomelabInventory {
    <#
    .SYNOPSIS
    Reads the inventory file (.psd1) and checks its structure.
    .OUTPUTS
    The inventory as a hashtable. If the file is not valid, the function stops
    with an error that lists all the problems.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $inventory = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    $problems  = [System.Collections.Generic.List[string]]::new()

    foreach ($key in 'Domain', 'TailnetCidr', 'Hosts', 'Nodes', 'Services', 'Routes', 'Links', 'Layout') {
        if (-not $inventory.ContainsKey($key)) { $problems.Add("the key '$key' is missing") }
    }
    if ($problems.Count -gt 0) {
        throw "Inventory '$Path' is not valid:`n - $($problems -join "`n - ")"
    }

    # One Id space for hosts, nodes and services: the Id is the map_id in the drawing.
    $ids = @{}
    foreach ($group in 'Hosts', 'Nodes', 'Services') {
        foreach ($item in $inventory[$group]) {
            if (-not $item.Id) { $problems.Add("$group has an item with no Id"); continue }
            if ($ids.ContainsKey($item.Id)) { $problems.Add("the Id '$($item.Id)' is used two times") }
            $ids[$item.Id] = $group
        }
    }

    # Uplink: the device or the network of the connection (an Id in Hosts or Nodes).
    foreach ($item in @($inventory.Hosts) + @($inventory.Nodes)) {
        if ($item.Uplink -and $ids[$item.Uplink] -notin 'Hosts', 'Nodes') {
            $problems.Add("'$($item.Id)': Uplink '$($item.Uplink)' is not in Hosts or Nodes")
        }
    }

    foreach ($service in $inventory.Services) {
        if ($ids[$service.Host] -ne 'Hosts') {
            $problems.Add("service '$($service.Id)': the host '$($service.Host)' is not in Hosts")
        }
        if ($service.Kind -notin $script:ServiceKinds) {
            $problems.Add("service '$($service.Id)': Kind '$($service.Kind)' is not one of: $($script:ServiceKinds -join ', ')")
        }
        foreach ($container in @($service.Containers)) {
            if (-not $container) { continue }
            if (-not ($container.Name -or $container.Pattern)) {
                $problems.Add("service '$($service.Id)': a container has no Name and no Pattern")
            }
            if ($container.State -notin $script:ContainerStates) {
                $problems.Add("service '$($service.Id)': container state '$($container.State)' is not one of: $($script:ContainerStates -join ', ')")
            }
        }
        if ($service.Kind -eq 'task' -and -not $service.TaskName) {
            $problems.Add("service '$($service.Id)': Kind task needs TaskName (the name in the Task Scheduler)")
        }
        if ($service.Endpoint -and $service.Endpoint -notmatch '^\d{1,3}(\.\d{1,3}){3}:\d+$') {
            $problems.Add("service '$($service.Id)': Endpoint '$($service.Endpoint)' is not <IPv4>:<port>")
        }
    }

    $hostnames = @{}
    foreach ($route in $inventory.Routes) {
        if ($hostnames.ContainsKey($route.Hostname)) { $problems.Add("the route '$($route.Hostname)' is there two times") }
        $hostnames[$route.Hostname] = $true
        if ($ids[$route.Service] -ne 'Services') {
            $problems.Add("route '$($route.Hostname)': the service '$($route.Service)' is not in Services")
        }
        if ($route.Via -notin 'caddy', 'direct') {
            $problems.Add("route '$($route.Hostname)': Via must be 'caddy' or 'direct'")
        }
        if ($route.Exposure -notin $script:Exposures) {
            $problems.Add("route '$($route.Hostname)': Exposure '$($route.Exposure)' is not one of: $($script:Exposures -join ', ')")
        }
        if ($route.Backend -notmatch '^\d{1,3}(\.\d{1,3}){3}:\d+$') {
            $problems.Add("route '$($route.Hostname)': Backend '$($route.Backend)' is not <IPv4>:<port>")
        }
        if ($route.Dns -and $route.Dns -notin 'proxied', 'public-ip', 'tailnet') {
            $problems.Add("route '$($route.Hostname)': Dns '$($route.Dns)' is not one of: proxied, public-ip, tailnet")
        }
        $source = Get-HomelabRouteSource -Route $route
        if (-not $ids.ContainsKey($source)) {
            $problems.Add("route '$($route.Hostname)': the start node '$source' is not in the inventory")
        }
    }

    foreach ($link in $inventory.Links) {
        foreach ($end in 'From', 'To') {
            if (-not $ids.ContainsKey($link[$end])) {
                $problems.Add("link '$($link.Id)': $end '$($link[$end])' is not in the inventory")
            }
        }
        if ($link.Kind -and $link.Kind -notin 'data', 'control', 'read') {
            $problems.Add("link '$($link.Id)': Kind '$($link.Kind)' is not one of: data, control, read")
        }
        if ($link.View -notin $script:Views) {
            $problems.Add("link '$($link.Id)': View '$($link.View)' is not one of: $($script:Views -join ', ')")
        }
    }

    foreach ($view in $script:LayoutViews) {
        $layout = $inventory.Layout[$view]
        if (-not $layout) { $problems.Add("Layout.$view is missing"); continue }
        $placed = @{}
        foreach ($column in $layout.Columns) {
            foreach ($entry in (Get-HomelabLayoutEntry -Column $column)) {
                if (-not $ids.ContainsKey($entry.Id)) { $problems.Add("Layout.$view.Columns: '$($entry.Id)' is not in the inventory") }
                if ($null -ne $entry.At -and ($entry.At -lt 0 -or $entry.At -gt 1)) {
                    $problems.Add("Layout.$view.Columns: At of '$($entry.Id)' is not between 0 and 1")
                }
                $placed[$entry.Id] = $true
            }
        }
        foreach ($laneHost in $layout.Lanes) {
            if ($ids[$laneHost] -ne 'Hosts') { $problems.Add("Layout.$view.Lanes: '$laneHost' is not in Hosts") }
        }
        # Each routed service must have a place: a column, or the lane of its host.
        foreach ($route in $inventory.Routes) {
            $service = $inventory.Services | Where-Object { $_.Id -eq $route.Service } | Select-Object -First 1
            if (-not $service) { continue }
            if (-not $placed.ContainsKey($service.Id) -and $service.Host -notin $layout.Lanes) {
                $problems.Add("Layout.$view`: the routed service '$($service.Id)' has no column and its host '$($service.Host)' has no lane")
            }
        }
    }

    # Backups is optional: the card "Backup" of the poster.
    $backupIds = @{}
    foreach ($backup in @($inventory['Backups'] | Where-Object { $_ })) {
        if (-not $backup.Id) { $problems.Add('Backups has an item with no Id'); continue }
        if ($backupIds.ContainsKey($backup.Id)) { $problems.Add("backup '$($backup.Id)' is there two times") }
        $backupIds[$backup.Id] = $true
        foreach ($key in 'From', 'To') {
            if ($ids[$backup[$key]] -ne 'Hosts') { $problems.Add("backup '$($backup.Id)': $key '$($backup[$key])' is not in Hosts") }
        }
        if (-not $backup.Schedule) { $problems.Add("backup '$($backup.Id)': no Schedule") }
    }

    # Layout.Poster is optional: the steps of the card "Media pipeline" of the poster,
    # and the host of the card "Backup".
    $poster = $inventory.Layout['Poster']
    if ($poster -and $poster.BackupUnder -and $ids[$poster.BackupUnder] -ne 'Hosts') {
        $problems.Add("Layout.Poster.BackupUnder: '$($poster.BackupUnder)' is not in Hosts")
    }
    foreach ($step in @($poster.Pipeline | Where-Object { $_ })) {
        if (-not $step.Step) { $problems.Add('Layout.Poster.Pipeline: a step has no name (Step)') }
        foreach ($id in @($step.Items)) {
            if ($ids[$id] -ne 'Services') { $problems.Add("Layout.Poster.Pipeline, step '$($step.Step)': '$id' is not in Services") }
        }
    }

    if ($problems.Count -gt 0) {
        throw "Inventory '$Path' is not valid:`n - $($problems -join "`n - ")"
    }
    return $inventory
}

function Get-HomelabViewItem {
    <#
    .SYNOPSIS
    Gives the items (nodes, lanes, services, devices and edges) that a view of
    the map must show. New-HomelabMap.ps1 draws these items, and
    Test-HomelabMap.ps1 looks for them in the drawing.
    .DESCRIPTION
    Edge: the columns and lanes of Layout.Edge, the routed services, the
    routes and the links of the view.
    Hosts: the network and all the services. Each server host is a lane with
    all its services. A node of Kind 'wireless' is a lane with the devices
    that use it (no edge for them). Each other Uplink is an edge
    "uplink:<id>" from the Uplink to the item. A node shows only if it has
    an Uplink or a link of the view.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Inventory,

        [ValidateSet('Edge', 'Hosts', 'Media')]
        [string]$View = 'Edge'
    )

    if ($View -eq 'Media') {
        # The page Media has the items at the ends of its links, and the links.
        $links = @($Inventory.Links | Where-Object { $_.View -eq $View })
        $seen  = @{}
        foreach ($id in @($links | ForEach-Object { $_.From; $_.To })) {
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            [pscustomobject]@{ MapId = $id; Type = 'node'; Lane = $null }
        }
        foreach ($link in $links) {
            [pscustomobject]@{ MapId = "link:$($link.Id)"; Type = 'link'; Lane = $null; From = $link.From; To = $link.To }
        }
        return
    }

    if ($View -eq 'Hosts') {
        $wireless = @($Inventory.Nodes | Where-Object { $_.Kind -eq 'wireless' } | ForEach-Object { $_.Id })
        $links    = @($Inventory.Links | Where-Object { $_.View -eq $View })
        $linked   = @($links | ForEach-Object { $_.From; $_.To })
        foreach ($node in $Inventory.Nodes) {
            if ($node.Id -in $wireless) { [pscustomobject]@{ MapId = $node.Id; Type = 'lane'; Lane = $null } }
            elseif ($node.Uplink -or $node.Id -in $linked) { [pscustomobject]@{ MapId = $node.Id; Type = 'node'; Lane = $null } }
        }
        foreach ($item in $Inventory.Hosts) {
            if ($item.Kind -eq 'server') {
                [pscustomobject]@{ MapId = $item.Id; Type = 'lane'; Lane = $null }
                # Scheduled Tasks are on the page Media, not in the boxes of the hosts.
                foreach ($service in @($Inventory.Services | Where-Object { $_.Host -eq $item.Id -and $_.Kind -ne 'task' })) {
                    [pscustomobject]@{ MapId = $service.Id; Type = 'service'; Lane = $item.Id }
                }
            }
            elseif ($item.Uplink -and $item.Uplink -in $wireless) {
                [pscustomobject]@{ MapId = $item.Id; Type = 'device'; Lane = $item.Uplink }
            }
            else {
                [pscustomobject]@{ MapId = $item.Id; Type = 'node'; Lane = $null }
            }
        }
        foreach ($item in @($Inventory.Hosts) + @($Inventory.Nodes)) {
            if ($item.Uplink -and $item.Uplink -notin $wireless) {
                [pscustomobject]@{ MapId = "uplink:$($item.Id)"; Type = 'uplink'; Lane = $null; From = $item.Uplink; To = $item.Id }
            }
        }
        foreach ($link in $links) {
            [pscustomobject]@{ MapId = "link:$($link.Id)"; Type = 'link'; Lane = $null; From = $link.From; To = $link.To }
        }
        return
    }

    $layout   = $Inventory.Layout[$View]
    $placed   = @{}
    $routedId = @($Inventory.Routes | ForEach-Object { $_.Service })

    foreach ($column in $layout.Columns) {
        foreach ($entry in (Get-HomelabLayoutEntry -Column $column)) {
            $placed[$entry.Id] = $true
            [pscustomobject]@{ MapId = $entry.Id; Type = 'node'; Lane = $null }
        }
    }
    foreach ($laneHost in $layout.Lanes) {
        [pscustomobject]@{ MapId = $laneHost; Type = 'lane'; Lane = $null }
        $services = $Inventory.Services | Where-Object {
            $_.Host -eq $laneHost -and -not $placed.ContainsKey($_.Id) -and $_.Id -in $routedId
        }
        foreach ($service in $services) {
            $placed[$service.Id] = $true
            [pscustomobject]@{ MapId = $service.Id; Type = 'service'; Lane = $laneHost }
        }
    }
    foreach ($link in ($Inventory.Links | Where-Object { $_.View -eq $View })) {
        [pscustomobject]@{ MapId = "link:$($link.Id)"; Type = 'link'; Lane = $null; From = $link.From; To = $link.To }
    }
    foreach ($route in $Inventory.Routes) {
        [pscustomobject]@{
            MapId = "route:$($route.Hostname)"; Type = 'route'; Lane = $null
            From  = Get-HomelabRouteSource -Route $route; To = $route.Service
        }
    }
}

function Get-HomelabCaddyRoute {
    <#
    .SYNOPSIS
    Reads the routes of a Caddyfile: one object for each host name in a
    "handle @matcher" block.
    .DESCRIPTION
    Exposure rules:
      tailnet-enforced  the matcher has "remote_ip"
      public-crowdsec   the handle block has the "crowdsec" directive
      dns-only          neither: only the DNS record keeps the route private
    The parser knows the patterns of this repo only: "@name host <names>" on one
    line, "@name { host ...; remote_ip ... }" as a block, and "handle @name { }".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $lines    = @(Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object { ($_ -replace '#.*$', '').Trim() })
    $matchers = @{}
    $index    = 0

    # First pass: the named matchers.
    while ($index -lt $lines.Count) {
        $line = $lines[$index]
        if ($line -match '^@(\S+)\s+host\s+(.+)$') {
            $matchers[$Matches[1]] = @{ Hosts = @($Matches[2] -split '\s+'); RemoteIp = @() }
        }
        elseif ($line -match '^@(\S+)\s*\{$') {
            $name = $Matches[1]
            $entry = @{ Hosts = @(); RemoteIp = @() }
            $index++
            while ($index -lt $lines.Count -and $lines[$index] -ne '}') {
                if ($lines[$index] -match '^host\s+(.+)$')      { $entry.Hosts    += @($Matches[1] -split '\s+') }
                if ($lines[$index] -match '^remote_ip\s+(.+)$') { $entry.RemoteIp += @($Matches[1] -split '\s+') }
                $index++
            }
            $matchers[$name] = $entry
        }
        $index++
    }

    # Second pass: the handle blocks.
    $index = 0
    while ($index -lt $lines.Count) {
        if ($lines[$index] -match '^handle\s+@(\S+)\s*\{$') {
            $name     = $Matches[1]
            $depth    = 1
            $crowdsec = $false
            $backend  = $null
            $index++
            while ($index -lt $lines.Count -and $depth -gt 0) {
                $line = $lines[$index]
                if ($line -eq 'crowdsec') { $crowdsec = $true }
                if (-not $backend -and $line -match '^reverse_proxy\s+([^\s{]+)') { $backend = $Matches[1] }
                $depth += ([regex]::Matches($line, '\{').Count - [regex]::Matches($line, '\}').Count)
                $index++
            }
            $matcher  = $matchers[$name]
            $hosts    = @(if ($matcher) { $matcher.Hosts })
            $remoteIp = @(if ($matcher) { $matcher.RemoteIp })
            $exposure = if ($remoteIp.Count -gt 0) { 'tailnet-enforced' } elseif ($crowdsec) { 'public-crowdsec' } else { 'dns-only' }
            foreach ($hostname in $hosts) {
                [pscustomobject]@{
                    Hostname = $hostname
                    Matcher  = $name
                    Backend  = $backend
                    Exposure = $exposure
                    CrowdSec = $crowdsec
                    RemoteIp = ($remoteIp -join ' ')
                }
            }
            continue
        }
        $index++
    }
}

function Get-HomelabHomepageService {
    <#
    .SYNOPSIS
    Reads the cards of the Homepage file services.yaml: group, name, href and
    siteMonitor. A small line parser for the layout of this repo (groups at
    column 0, cards at 4 spaces, fields at 8 spaces). Comment lines are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $group   = $null
    $current = $null
    foreach ($raw in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        if ($raw.TrimStart().StartsWith('#') -or -not $raw.Trim()) { continue }
        if ($raw -match '^- (.+?):\s*$') {
            if ($current) { [pscustomobject]$current }
            $current = $null
            $group   = $Matches[1]
            continue
        }
        if ($raw -match '^    - (.+?):\s*$') {
            if ($current) { [pscustomobject]$current }
            $current = [ordered]@{ Group = $group; Name = $Matches[1]; Href = $null; SiteMonitor = $null; Icon = $null }
            continue
        }
        if (-not $current) { continue }
        if ($raw -match '^        href:\s*(\S+)')        { $current.Href        = $Matches[1] }
        if ($raw -match '^        siteMonitor:\s*(\S+)') { $current.SiteMonitor = $Matches[1] }
        if ($raw -match '^        icon:\s*(\S+)')        { $current.Icon        = $Matches[1] }
    }
    if ($current) { [pscustomobject]$current }
}

function ConvertFrom-HomelabDrawioPage {
    <#
    .SYNOPSIS
    Gives the mxGraphModel element of one page (<diagram>) of a draw.io file.
    The page can be plain XML or compressed (base64 + raw deflate + URL encoding).
    #>
    [CmdletBinding()]
    [OutputType([System.Xml.XmlElement])]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Diagram
    )

    $model = $Diagram.SelectSingleNode('mxGraphModel')
    if ($model) { return $model }

    $text = $Diagram.InnerText.Trim()
    if (-not $text) { return $null }
    $stream  = [System.IO.MemoryStream]::new([Convert]::FromBase64String($text))
    $deflate = [System.IO.Compression.DeflateStream]::new($stream, [System.IO.Compression.CompressionMode]::Decompress)
    $reader  = [System.IO.StreamReader]::new($deflate, [System.Text.Encoding]::UTF8)
    try {
        $decoded = [Uri]::UnescapeDataString($reader.ReadToEnd())
    }
    finally {
        $reader.Dispose()
    }
    $page = [xml]$decoded
    return $page.DocumentElement
}

function Get-HomelabDrawioCell {
    <#
    .SYNOPSIS
    Gives the cells of a draw.io file that have the custom property "map_id".
    For an edge, Source and Target are the map_id of the cells at its two ends
    (empty when the end is not connected to a cell with a map_id).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $document = [xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
    foreach ($diagram in $document.SelectNodes('/mxfile/diagram')) {
        $model = ConvertFrom-HomelabDrawioPage -Diagram $diagram
        if (-not $model) { continue }
        $nodes = @($model.SelectNodes('.//*[@map_id]'))
        $mapIdOfCell = @{}
        foreach ($node in $nodes) { $mapIdOfCell[$node.GetAttribute('id')] = $node.GetAttribute('map_id') }
        foreach ($node in $nodes) {
            $cell = if ($node.LocalName -eq 'mxCell') { $node } else { $node.SelectSingleNode('mxCell') }
            $kind = if ($cell -and $cell.GetAttribute('edge') -eq '1') { 'edge' } else { 'vertex' }
            $source = ''
            $target = ''
            if ($kind -eq 'edge') {
                $source = [string]$mapIdOfCell[$cell.GetAttribute('source')]
                $target = [string]$mapIdOfCell[$cell.GetAttribute('target')]
            }
            [pscustomobject]@{
                Page   = $diagram.GetAttribute('name')
                MapId  = $node.GetAttribute('map_id')
                Kind   = $kind
                CellId = $node.GetAttribute('id')
                Label  = $node.GetAttribute('label')
                Source = $source
                Target = $target
            }
        }
    }
}

function Get-HomelabContainer {
    <#
    .SYNOPSIS
    Gives the name and the state of all the containers of one host
    ("docker ps -a"). With no SSH alias, the function reads the local host.
    With more than one alias, it uses the first alias that answers.
    .NOTES
    The format has name and state only: no command line, no environment.
    #>
    [CmdletBinding()]
    param(
        [string[]]$SshAlias = @()
    )

    $format = '{{.Names}}|{{.State}}'
    $output = $null
    $via    = 'local'
    if ($SshAlias.Count -eq 0) {
        $output = docker ps -a --format $format 2>$null
        if ($LASTEXITCODE -ne 0) { throw "docker ps failed on the local host (exit code $LASTEXITCODE)" }
    }
    else {
        foreach ($alias in $SshAlias) {
            $output = ssh -o BatchMode=yes -o ConnectTimeout=8 $alias "docker ps -a --format '$format'" 2>$null
            if ($LASTEXITCODE -eq 0) { $via = $alias; break }
            $output = $null
        }
        if ($via -eq 'local') { throw "no SSH alias answered: $($SshAlias -join ', ')" }
    }

    foreach ($line in @($output)) {
        if (-not $line) { continue }
        $name, $state = $line -split '\|', 2
        [pscustomobject]@{ Name = $name; State = $state; Via = $via }
    }
}

function Resolve-HomelabPublicName {
    <#
    .SYNOPSIS
    Gives the public A records of a host name. The query goes to a public
    DNS-over-HTTPS resolver, so the router, Diversion and NextDNS do not
    change the answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Hostname,

        [string]$Resolver = 'https://cloudflare-dns.com/dns-query'
    )

    $uri    = '{0}?name={1}&type=A' -f $Resolver, [Uri]::EscapeDataString($Hostname)
    $answer = Invoke-RestMethod -Uri $uri -Headers @{ Accept = 'application/dns-json' } -TimeoutSec 10 -ErrorAction Stop
    $records = if ($answer.PSObject.Properties['Answer']) { @($answer.Answer) } else { @() }

    [pscustomobject]@{
        Hostname  = $Hostname
        Status    = $answer.Status
        Addresses = @($records | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
    }
}

function Get-HomelabCloudflareRange {
    <#
    .SYNOPSIS
    Gives the IPv4 ranges of the Cloudflare edge, from the list that Cloudflare
    publishes. The DNS check uses them to tell a proxied name from a DNS-only name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Uri = 'https://www.cloudflare.com/ips-v4'
    )

    $text = Invoke-RestMethod -Uri $Uri -TimeoutSec 10 -ErrorAction Stop
    $ranges = @($text -split '\s+' | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' })
    if ($ranges.Count -eq 0) { throw "no IPv4 range in the answer of $Uri" }
    return $ranges
}

function Test-HomelabIpInCidr {
    <#
    .SYNOPSIS
    Tells if an IPv4 address is in an IPv4 CIDR block (example: 100.64.0.0/10).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [Parameter(Mandatory)]
        [string]$Cidr
    )

    $network, $bits = $Cidr -split '/', 2
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    $addressBytes = $parsed.GetAddressBytes()
    $networkBytes = [System.Net.IPAddress]::Parse($network).GetAddressBytes()
    if ($addressBytes.Length -ne 4 -or $networkBytes.Length -ne 4) { return $false }

    $toNumber = { param([byte[]]$b) ([uint64]$b[0] -shl 24) -bor ([uint64]$b[1] -shl 16) -bor ([uint64]$b[2] -shl 8) -bor [uint64]$b[3] }
    # 4294967295 = 32 bits set. Do not write 0xFFFFFFFF: PowerShell reads it as the Int32 -1.
    $allBits = [uint64]4294967295
    $mask = ($allBits -shl (32 - [int]$bits)) -band $allBits
    return ((& $toNumber $addressBytes) -band $mask) -eq ((& $toNumber $networkBytes) -band $mask)
}

function Test-HomelabTcpPort {
    <#
    .SYNOPSIS
    Tells if a TCP port accepts a connection. The function opens the
    connection and closes it at once. It sends no data.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMs = 2000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Address, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-HomelabIconDataUri {
    <#
    .SYNOPSIS
    Gives an icon of docs/map/icons (.svg first, then .png) as a data URI for
    a draw.io style. draw.io wants "data:<type>,<base64>" with no ";base64":
    the ";" is the separator of the style string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$IconDirectory,

        [Parameter(Mandatory)]
        [string]$Name
    )

    foreach ($format in @(@{ Extension = 'svg'; Type = 'image/svg+xml' }, @{ Extension = 'png'; Type = 'image/png' })) {
        $file = Join-Path $IconDirectory "$Name.$($format.Extension)"
        if (Test-Path -LiteralPath $file) {
            return "data:$($format.Type)," + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file))
        }
    }
    return $null
}

Export-ModuleMember -Function @(
    'ConvertFrom-HomelabDrawioPage'
    'Get-HomelabCaddyRoute'
    'Get-HomelabCloudflareRange'
    'Get-HomelabContainer'
    'Get-HomelabDrawioCell'
    'Get-HomelabHomepageService'
    'Get-HomelabIconDataUri'
    'Get-HomelabLayoutEntry'
    'Get-HomelabLightTileIcon'
    'Get-HomelabRouteDnsKind'
    'Get-HomelabRouteSource'
    'Get-HomelabTheme'
    'Get-HomelabViewItem'
    'Import-HomelabInventory'
    'Resolve-HomelabPublicName'
    'Test-HomelabIpInCidr'
    'Test-HomelabTcpPort'
)
