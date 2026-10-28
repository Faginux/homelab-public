#Requires -Version 7.0
<#
  Test-HomelabMap.ps1  -  v1.2  (2026-10-26)
  Compares the inventory of the map (docs/map/inventory.psd1) with the real
  homelab and with the drawing. Run it on ARCADE: it needs the LAN, the
  tailnet and the SSH aliases the-grid and scope.

  Checks:
    CADDY     the routes of nodes/the-grid/caddy/Caddyfile: names,
              backends and exposure
    EXPOSURE  each Caddy route that is private by DNS only (no remote_ip,
              no CrowdSec)
    DNS       the public A records of each route (DNS over HTTPS, so the
              router, Diversion and NextDNS do not change the answer)
    RUNTIME   "docker ps -a" on each host with Docker = $true, and the
              Scheduled Tasks (Kind = task) of the local host
    PORT      one TCP connection to each route backend and each Endpoint
    HOMEPAGE  the cards of nodes/scope/homepage/conf/services.yaml
    DRAWING   the items with "map_id" in docs/map/homelab-map.drawio, and
              the two ends of each edge (v1.1)
    POSTER    docs/map/homelab-poster.svg was made from the inventory as it
              is now (the SHA-256 in the poster, v1.2), and each backup job
              of the inventory is in CALENDARIO-OPERAZIONI.md

  Output: one object for each finding, with Check, Severity, Item and Detail.
    ERROR  the script could not read a source
    WARN   a difference, or a risk that nobody accepted
    INFO   a known item, for example a risk that Faginux accepted
  Exit code: 0 = no WARN and no ERROR, 1 = one or more WARN, 2 = one or more ERROR.

  Read only. The script changes no host, no container and no file. The
  runtime check reads names and states only ("{{.Names}}|{{.State}}"): no
  environment, no command line. The port check opens a TCP connection and
  closes it at once. It sends no data.

  Tests:  -Skip Dns,Runtime,Port   skip the checks that use the network

  Created with Claude Code (Anthropic).
#>
[CmdletBinding()]
param(
    [string]$InventoryPath        = (Join-Path $PSScriptRoot '..\..\docs\map\inventory.psd1'),
    [string]$CaddyfilePath        = (Join-Path $PSScriptRoot '..\..\nodes\the-grid\caddy\Caddyfile'),
    [string]$HomepageServicesPath = (Join-Path $PSScriptRoot '..\..\nodes\scope\homepage\conf\services.yaml'),
    [string]$DrawingPath          = (Join-Path $PSScriptRoot '..\..\docs\map\homelab-map.drawio'),
    [string]$PosterPath           = (Join-Path $PSScriptRoot '..\..\docs\map\homelab-poster.svg'),
    [string]$CalendarPath         = (Join-Path $PSScriptRoot '..\..\CALENDARIO-OPERAZIONI.md'),

    [ValidateSet('Caddy', 'Exposure', 'Dns', 'Runtime', 'Port', 'Homepage', 'Drawing', 'Poster')]
    [string[]]$Skip = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HomelabMap.psm1') -Force

$script:Findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet('ERROR', 'WARN', 'INFO')][string]$Severity,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Detail
    )
    $script:Findings.Add([pscustomobject]@{ Check = $Check; Severity = $Severity; Item = $Item; Detail = $Detail })
}

function Split-Endpoint {
    [CmdletBinding()]
    param([string]$Endpoint)
    $address, $port = $Endpoint -split ':', 2
    return [pscustomobject]@{ Address = $address; Port = [int]$port }
}

$inventory   = Import-HomelabInventory -Path $InventoryPath
$caddyRoutes = @($inventory.Routes | Where-Object { $_.Via -eq 'caddy' })

