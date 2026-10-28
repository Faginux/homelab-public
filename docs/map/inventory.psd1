# Inventory of the homelab map. Written on 2026-10-20 from "docker ps -a" on the
# three hosts, the Caddyfile of the-grid, Homepage (services.yaml) and "tailscale status".
#
# This file is the source of the map:
#   tools/homelab-map/New-HomelabMap.ps1   draws docs/map/homelab-map.drawio from it.
#   tools/homelab-map/Test-HomelabMap.ps1  compares it with the hosts, the Caddyfile,
#                                         Homepage, the public DNS and the drawing.
# When the homelab changes, change this file first. Then run the test.
#
# Rules:
# - Id: one name space for Hosts, Nodes and Services. The Id is the "map_id" in the drawing.
# - Services.Kind: container, baremetal, job or task. A task is a Scheduled Task of the
#   host (key TaskName): it shows on the page Media, and the test checks it.
# - Containers.State: running = must run. stopped = must exist and must not run.
#   job = "docker compose run --rm": no container between two runs.
# - Containers.Pattern: a regex for job containers with a generated name.
# - Endpoint: <IPv4>:<port> that the test opens (TCP only, no data).
# - Homepage: the name of the card in nodes/scope/homepage/conf/services.yaml.
# - Routes.Exposure: public-crowdsec, tailnet-enforced (Caddy remote_ip) or dns-only.
#   Via = caddy: a route of the Caddyfile. Via = direct: a DNS record with no Caddy.
# - Routes.Dns: the expected public DNS. proxied = Cloudflare proxy. public-ip = DNS
#   only, the public IP of the home. tailnet = DNS only, a Tailscale IP. With no Dns:
#   public-crowdsec expects proxied, dns-only and direct expect tailnet.
# - Uplink (Hosts and Nodes): the connection of the item, an Id of Hosts or Nodes
#   (the switch, the router, 'wifi'). On the page Hosts it is a cable from the
#   Uplink to the item, with the text UplinkLabel. The devices of a node with
#   Kind = 'wireless' go in the box of that node, with no line. Data from Faginux,
#   2026-10-20.
# - Routes.AcceptedRisk: write the reason and the date to change the dns-only
#   warning of the test into information. Only Faginux sets it.
# - Detail (Hosts and Nodes): the second line of the item on the network row of the poster.
# - Tagline and Hardware (server hosts): the text of the host card on the poster
#   (tools/homelab-map/Export-HomelabPoster.ps1). Read on 2026-10-26 with lscpu,
#   free, lsblk (the-grid, scope) and Get-CimInstance, Get-PhysicalDisk (ARCADE).
# - Hardware.Volumes (ARCADE): one entry for each disk letter. The poster does not use it.
#   Read on 2026-09-03 with Get-PhysicalDisk and Get-Partition (TOPOGRAFIA-DISCHI.md, section 1).
#   It keeps the model, the bus, the size and the role. It has no used or free space and no
#   temperature: these values go out of date quickly.
# - No secrets in this file. The IP addresses are also in README.md.
@{
    SchemaVersion = 1
    Domain        = 'homelab.example'
    TailnetCidr   = '100.64.0.0/10'

    Hosts = @(
        @{
            Id = 'arcade'; Name = 'ARCADE'; Kind = 'server'; Os = 'Windows 11 Pro'
            Lan = '192.0.2.10'; Tailnet = '198.51.100.10'; Docker = $true; Ssh = @(); Uplink = 'switch'
            Icon = 'windows11'
            Role = 'Docker Desktop, GPU jobs (Tdarr, Immich ML), bare-metal Plex and *arr apps'
            Tagline = 'Media + GPU'
            Hardware = @{
                Cpu = 'AMD Ryzen 9 5900X'; Cores = '12C / 24T'; RamGb = 32; Gpu = 'NVIDIA RTX 3080 Ti, 12 GB'
                Disks = @(
                    @{ Label = 'NVMe';      Value = '2 x 1 TB (system, games)' }
                    @{ Label = 'Media HDD'; Value = '22 TB + 18 TB (Seagate Exos)' }
                    @{ Label = 'Media SSD'; Value = '4 TB + 1 TB (Samsung SATA)' }
                    @{ Label = 'USB';       Value = '2 x 4 TB HDD + 2 TB SSD' }
                )
                Volumes = @(
                    @{ Letter = 'A'; Model = 'ST22000NM000C-3WC103';    Bus = 'SATA'; SizeTb = 22; Role = 'Radarr root' }
                    @{ Letter = 'B'; Model = 'ST18000NM000J-2TV103';    Bus = 'SATA'; SizeTb = 18; Role = 'Sonarr root' }
                    @{ Letter = 'D'; Model = 'TOSHIBA EXTERNAL_USB';    Bus = 'USB';  SizeTb = 4;  Role = 'Radarr root, external disk' }
                    @{ Letter = 'F'; Model = 'Samsung SSD 870 QVO 4TB'; Bus = 'SATA'; SizeTb = 4;  Role = 'Sonarr root' }
                    @{ Letter = 'G'; Model = 'WD My Passport 25E2';     Bus = 'USB';  SizeTb = 4;  Role = 'Sonarr root, external disk' }
                    @{ Letter = 'H'; Model = 'Samsung SSD 860 EVO 1TB'; Bus = 'SATA'; SizeTb = 1;  Role = 'Radarr root' }
                    @{ Letter = 'I'; Model = 'Samsung PSSD T7';         Bus = 'USB';  SizeTb = 2;  Role = 'Sonarr root, external disk' }
                    @{ Letter = 'S'; Model = 'Sabrent Rocket 4.0 1TB';  Bus = 'NVMe'; SizeTb = 1;  Role = 'System, repo, Docker appdata, Tdarr staging' }
                )
            }
        }
        @{
            Id = 'the-grid'; Name = 'the-grid'; Kind = 'server'; Os = 'Debian 13'
            Lan = '192.0.2.20'; Tailnet = '198.51.100.20'; Docker = $true; Ssh = @('the-grid', 'the-grid-ts'); Uplink = 'switch'
            Icon = 'debian'
            Role = 'Public edge (Caddy + CrowdSec) and most services'
            Tagline = 'Edge + apps'
            Hardware = @{
                Cpu = 'AMD Ryzen Embedded R2514'; Cores = '4C / 8T'; RamGb = 12
                Disks = @(@{ Label = 'NVMe'; Value = '512 GB (GMKtec NucBox G11)' })
            }
        }
        @{
            Id = 'scope'; Name = 'scope'; Kind = 'server'; Os = 'Debian 13 (aarch64)'
            Lan = '192.0.2.30'; Tailnet = '198.51.100.30'; Docker = $true; Ssh = @('scope', 'scope-ts'); Uplink = 'switch'
            Icon = 'raspberrypi'
            Role = 'Beszel hub, Homepage, komodo-watchdog (experimental node)'
            Tagline = 'Monitoring'
            Hardware = @{
                Cpu = 'Raspberry Pi 4 Model B'; Cores = '4C Cortex-A72'; RamGb = 4
                Disks = @(@{ Label = 'SSD'; Value = '250 GB Crucial MX500 (USB)' })
            }
        }
        @{
            Id = 'router'; Name = 'Asus GT-AX6000'; Kind = 'network'; Os = 'Asuswrt-Merlin'
            Lan = '192.0.2.1'; Docker = $false
            Icon = 'asus-router'
            Role = 'Gateway, DNS (Diversion + NextDNS), port forward 80/443 to the-grid'
            Detail = 'Asuswrt-Merlin · gateway'
        }
        @{
            Id = 'ont'; Name = 'Nokia G-010G-T'; Kind = 'network'; Docker = $false
            Role = 'ONT of ISP (in the box of the ISP). The WAN port of the router connects to it. Data from Faginux, 2026-10-26.'
            Detail = 'ONT · fibre to Ethernet'
        }
        @{
            Id = 'switch'; Name = 'QNAP QSW-1105-5T'; Kind = 'network'; Docker = $false; Uplink = 'router'; UplinkLabel = '2.5G port'; Detail = 'Switch · 5 x 2.5 GbE'
            Icon = 'qnap'
            Role = 'Unmanaged switch, 5 ports 2.5GbE, on the 2.5G port of the router. Ports: ARCADE, the-grid, scope, Shield TV Pro, PlayStation 4 Pro.'
        }
        @{
            Id = 'shield-tv'; Name = 'NVIDIA Shield TV Pro'; Kind = 'client'; Docker = $false; Uplink = 'switch'
            Icon = 'nvidia'
            Role = 'TV player'
        }
        @{
            Id = 'ps4-pro'; Name = 'PlayStation 4 Pro'; Kind = 'client'; Docker = $false; Uplink = 'switch'
            Icon = 'playstation'
            Role = 'Game console'
        }
        @{
            Id = 'printer'; Name = 'Bambu Lab P2S + AMS 2 Pro'; Kind = 'device'; Docker = $false; Uplink = 'wifi'
            Icon = 'bambulab'
            Role = '3D printer'
        }
        @{
            Id = 'dryer'; Name = 'Sunlu S4 Dryer'; Kind = 'device'; Docker = $false; Uplink = 'wifi'
            Role = 'Filament dry box (a location in Spoolman)'
        }
        @{
            Id = 'oneplus-13'; Name = 'OnePlus 13'; Kind = 'client'; Tailnet = '198.51.100.40'; Docker = $false; Uplink = 'wifi'
            Icon = 'android'
            Role = 'Phone, tailnet client'
        }
        @{
            Id = 'tab-s5e'; Name = 'Galaxy Tab S5e'; Kind = 'client'; Docker = $false; Uplink = 'wifi'
            Icon = 'android'
            Role = 'Tablet. Not in the tailnet (tailscale status, 2026-10-20).'
        }
    )

    Nodes = @(
        @{ Id = 'internet';   Name = 'Internet';   Shape = 'cloud'; Role = 'Any client outside the home network' }
        @{ Id = 'isp';        Name = 'ISP'; Kind = 'provider'; Detail = 'Fibre FTTH · 2.5 Gbit/s'
           Role = 'Internet provider: fibre FTTH, 2.5 Gbit/s. Data from Faginux, 2026-10-26.' }
        @{ Id = 'cloudflare'; Name = 'Cloudflare'; Icon = 'cloudflare'; Role = 'DNS of homelab.example, proxy of the public names' }
        @{ Id = 'tailscale';  Name = 'Tailscale';  Icon = 'tailscale';  Role = 'Tailnet 100.64.0.0/10' }
        @{ Id = 'wifi';       Name = 'Wi-Fi';      Kind = 'wireless'; Uplink = 'router'; UplinkLabel = 'Wi-Fi'
           Role = 'The Wi-Fi of the router. The devices with Uplink = wifi use it.' }
        @{ Id = 'media-library'; Name = 'Media library'; Kind = 'storage'
           Role = 'The film and series folders of Radarr and Sonarr on ARCADE. Read TOPOGRAFIA-DISCHI.md.' }
    )

    Services = @(
        # --- the-grid ---
        @{ Id = 'caddy'; Name = 'Caddy'; Host = 'the-grid'; Kind = 'container'; Icon = 'caddy'
           Stack = 'nodes/the-grid/caddy'; Endpoint = '192.0.2.20:443'
           Containers = @(@{ Name = 'caddy'; State = 'running' }) }
        @{ Id = 'crowdsec'; Name = 'CrowdSec'; Host = 'the-grid'; Kind = 'container'; Icon = 'crowdsec'
           Stack = 'nodes/the-grid/caddy'
           Containers = @(@{ Name = 'crowdsec'; State = 'running' }) }
        @{ Id = 'paperless'; Name = 'Paperless-ngx'; Host = 'the-grid'; Kind = 'container'; Icon = 'paperless-ngx'
           Stack = 'nodes/the-grid/paperless'; Homepage = 'Paperless'
           Containers = @(
               @{ Name = 'paperless-ngx'; State = 'running' }
               @{ Name = 'paperless-db'; State = 'running' }
               @{ Name = 'paperless-redis'; State = 'running' }
               @{ Name = 'paperless-gotenberg'; State = 'running' }
               @{ Name = 'paperless-tika'; State = 'running' }
           ) }
        @{ Id = 'bitwarden'; Name = 'Bitwarden'; Host = 'the-grid'; Kind = 'container'; Icon = 'bitwarden'
           Stack = 'nodes/the-grid/bitwarden'; Homepage = 'Bitwarden'
           Containers = @(
               @{ Name = 'bitwarden'; State = 'running' }
               @{ Name = 'bitwarden-db'; State = 'running' }
           ) }
        @{ Id = 'tautulli'; Name = 'Tautulli'; Host = 'the-grid'; Kind = 'container'; Icon = 'tautulli'
           Stack = 'nodes/the-grid/tautulli'; Homepage = 'Tautulli'
           Containers = @(@{ Name = 'tautulli'; State = 'running' }) }
        @{ Id = 'yamtrack'; Name = 'Yamtrack'; Host = 'the-grid'; Kind = 'container'; Icon = 'yamtrack'
           Stack = 'nodes/the-grid/yamtrack'; Homepage = 'Yamtrack'
           Containers = @(
               @{ Name = 'yamtrack'; State = 'running' }
               @{ Name = 'yamtrack-redis'; State = 'running' }
           ) }
        @{ Id = 'spoolman'; Name = 'Spoolman'; Host = 'the-grid'; Kind = 'container'; Icon = 'spoolman'
           Stack = 'nodes/the-grid/spoolman'; Homepage = 'Spoolman'
           Containers = @(@{ Name = 'spoolman'; State = 'running' }) }
        @{ Id = 'seerr'; Name = 'Seerr'; Host = 'the-grid'; Kind = 'container'; Icon = 'seerr'
           Stack = 'nodes/the-grid/seerr'; Homepage = 'Seerr'
           Containers = @(@{ Name = 'seerr'; State = 'running' }) }
        @{ Id = 'komodo'; Name = 'Komodo Core'; Host = 'the-grid'; Kind = 'container'; Icon = 'komodo'
           Stack = 'nodes/the-grid/komodo'; Homepage = 'Komodo'
           Note = 'The Periphery of the-grid is a systemd service, not a container.'
           Containers = @(
               @{ Name = 'komodo-core'; State = 'running' }
               @{ Name = 'komodo-mongo'; State = 'running' }
           ) }
        @{ Id = 'flaresolverr'; Name = 'FlareSolverr'; Host = 'the-grid'; Kind = 'container'; Icon = 'flaresolverr'
           Stack = 'nodes/the-grid/flaresolverr'; Endpoint = '198.51.100.20:8191'
           Containers = @(@{ Name = 'flaresolverr'; State = 'running' }) }
        @{ Id = 'glances-the-grid'; Name = 'Glances (the-grid)'; Host = 'the-grid'; Kind = 'container'; Icon = 'glances'
           Stack = 'nodes/the-grid/glances'; Endpoint = '198.51.100.20:61208'
           Containers = @(@{ Name = 'glances'; State = 'running' }) }
        @{ Id = 'beszel-agent-the-grid'; Name = 'Beszel agent (the-grid)'; Host = 'the-grid'; Kind = 'container'; Icon = 'beszel'
           Stack = 'nodes/the-grid/beszel-agent'
           Containers = @(@{ Name = 'beszel-agent'; State = 'running' }) }
        @{ Id = 'backup-the-grid'; Name = 'Volume backup (the-grid)'; Host = 'the-grid'; Kind = 'container'; Icon = 'docker-volume-backup'
           Stack = 'nodes/the-grid/backup'
           Containers = @(@{ Name = 'dvb-local'; State = 'running' }) }

        # --- ARCADE: containers ---
        @{ Id = 'immich'; Name = 'Immich'; Host = 'arcade'; Kind = 'container'; Icon = 'immich'
           Stack = 'stacks/immich'; Homepage = 'Immich'
           Containers = @(
               @{ Name = 'immich-server'; State = 'running' }
               @{ Name = 'immich-machine-learning'; State = 'running' }
               @{ Name = 'immich-postgres'; State = 'running' }
               @{ Name = 'immich-redis'; State = 'running' }
           ) }
        @{ Id = 'tdarr'; Name = 'Tdarr'; Host = 'arcade'; Kind = 'container'; Icon = 'tdarr'
           Stack = 'stacks/tdarr'; Homepage = 'Tdarr'
           Note = 'Library Movies only (/media/movies). No TV library: decision of Faginux. Hourly scan for new files, folder watching off. Hold Files After Scanning: 30 minutes since 2026-10-20 (Faginux), so Tdarr works after TMM and the scan of Plex.'
           Containers = @(@{ Name = 'tdarr'; State = 'running' }) }
        @{ Id = 'tdarr-node'; Name = 'Tdarr Node'; Host = 'arcade'; Kind = 'container'; Icon = 'tdarr'
           Stack = 'stacks/tdarr'; Homepage = 'Tdarr Node'
           Containers = @(@{ Name = 'tdarr-node'; State = 'running' }) }
        @{ Id = 'cleanuparr'; Name = 'Cleanuparr'; Host = 'arcade'; Kind = 'container'; Icon = 'cleanuparr'
           Stack = 'stacks/cleanuparr'; Homepage = 'Cleanuparr'
           Containers = @(@{ Name = 'cleanuparr'; State = 'running' }) }
        @{ Id = 'qbit-manage'; Name = 'qbit_manage'; Host = 'arcade'; Kind = 'container'
           Stack = 'stacks/qbit_manage'
           Containers = @(@{ Name = 'qbit_manage'; State = 'running' }) }
        @{ Id = 'komodo-periphery-v4'; Name = 'Komodo Periphery (ARCADE)'; Host = 'arcade'; Kind = 'container'; Icon = 'komodo'
           Stack = 'stacks/komodo-periphery'
           Containers = @(@{ Name = 'komodo-periphery'; State = 'running' }) }
        @{ Id = 'backup-v4'; Name = 'Volume backup (ARCADE)'; Host = 'arcade'; Kind = 'container'; Icon = 'docker-volume-backup'
           Stack = 'stacks/volume-backup'
           Containers = @(
               @{ Name = 'dvb-local'; State = 'running' }
               @{ Name = 'dvb-remote-the-grid'; State = 'running' }
           ) }
        @{ Id = 'kometa'; Name = 'Kometa'; Host = 'arcade'; Kind = 'job'; Icon = 'kometa'
           Stack = 'stacks/kometa'
           Note = 'Started only by stacks/kometa/Invoke-KometaRun.ps1 (Scheduled Tasks Kometa-Nightly and Kometa-Quick).'
           Containers = @(@{ Pattern = '^kometa($|-kometa-run-)'; State = 'job' }) }
        @{ Id = 'umtk'; Name = 'UMTK (TSSK)'; Host = 'arcade'; Kind = 'job'
           Stack = 'stacks/umtk'
           Note = 'Started only by stacks/kometa/Invoke-KometaRun.ps1, before Kometa.'
           Containers = @(@{ Pattern = '^umtk($|-umtk-run-)'; State = 'job' }) }

        # --- ARCADE: bare metal (Windows apps and services) ---
        @{ Id = 'plex'; Name = 'Plex'; Host = 'arcade'; Kind = 'baremetal'; Icon = 'plex'
           Endpoint = '192.0.2.10:32400'; Homepage = 'Plex' }
        @{ Id = 'radarr'; Name = 'Radarr'; Host = 'arcade'; Kind = 'baremetal'; Icon = 'radarr'; Homepage = 'Radarr' }
        @{ Id = 'sonarr'; Name = 'Sonarr'; Host = 'arcade'; Kind = 'baremetal'; Icon = 'sonarr'; Homepage = 'Sonarr' }
        @{ Id = 'prowlarr'; Name = 'Prowlarr'; Host = 'arcade'; Kind = 'baremetal'; Icon = 'prowlarr'; Homepage = 'Prowlarr' }
        @{ Id = 'qbittorrent'; Name = 'qBittorrent'; Host = 'arcade'; Kind = 'baremetal'; Icon = 'qbittorrent'; Homepage = 'qBittorrent' }
        @{ Id = 'nomachine'; Name = 'NoMachine'; Host = 'arcade'; Kind = 'baremetal'
           Note = 'Remote desktop, NX protocol on TCP 4000. No Caddy route (PROBLEMI-E-SOLUZIONI.md 10.1).' }
        @{ Id = 'glances-v4'; Name = 'Glances (ARCADE)'; Host = 'arcade'; Kind = 'baremetal'; Icon = 'glances'
           Endpoint = '198.51.100.10:18208'
           Note = 'NSSM service, started through tools/glances-lhm.' }
        @{ Id = 'tmm'; Name = 'tinyMediaManager'; Host = 'arcade'; Kind = 'baremetal'
           Role = 'Metadata of films and series: NFO and artwork. Radarr and Sonarr start it through its HTTP API (tmm-trigger.ps1).'
           Note = 'Scripts in S:\Scripts\Tmm (not in the repo). Read KOMETA-CONFIG.md.' }

        # --- ARCADE: Scheduled Tasks of the media pipeline (page Media) ---
        @{ Id = 'task-tmm-watcher'; Name = 'TMM-Plex-Watcher'; Host = 'arcade'; Kind = 'task'; TaskName = 'TMM-Plex-Watcher'
           Role = 'Scheduled Task, every 2 minutes: tmm-plex-watcher.ps1. Waits for TMM, starts a partial scan of Plex, then starts Kometa-Quick.' }
        @{ Id = 'task-kometa-nightly'; Name = 'Kometa-Nightly'; Host = 'arcade'; Kind = 'task'; TaskName = 'Kometa-Nightly'
           Role = 'Scheduled Task, 00:30: Invoke-KometaRun.ps1 -Mode Full (UMTK, then Kometa with overlays and IMDb collections).' }
        @{ Id = 'task-kometa-quick'; Name = 'Kometa-Quick'; Host = 'arcade'; Kind = 'task'; TaskName = 'Kometa-Quick'
           Role = 'Scheduled Task with no time trigger: the watcher starts it 10 minutes after the last import. Invoke-KometaRun.ps1 -Mode Quick (overlays only).' }

        # --- scope ---
        @{ Id = 'beszel'; Name = 'Beszel hub'; Host = 'scope'; Kind = 'container'; Icon = 'beszel'
           Stack = 'nodes/scope/beszel'; Homepage = 'Beszel'
           Containers = @(
               @{ Name = 'beszel'; State = 'running' }
               @{ Name = 'beszel-agent'; State = 'running' }
           ) }
        @{ Id = 'homepage'; Name = 'Homepage'; Host = 'scope'; Kind = 'container'; Icon = 'homepage'
           Stack = 'nodes/scope/homepage'
           Containers = @(@{ Name = 'homepage'; State = 'running' }) }
        @{ Id = 'bitwarden-scope'; Name = 'Bitwarden (old, rollback)'; Host = 'scope'; Kind = 'container'; Icon = 'bitwarden'
           Stack = 'nodes/scope/bitwarden'
           Note = 'Stopped since 2026-10-04. Kept for the rollback until B.7 (not before 2026-11-03).'
           Containers = @(
               @{ Name = 'bitwarden'; State = 'stopped' }
               @{ Name = 'bitwarden-db'; State = 'stopped' }
           ) }
    )

    # Copy of the routes of nodes/the-grid/caddy/Caddyfile. The test compares them.
    Routes = @(
        # Public: Cloudflare proxy, CrowdSec in Caddy.
        @{ Hostname = 'paperless.homelab.example'; Service = 'paperless';   Via = 'caddy'; Backend = '198.51.100.20:8010'; Exposure = 'public-crowdsec' }
        @{ Hostname = 'vault.homelab.example';     Service = 'bitwarden';   Via = 'caddy'; Backend = '192.0.2.20:8080';  Exposure = 'public-crowdsec' }
        @{ Hostname = 'qbit.homelab.example';      Service = 'qbittorrent'; Via = 'caddy'; Backend = '192.0.2.10:8082';  Exposure = 'public-crowdsec' }
        @{ Hostname = 'tautulli.homelab.example';  Service = 'tautulli';    Via = 'caddy'; Backend = '198.51.100.20:8181'; Exposure = 'public-crowdsec' }
        @{ Hostname = 'cleanuparr.homelab.example'; Service = 'cleanuparr'; Via = 'caddy'; Backend = '192.0.2.10:11011'; Exposure = 'public-crowdsec' }
        @{ Hostname = 'yamtrack.homelab.example';  Service = 'yamtrack';    Via = 'caddy'; Backend = '198.51.100.20:8000'; Exposure = 'public-crowdsec' }
        @{ Hostname = 'spoolman.homelab.example';  Service = 'spoolman';    Via = 'caddy'; Backend = '198.51.100.20:7912'; Exposure = 'public-crowdsec'
           Note = 'Spoolman has no login. basic_auth in Caddy since 2026-10-27 (credentials outside the repo).' }
        @{ Hostname = 'seerr.homelab.example';     Service = 'seerr';       Via = 'caddy'; Backend = '198.51.100.20:5055'; Exposure = 'public-crowdsec'
           Note = 'Public since 2026-10-27 (Faginux). Before, tailnet only.' }
        # immich: public, but DNS only (the Cloudflare proxy limits a request body to 100 MB).
        @{ Hostname = 'immich.homelab.example';    Service = 'immich';      Via = 'caddy'; Backend = '192.0.2.10:2283';  Exposure = 'public-crowdsec'; Dns = 'public-ip'
           Note = 'Public since 2026-10-27 (Faginux), for the phone backup with no VPN. DNS only to the public IP, kept current by dynamic_dns in Caddy. Before (2026-10-20 to 2026-10-27): tailnet only.' }

        # Private, enforced by Caddy: remote_ip 100.64.0.0/10. The DNS record points
        # to the Tailscale IP of the-grid (Dns = 'tailnet', the test checks it).
        # radarr to beszel: remote_ip since 2026-10-20 (finding F1, commit ddad0b8).
        @{ Hostname = 'radarr.homelab.example';   Service = 'radarr';      Via = 'caddy'; Backend = '192.0.2.10:7878';  Exposure = 'tailnet-enforced'; Dns = 'tailnet' }
        @{ Hostname = 'sonarr.homelab.example';    Service = 'sonarr';      Via = 'caddy'; Backend = '192.0.2.10:8989';  Exposure = 'tailnet-enforced'; Dns = 'tailnet' }
        @{ Hostname = 'prowlarr.homelab.example';  Service = 'prowlarr';    Via = 'caddy'; Backend = '192.0.2.10:9696';  Exposure = 'tailnet-enforced'; Dns = 'tailnet' }
        @{ Hostname = 'tdarr.homelab.example';     Service = 'tdarr';       Via = 'caddy'; Backend = '192.0.2.10:8265';  Exposure = 'tailnet-enforced'; Dns = 'tailnet' }
        @{ Hostname = 'beszel.homelab.example';    Service = 'beszel';      Via = 'caddy'; Backend = '192.0.2.30:8090';  Exposure = 'tailnet-enforced'; Dns = 'tailnet' }
        @{ Hostname = 'komodo.homelab.example';    Service = 'komodo';      Via = 'caddy'; Backend = '198.51.100.20:9120'; Exposure = 'tailnet-enforced'; Dns = 'tailnet' }
        @{ Hostname = 'home.homelab.example';      Service = 'homepage';    Via = 'caddy'; Backend = '198.51.100.30:3000';   Exposure = 'tailnet-enforced'; Dns = 'tailnet' }

        # Direct DNS record to the Tailscale IP of the host, no Caddy.
        @{ Hostname = 'nomachine.homelab.example'; Service = 'nomachine';   Via = 'direct'; From = 'tailscale'; Backend = '198.51.100.10:4000'; Exposure = 'dns-only' }
    )

    # Edges of the map that are not routes.
    Links = @(
        @{ Id = 'internet-cloudflare'; View = 'Edge'; From = 'internet';   To = 'cloudflare'; Label = 'public names (proxied)' }
        @{ Id = 'cloudflare-router';   View = 'Edge'; From = 'cloudflare'; To = 'router';     Label = 'HTTPS to the public IP' }
        @{ Id = 'internet-router';     View = 'Edge'; From = 'internet';   To = 'router';     Label = 'direct to the public IP (443 open to all)' }
        @{ Id = 'router-caddy';        View = 'Edge'; From = 'router';     To = 'caddy';      Label = 'port forward 443' }
        @{ Id = 'oneplus-tailscale';   View = 'Edge'; From = 'oneplus-13'; To = 'tailscale';  Label = 'tailnet' }
        @{ Id = 'tailscale-caddy';     View = 'Edge'; From = 'tailscale';  To = 'caddy';      Label = 'private names to 198.51.100.20' }
        @{ Id = 'caddy-crowdsec';      View = 'Edge'; From = 'caddy';      To = 'crowdsec';   Label = 'bouncer' }
        @{ Id = 'internet-isp';        View = 'Hosts'; From = 'internet'; To = 'isp';        Label = 'fibre FTTH' }
        @{ Id = 'isp-ont';             View = 'Hosts'; From = 'isp';      To = 'ont';        Label = '2.5 Gbit/s' }
        @{ Id = 'ont-router';          View = 'Hosts'; From = 'ont';      To = 'router';     Label = 'WAN' }

        # Page Media: the media pipeline. Flow approved by Faginux on 2026-10-20 (read
        # KOMETA-CONFIG.md). Kind: data (files and requests), control (a script or a task
        # starts the target), read (the target reads the source).
        @{ Id = 'seerr-radarr';      View = 'Media'; Kind = 'data';    From = 'seerr';        To = 'radarr';        Label = 'request (films)' }
        @{ Id = 'seerr-sonarr';      View = 'Media'; Kind = 'data';    From = 'seerr';        To = 'sonarr';        Label = 'request (series)' }
        @{ Id = 'prowlarr-radarr';   View = 'Media'; Kind = 'data';    From = 'prowlarr';     To = 'radarr';        Label = 'indexers' }
        @{ Id = 'prowlarr-sonarr';   View = 'Media'; Kind = 'data';    From = 'prowlarr';     To = 'sonarr';        Label = 'indexers' }
        @{ Id = 'flaresolverr-prowlarr'; View = 'Media'; Kind = 'data'; From = 'flaresolverr'; To = 'prowlarr';     Label = 'Cloudflare challenge' }
        @{ Id = 'radarr-qbittorrent'; View = 'Media'; Kind = 'data';   From = 'radarr';       To = 'qbittorrent';   Label = 'download' }
        @{ Id = 'sonarr-qbittorrent'; View = 'Media'; Kind = 'data';   From = 'sonarr';       To = 'qbittorrent';   Label = 'download' }
        @{ Id = 'qbitmanage-qbittorrent'; View = 'Media'; Kind = 'control'; From = 'qbit-manage'; To = 'qbittorrent'; Label = 'tags, share limits' }
        @{ Id = 'cleanuparr-qbittorrent'; View = 'Media'; Kind = 'control'; From = 'cleanuparr'; To = 'qbittorrent'; Label = 'stalled downloads' }
        @{ Id = 'radarr-library';    View = 'Media'; Kind = 'data';    From = 'radarr';       To = 'media-library'; Label = 'import, rename' }
        @{ Id = 'sonarr-library';    View = 'Media'; Kind = 'data';    From = 'sonarr';       To = 'media-library'; Label = 'import, rename' }
        @{ Id = 'radarr-tmm';        View = 'Media'; Kind = 'control'; From = 'radarr';       To = 'tmm';           Label = 'tmm-trigger.ps1 (on import)' }
        @{ Id = 'sonarr-tmm';        View = 'Media'; Kind = 'control'; From = 'sonarr';       To = 'tmm';           Label = 'tmm-trigger.ps1 (on import)' }
        @{ Id = 'tmm-library';       View = 'Media'; Kind = 'data';    From = 'tmm';          To = 'media-library'; Label = 'NFO, artwork' }
        @{ Id = 'watcher-tmm';       View = 'Media'; Kind = 'read';    From = 'task-tmm-watcher'; To = 'tmm';       Label = 'reads tmm.log' }
        @{ Id = 'watcher-plex';      View = 'Media'; Kind = 'control'; From = 'task-tmm-watcher'; To = 'plex';      Label = 'partial scan' }
        @{ Id = 'watcher-quick';     View = 'Media'; Kind = 'control'; From = 'task-tmm-watcher'; To = 'task-kometa-quick'; Label = 'starts it (10 min after the last import)' }
        @{ Id = 'quick-kometa';      View = 'Media'; Kind = 'control'; From = 'task-kometa-quick'; To = 'kometa';   Label = 'Quick: overlays only' }
        @{ Id = 'nightly-umtk';      View = 'Media'; Kind = 'control'; From = 'task-kometa-nightly'; To = 'umtk';   Label = 'Full, 00:30: first' }
        @{ Id = 'nightly-kometa';    View = 'Media'; Kind = 'control'; From = 'task-kometa-nightly'; To = 'kometa'; Label = 'Full: overlays, IMDb collections' }
        @{ Id = 'sonarr-umtk';       View = 'Media'; Kind = 'read';    From = 'sonarr';       To = 'umtk';          Label = 'series status' }
        @{ Id = 'umtk-kometa';       View = 'Media'; Kind = 'data';    From = 'umtk';         To = 'kometa';        Label = 'badge YAML (tssk)' }
        @{ Id = 'kometa-plex';       View = 'Media'; Kind = 'data';    From = 'kometa';       To = 'plex';          Label = 'overlays, collections' }
        @{ Id = 'library-plex';      View = 'Media'; Kind = 'read';    From = 'media-library'; To = 'plex';         Label = 'library' }
        @{ Id = 'tdarr-library';     View = 'Media'; Kind = 'data';    From = 'tdarr';        To = 'media-library'; Label = 'Movies only: scheduled scan, HEVC, replaces the file' }
        @{ Id = 'plex-tautulli';     View = 'Media'; Kind = 'read';    From = 'plex';         To = 'tautulli';      Label = 'activity' }
        @{ Id = 'plex-yamtrack';     View = 'Media'; Kind = 'data';    From = 'plex';         To = 'yamtrack';      Label = 'webhook: watched' }
    )

    # The page Hosts has no Layout block: the script makes a tree from the Uplink keys.
    # Place of the items in each view. Columns go from left to right. At is the
    # vertical place (0 = top, 1 = bottom): the values keep the lines from going
    # through other nodes. The script puts the routed services of each lane host
    # in that lane.
    # Backups: the card "Backup" of the poster, from CALENDARIO-OPERAZIONI.md (2026-10-26).
    # From = the host of the data, To = the host that keeps the copy (Ids of Hosts).
    # CalendarKey = a text of the line in CALENDARIO-OPERAZIONI.md: the test looks for it,
    # so a job that leaves the calendar gives a warning. Change the two files together.
    # No paths here: the poster is public.
    Backups = @(
        @{ Id = 'immich-dump';     Name = 'Immich database dump'; Schedule = 'Daily 01:45';    From = 'arcade'; To = 'arcade'
           Detail = 'Immich, media disk';            Retention = '';        CalendarKey = 'dump DB Immich' }
        @{ Id = 'dvb-local-v4';    Name = 'Docker volumes';       Schedule = 'Mon, Thu 02:15'; From = 'arcade'; To = 'arcade'
           Detail = 'docker-volume-backup';          Retention = '29 days'; CalendarKey = 'dvb-local' }
        @{ Id = 'bitwarden-dump';  Name = 'Bitwarden dump';       Schedule = 'Sun 02:45';      From = 'the-grid';        To = 'the-grid'
           Detail = 'SQL dump, read only';           Retention = '4 dumps'; CalendarKey = 'backup-bitwarden.sh' }
        @{ Id = 'dvb-local-the-grid';   Name = 'Docker volumes';       Schedule = 'Tue, Fri 03:00'; From = 'the-grid';        To = 'the-grid'
           Detail = 'docker-volume-backup';          Retention = '29 days'; CalendarKey = 'dvb-local'; Encrypted = $true }
        @{ Id = 'sha256-manifest'; Name = 'SHA-256 manifest';     Schedule = 'Daily 03:40';    From = 'the-grid';        To = 'the-grid'
           Detail = 'a hash next to each new archive'; Retention = '';      CalendarKey = 'backup-sha256-manifest' }
        @{ Id = 'the-grid-pull';        Name = 'Pull of the-grid archives'; Schedule = 'Daily 05:40';    From = 'the-grid';        To = 'arcade'
           Detail = 'SFTP read only, SHA-256 check'; Retention = '36 days'; CalendarKey = 'the-grid-BackupPull' }
        @{ Id = 'dvb-remote-the-grid';  Name = 'Off-host copy';        Schedule = 'Sun 06:00';      From = 'arcade'; To = 'the-grid'
           Detail = 'docker-volume-backup over SSH'; Retention = '36 days'; CalendarKey = 'dvb-remote-the-grid'; Encrypted = $true }
    )

    Layout = @{
        Edge = @{
            # Commas between the columns: with no comma, PowerShell makes one flat list.
            Columns = @(
                @(@{ Id = 'internet'; At = 0.33 }, @{ Id = 'oneplus-13'; At = 0.72 }),
                @(@{ Id = 'cloudflare'; At = 0.18 }, @{ Id = 'tailscale'; At = 0.72 }),
                @(@{ Id = 'router'; At = 0.33 }),
                @(@{ Id = 'caddy'; At = 0.45 }, @{ Id = 'crowdsec'; At = 0.88 })
            )
            Lanes = @('the-grid', 'arcade', 'scope')
        }
        # The card "Media pipeline" of the poster: the steps from a request to the
        # film in Plex, in order. Items = Ids of Services. The full flow, with
        # each link, is the page Media of the drawing.
        Poster = @{
            # The card "Backup" goes under the card of this host.
            BackupUnder = 'the-grid'
            Pipeline = @(
                @{ Step = 'Request';  Items = @('seerr') }
                @{ Step = 'Search';   Items = @('prowlarr', 'flaresolverr') }
                @{ Step = 'Grab';     Items = @('radarr', 'sonarr') }
                @{ Step = 'Download'; Items = @('qbittorrent') }
                @{ Step = 'Organize'; Items = @('tmm') }
                @{ Step = 'Play';     Items = @('plex') }
                @{ Step = 'Polish';   Items = @('kometa', 'tdarr') }
                @{ Step = 'Track';    Items = @('tautulli', 'yamtrack') }
            )
        }
    }
}
