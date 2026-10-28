# Icons of the homelab map. tools/homelab-map/Sync-HomelabMapIcon.ps1 downloads
# them from the pinned commits below into this directory. To add an icon, add a line
# and run the script. To update all the icons, change a commit and run the script.
#
# The icons are trademarks of their owners. The licence of each source is in its entry below.
# The public repo has a NOTICE file that lists the sources.
@{
    Sources = @{
        'homelab-svg-assets' = @{
            Repository = 'loganmarchione/homelab-svg-assets'
            Commit     = '73d44d7615cfca73ae909e8631235cdf18e8f043'
            # {0} = File, {1} = Format
            PathFormat = 'assets/{0}.{1}'
            License    = 'MIT for the code of the repository. Each icon belongs to its brand owner (DISCLAIMER.md).'
        }
        'dashboard-icons' = @{
            Repository = 'homarr-labs/dashboard-icons'
            Commit     = '320c819da84048d5a3066e2578bfa83be9019fdf'
            PathFormat = '{1}/{0}.{1}'
            License    = 'Apache-2.0 for the repository. Each icon belongs to its brand owner.'
        }
    }

    # Name   = the name in the inventory (Icon = '...') and the file name here.
    # File   = the file name in the source repository, with no extension.
    # Format = svg or png. Use png only when the source has no svg.
    # Tile   = 'light' for a dark icon: the map puts it on a light tile, because
    #          the background of the map is dark (2026-10-21). Optional.
    Icons = @(
        # Network and hosts
        @{ Name = 'cloudflare';   Source = 'homelab-svg-assets'; File = 'cloudflare';   Format = 'svg' }
        @{ Name = 'asus-router';  Source = 'homelab-svg-assets'; File = 'asus-router';  Format = 'svg' }
        @{ Name = 'tailscale';    Source = 'homelab-svg-assets'; File = 'tailscale';    Format = 'svg'; Tile = 'light' }
        @{ Name = 'qnap';         Source = 'homelab-svg-assets'; File = 'qnap';         Format = 'svg'; Tile = 'light' }
        @{ Name = 'windows11';    Source = 'homelab-svg-assets'; File = 'windows11';    Format = 'svg' }
        @{ Name = 'debian';       Source = 'homelab-svg-assets'; File = 'debian';       Format = 'svg'; Tile = 'light' }
        @{ Name = 'raspberrypi';  Source = 'homelab-svg-assets'; File = 'raspberrypi';  Format = 'svg' }
        @{ Name = 'android';      Source = 'homelab-svg-assets'; File = 'android';      Format = 'svg' }
        @{ Name = 'bambulab';     Source = 'homelab-svg-assets'; File = 'bambulab';     Format = 'svg' }
        @{ Name = 'docker';       Source = 'homelab-svg-assets'; File = 'docker';       Format = 'svg' }
        @{ Name = 'nvidia';       Source = 'homelab-svg-assets'; File = 'nvidia';       Format = 'svg' }
        @{ Name = 'playstation';  Source = 'dashboard-icons';    File = 'playstation';  Format = 'svg' }

        # Edge
        @{ Name = 'caddy';        Source = 'homelab-svg-assets'; File = 'caddy';        Format = 'svg'; Tile = 'light' }
        @{ Name = 'crowdsec';     Source = 'homelab-svg-assets'; File = 'crowdsec';     Format = 'svg' }

        # Services
        @{ Name = 'bitwarden';    Source = 'homelab-svg-assets'; File = 'bitwarden';    Format = 'svg' }
        @{ Name = 'tautulli';     Source = 'homelab-svg-assets'; File = 'tautulli';     Format = 'svg' }
        @{ Name = 'qbittorrent';  Source = 'homelab-svg-assets'; File = 'qbittorrent';  Format = 'svg' }
        @{ Name = 'immich';       Source = 'homelab-svg-assets'; File = 'immich';       Format = 'svg' }
        @{ Name = 'plex';         Source = 'dashboard-icons';    File = 'plex';         Format = 'svg' }
        @{ Name = 'radarr';       Source = 'dashboard-icons';    File = 'radarr';       Format = 'svg' }
        @{ Name = 'sonarr';       Source = 'dashboard-icons';    File = 'sonarr';       Format = 'svg' }
        @{ Name = 'prowlarr';     Source = 'dashboard-icons';    File = 'prowlarr';     Format = 'svg' }
        @{ Name = 'seerr';        Source = 'dashboard-icons';    File = 'seerr';        Format = 'svg' }
        @{ Name = 'tdarr';        Source = 'dashboard-icons';    File = 'tdarr';        Format = 'svg' }
        @{ Name = 'paperless-ngx'; Source = 'dashboard-icons';   File = 'paperless-ngx'; Format = 'svg'; Tile = 'light' }
        @{ Name = 'yamtrack';     Source = 'dashboard-icons';    File = 'yamtrack';     Format = 'svg' }
        @{ Name = 'spoolman';     Source = 'dashboard-icons';    File = 'spoolman';     Format = 'svg' }
        @{ Name = 'komodo';       Source = 'dashboard-icons';    File = 'komodo';       Format = 'svg'; Tile = 'light' }
        @{ Name = 'beszel';       Source = 'dashboard-icons';    File = 'beszel';       Format = 'svg' }
        @{ Name = 'glances';      Source = 'dashboard-icons';    File = 'glances';      Format = 'svg' }
        @{ Name = 'flaresolverr'; Source = 'dashboard-icons';    File = 'flaresolverr'; Format = 'svg' }
        @{ Name = 'cleanuparr';   Source = 'dashboard-icons';    File = 'cleanuparr';   Format = 'png'; Tile = 'light' }
        @{ Name = 'homepage';     Source = 'dashboard-icons';    File = 'homepage';     Format = 'png' }
        # Added on 2026-10-26 for the poster: the services with no icon before.
        @{ Name = 'docker-volume-backup'; Source = 'dashboard-icons'; File = 'docker-volume-backup'; Format = 'svg' }
        @{ Name = 'kometa';       Source = 'dashboard-icons';    File = 'kometa';       Format = 'png' }
    )
}