# --- CADDY: the Caddyfile and the inventory have the same routes ---
if ('Caddy' -notin $Skip) {
    Write-Verbose 'CADDY: read the Caddyfile'
    try {
        $fileRoutes = @(Get-HomelabCaddyRoute -Path $CaddyfilePath)
        foreach ($fileRoute in $fileRoutes) {
            $known = $caddyRoutes | Where-Object { $_.Hostname -eq $fileRoute.Hostname } | Select-Object -First 1
            if (-not $known) {
                Add-Finding CADDY WARN $fileRoute.Hostname "in the Caddyfile, not in the inventory (backend $($fileRoute.Backend), $($fileRoute.Exposure))"
                continue
            }
            if ($known.Backend -ne $fileRoute.Backend) {
                Add-Finding CADDY WARN $fileRoute.Hostname "backend: inventory $($known.Backend), Caddyfile $($fileRoute.Backend)"
            }
            if ($known.Exposure -ne $fileRoute.Exposure) {
                Add-Finding CADDY WARN $fileRoute.Hostname "exposure: inventory $($known.Exposure), Caddyfile $($fileRoute.Exposure)"
            }
        }
        foreach ($known in $caddyRoutes) {
            if ($fileRoutes.Hostname -notcontains $known.Hostname) {
                Add-Finding CADDY WARN $known.Hostname 'in the inventory, not in the Caddyfile'
            }
        }
    }
    catch {
        Add-Finding CADDY ERROR $CaddyfilePath "cannot read the Caddyfile: $($_.Exception.Message)"
    }
}

# --- EXPOSURE: a Caddy route that is private by DNS only ---
if ('Exposure' -notin $Skip) {
    foreach ($route in @($caddyRoutes | Where-Object { $_.Exposure -eq 'dns-only' })) {
        if ($route.AcceptedRisk) {
            Add-Finding EXPOSURE INFO $route.Hostname "accepted risk: $($route.AcceptedRisk)"
            continue
        }
        Add-Finding EXPOSURE WARN $route.Hostname ("no remote_ip and no CrowdSec. Caddy sends this name to the backend for any client " +
            "that connects to the public IP (port forward 443) with this name, not only for the tailnet. " +
            "Add 'remote_ip $($inventory.TailnetCidr)' to the matcher, as for komodo and home.")
    }
}

# --- DNS: the public records agree with the exposure ---
if ('Dns' -notin $Skip) {
    $caddyService = $inventory.Services | Where-Object { $_.Id -eq 'caddy' } | Select-Object -First 1
    $caddyHost    = $inventory.Hosts | Where-Object { $_.Id -eq $caddyService.Host } | Select-Object -First 1
    $cloudflare   = @()
    try {
        $cloudflare = @(Get-HomelabCloudflareRange)
    }
    catch {
        Add-Finding DNS ERROR 'cloudflare-ranges' "cannot read the Cloudflare IP ranges, the proxy check is skipped: $($_.Exception.Message)"
    }
    $isCloudflare = {
        param([string]$Address)
        foreach ($range in $cloudflare) { if (Test-HomelabIpInCidr -Address $Address -Cidr $range) { return $true } }
        return $false
    }
    # The home public IP does not go into the output: the output can go into a log or a commit.
    $describe = {
        param([string]$Address)
        if (Test-HomelabIpInCidr -Address $Address -Cidr $inventory.TailnetCidr) { return $Address }
        if (& $isCloudflare $Address) { return "$Address (Cloudflare)" }
        return '<public address, not Cloudflare>'
    }

    foreach ($route in $inventory.Routes) {
        Write-Verbose "DNS: $($route.Hostname)"
        try {
            $answer = Resolve-HomelabPublicName -Hostname $route.Hostname
        }
        catch {
            Add-Finding DNS ERROR $route.Hostname "the DNS query failed: $($_.Exception.Message)"
            continue
        }
        $addresses = @($answer.Addresses)
        $inTailnet = @($addresses | Where-Object { Test-HomelabIpInCidr -Address $_ -Cidr $inventory.TailnetCidr })
        $shown     = if ($addresses.Count -gt 0) { ($addresses | ForEach-Object { & $describe $_ }) -join ', ' } else { 'no A record' }

        $cloudflareCount = @($addresses | Where-Object { & $isCloudflare $_ }).Count
        switch (Get-HomelabRouteDnsKind -Route $route) {
            'tailnet' {
                # A Caddy route must point to the Tailscale IP of the Caddy host, a direct record to its backend.
                $expected = if ($route.Via -eq 'direct') { (Split-Endpoint $route.Backend).Address } else { $caddyHost.Tailnet }
                if ($addresses.Count -eq 0) {
                    Add-Finding DNS WARN $route.Hostname "no A record. Expected: $expected"
                }
                elseif ($inTailnet.Count -ne $addresses.Count) {
                    Add-Finding DNS WARN $route.Hostname "A records: $shown. A public address sends this name through Cloudflare or the port forward. Expected: $expected"
                }
                elseif ($addresses.Count -ne 1 -or $addresses[0] -ne $expected) {
                    Add-Finding DNS WARN $route.Hostname "A records: $shown. Expected: $expected only"
                }
            }
            'proxied' {
                if ($addresses.Count -eq 0) {
                    Add-Finding DNS WARN $route.Hostname 'no A record. Expected: Cloudflare addresses (proxied)'
                }
                elseif ($inTailnet.Count -gt 0) {
                    Add-Finding DNS WARN $route.Hostname "A records: $shown. Expected: Cloudflare (proxied). If the tailnet address is correct, set Dns = 'tailnet'"
                }
                elseif ($cloudflare.Count -gt 0 -and $cloudflareCount -ne $addresses.Count) {
                    Add-Finding DNS WARN $route.Hostname "A records: $shown. Cloudflare does not proxy the name. If this is correct, set Dns = 'public-ip'"
                }
            }
            'public-ip' {
                if ($addresses.Count -eq 0) {
                    Add-Finding DNS WARN $route.Hostname 'no A record. Expected: the public IP (DNS only)'
                }
                elseif ($inTailnet.Count -gt 0 -or ($cloudflare.Count -gt 0 -and $cloudflareCount -gt 0)) {
                    Add-Finding DNS WARN $route.Hostname "A records: $shown. Expected: the public IP of the home (DNS only)"
                }
            }
            # No value (tailnet-enforced): Caddy blocks the clients outside the tailnet, any record is correct.
        }
    }
}

# --- RUNTIME: the containers of each Docker host ---
if ('Runtime' -notin $Skip) {
    foreach ($dockerHost in @($inventory.Hosts | Where-Object { $_.Docker })) {
        Write-Verbose "RUNTIME: $($dockerHost.Id)"
        try {
            $actual = @(Get-HomelabContainer -SshAlias @($dockerHost.Ssh))
        }
        catch {
            Add-Finding RUNTIME ERROR $dockerHost.Id "cannot read the containers: $($_.Exception.Message)"
            continue
        }
        $expected = @(foreach ($service in @($inventory.Services | Where-Object { $_.Host -eq $dockerHost.Id })) {
                foreach ($container in @($service.Containers | Where-Object { $_ })) {
                    [pscustomobject]@{ Service = $service.Id; Name = $container.Name; Pattern = $container.Pattern; State = $container.State }
                }
            })

        foreach ($container in $actual) {
            $item  = "$($dockerHost.Id)/$($container.Name)"
            $match = $expected | Where-Object {
                ($_.Name -and $_.Name -eq $container.Name) -or ($_.Pattern -and $container.Name -match $_.Pattern)
            } | Select-Object -First 1
            if (-not $match) {
                Add-Finding RUNTIME WARN $item "not in the inventory (state: $($container.State))"
                continue
            }
            if ($match.State -eq 'running' -and $container.State -ne 'running') {
                Add-Finding RUNTIME WARN $item "state: $($container.State). Expected: running"
            }
            if ($match.State -eq 'stopped' -and $container.State -eq 'running') {
                Add-Finding RUNTIME WARN $item 'running. Expected: stopped (look at the restart policy)'
            }
        }
        foreach ($entry in @($expected | Where-Object { $_.Name -and $_.State -ne 'job' })) {
            if ($actual.Name -notcontains $entry.Name) {
                Add-Finding RUNTIME WARN "$($dockerHost.Id)/$($entry.Name)" "no container with this name. Expected: $($entry.State) (service $($entry.Service))"
            }
        }
    }

    # Scheduled Tasks: only on the local host (the script runs on ARCADE).
    $localHost = @($inventory.Hosts | Where-Object { $_.Docker -and @($_.Ssh).Count -eq 0 }) | Select-Object -First 1
    foreach ($task in @($inventory.Services | Where-Object { $_.Kind -eq 'task' })) {
        $item = "$($task.Host)/task:$($task.TaskName)"
        if (-not $localHost -or $task.Host -ne $localHost.Id) {
            Add-Finding RUNTIME INFO $item 'not checked: the task is not on the local host'
            continue
        }
        $scheduled = Get-ScheduledTask -TaskName $task.TaskName -ErrorAction SilentlyContinue
        if (-not $scheduled) {
            Add-Finding RUNTIME WARN $item 'no Scheduled Task with this name'
        }
        elseif ($scheduled.State -eq 'Disabled') {
            Add-Finding RUNTIME WARN $item 'the Scheduled Task is disabled'
        }
    }
}

# --- PORT: each backend and each Endpoint accepts a TCP connection ---
if ('Port' -notin $Skip) {
    $targets = [ordered]@{}
    foreach ($route in $inventory.Routes) {
        if (-not $targets.Contains($route.Backend)) { $targets[$route.Backend] = $route.Hostname }
    }
    foreach ($service in @($inventory.Services | Where-Object { $_.Endpoint })) {
        if (-not $targets.Contains($service.Endpoint)) { $targets[$service.Endpoint] = $service.Id }
    }
    foreach ($target in $targets.GetEnumerator()) {
        Write-Verbose "PORT: $($target.Key)"
        $endpoint = Split-Endpoint $target.Key
        if (-not (Test-HomelabTcpPort -Address $endpoint.Address -Port $endpoint.Port)) {
            Add-Finding PORT WARN $target.Value "no TCP answer from $($target.Key)"
        }
    }
}

# --- HOMEPAGE: the cards and the inventory agree ---
if ('Homepage' -notin $Skip) {
    try {
        $cards = @(Get-HomelabHomepageService -Path $HomepageServicesPath)
        $routeHostnames = @($inventory.Routes | ForEach-Object { $_.Hostname })
        foreach ($card in $cards) {
            $service = $inventory.Services | Where-Object { $_.Homepage -eq $card.Name } | Select-Object -First 1
            if (-not $service) {
                Add-Finding HOMEPAGE WARN $card.Name "the card has no service in the inventory (key Homepage = '$($card.Name)')"
                continue
            }
            $endpoints = @($inventory.Routes | Where-Object { $_.Service -eq $service.Id } | ForEach-Object { $_.Backend })
            if ($service.Endpoint) { $endpoints += $service.Endpoint }
            if ($card.SiteMonitor) {
                $uri = [Uri]$card.SiteMonitor
                $monitored = "$($uri.Host):$($uri.Port)"
                if ($monitored -notin $endpoints) {
                    Add-Finding HOMEPAGE WARN $card.Name "siteMonitor $monitored is not a backend or the Endpoint of '$($service.Id)' ($($endpoints -join ', '))"
                }
            }
            if ($card.Href) {
                $hrefHost = ([Uri]$card.Href).Host
                if ($hrefHost -like "*.$($inventory.Domain)" -and $hrefHost -notin $routeHostnames) {
                    Add-Finding HOMEPAGE WARN $card.Name "href $($card.Href): the inventory has no route for $hrefHost"
                }
            }
        }
        foreach ($service in @($inventory.Services | Where-Object { $_.Homepage })) {
            if ($cards.Name -notcontains $service.Homepage) {
                Add-Finding HOMEPAGE WARN $service.Id "no card '$($service.Homepage)' in services.yaml"
            }
        }
    }
    catch {
        Add-Finding HOMEPAGE ERROR $HomepageServicesPath "cannot read services.yaml: $($_.Exception.Message)"
    }
}

# --- DRAWING: the drawing has the items of each view, and no other items ---
if ('Drawing' -notin $Skip) {
    if (-not (Test-Path -LiteralPath $DrawingPath)) {
        Add-Finding DRAWING WARN (Split-Path $DrawingPath -Leaf) 'no drawing. Run New-HomelabMap.ps1'
    }
    else {
        try {
            $cells = @(Get-HomelabDrawioCell -Path $DrawingPath)
            foreach ($view in @('Edge', 'Hosts', 'Media')) {
                $viewItems = @(Get-HomelabViewItem -Inventory $inventory -View $view)
                $expected  = @($viewItems | ForEach-Object { $_.MapId })
                $pageCells = @($cells | Where-Object { $_.Page -eq $view })
                if ($pageCells.Count -eq 0) {
                    Add-Finding DRAWING WARN $view "the page is not in the drawing, or it has no item with map_id. Run New-HomelabMap.ps1 -View $view"
                    continue
                }
                foreach ($group in @($pageCells | Group-Object MapId | Where-Object { $_.Count -gt 1 })) {
                    Add-Finding DRAWING WARN "$view/$($group.Name)" "the map_id is on $($group.Count) cells. Keep one (a copy in draw.io copies the map_id)"
                }
                foreach ($mapId in $expected) {
                    if ($pageCells.MapId -notcontains $mapId) {
                        Add-Finding DRAWING WARN "$view/$mapId" 'not in the drawing. Run New-HomelabMap.ps1 to add it'
                    }
                }
                foreach ($mapId in @($pageCells | ForEach-Object { $_.MapId } | Select-Object -Unique)) {
                    if ($mapId -notin $expected) {
                        Add-Finding DRAWING WARN "$view/$mapId" 'in the drawing, not in the inventory. Delete it in draw.io, or add it to the inventory'
                    }
                }
                # A manual edit in draw.io can disconnect an end of an edge. The line stays
                # on the page, but it does not move with the items any more.
                foreach ($item in @($viewItems | Where-Object { $_.Type -in 'route', 'uplink', 'link' })) {
                    $edgeCell = $pageCells | Where-Object { $_.MapId -eq $item.MapId } | Select-Object -First 1
                    if (-not $edgeCell) { continue }
                    if ($edgeCell.Source -ne $item.From -or $edgeCell.Target -ne $item.To) {
                        $found = "'$($edgeCell.Source)' -> '$($edgeCell.Target)'"
                        Add-Finding DRAWING WARN "$view/$($item.MapId)" "the edge connects $found, not '$($item.From)' -> '$($item.To)'. In draw.io, drag each end of the edge onto its item"
                    }
                }
            }
        }
        catch {
            Add-Finding DRAWING ERROR $DrawingPath "cannot read the drawing: $($_.Exception.Message)"
        }
    }
}

# --- POSTER: the poster was made from the inventory as it is now ---
if ('Poster' -notin $Skip) {
    $posterName = Split-Path $PosterPath -Leaf
    if (-not (Test-Path -LiteralPath $PosterPath)) {
        Add-Finding POSTER WARN $posterName 'no poster. Run Export-HomelabPoster.ps1'
    }
    else {
        # Export-HomelabPoster.ps1 writes the hash in a comment near the start of the file.
        $head = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PosterPath).Path)
        $head = $head.Substring(0, [math]::Min(600, $head.Length))
        $now  = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($head -notmatch 'inventory-sha256: ([0-9a-f]{64})') {
            Add-Finding POSTER WARN $posterName 'the poster has no inventory hash. Run Export-HomelabPoster.ps1'
        }
        elseif ($Matches[1] -ne $now) {
            Add-Finding POSTER WARN $posterName 'the poster is older than the inventory. Run Export-HomelabPoster.ps1'
        }
    }

    # The backup card comes from CALENDARIO-OPERAZIONI.md: each job must still be there.
    $backups = @($inventory['Backups'] | Where-Object { $_ -and $_.CalendarKey })
    if ($backups.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $CalendarPath)) {
            Add-Finding POSTER ERROR (Split-Path $CalendarPath -Leaf) 'cannot read the calendar of the automatic operations'
        }
        else {
            $calendar = Get-Content -LiteralPath $CalendarPath -Raw
            foreach ($backup in $backups) {
                if (-not $calendar.Contains($backup.CalendarKey)) {
                    Add-Finding POSTER WARN "backup:$($backup.Id)" "'$($backup.CalendarKey)' is not in CALENDARIO-OPERAZIONI.md. Update the inventory (Backups) or the calendar"
                }
            }
        }
    }
}

# --- Result ---
$script:Findings
$errors   = @($script:Findings | Where-Object { $_.Severity -eq 'ERROR' }).Count
$warnings = @($script:Findings | Where-Object { $_.Severity -eq 'WARN' }).Count
$notes    = @($script:Findings | Where-Object { $_.Severity -eq 'INFO' }).Count
Write-Information "Result: $errors ERROR, $warnings WARN, $notes INFO." -InformationAction Continue
if ($errors -gt 0) { exit 2 }
if ($warnings -gt 0) { exit 1 }
exit 0
