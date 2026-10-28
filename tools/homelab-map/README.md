# homelab-map: scripts of the homelab map

These scripts make and check the homelab map in `docs/map`. The procedure to change the map is in
`docs/map/README.md`. The plan is `PIANO-MAPPA-HOMELAB.md`.

**All the scripts read only, except for the files of `docs/map`.** No script changes a host or a
container. Run them on ARCADE: the test needs the LAN, the tailnet and the SSH aliases `the-grid`
and `scope`.

## Scripts

| Script | What it does |
|---|---|
| `HomelabMap.psm1` | Shared functions: read the inventory, the Caddyfile, the Homepage cards and the drawing. Read the containers, the public DNS and the TCP ports. |
| `New-HomelabMap.ps1` | Makes the pages Edge, Hosts and Media of `docs/map/homelab-map.drawio` from the inventory. For the page Media it uses the layout `horizontalFlow` of draw.io Desktop (`-MediaLayout`, an empty value keeps a simple layout). A missing page gets a full layout. On a page that is there, it only adds the missing items. `-View` selects the pages. `-Force` makes the pages of `-View` again from zero, and their changes by hand are lost. `-Force` without `-View` stops with an error. `-Restyle` applies the theme (`$script:Theme` in `HomelabMap.psm1`) to the pages that are there. It changes the style and the label of each item, the title, the legend and the background. It does not move an item or change a bend point. `-WhatIf` writes nothing. |
| `Test-HomelabMap.ps1` | Compares the inventory with the real homelab and with the drawing. Read the next section. |
| `Export-HomelabMap.ps1` | Exports each page of the drawing to `docs/map/homelab-map-<page>.svg`, then runs `Export-HomelabPoster.ps1` (`-SkipPoster` skips it). Needs draw.io Desktop (`winget install --id JGraph.Draw --exact`). |
| `Export-HomelabPoster.ps1` | Makes `docs/map/homelab-poster.svg` from the inventory. The poster is one page: the network, the kinds of routes, a card for each server, the media pipeline and the devices. Writes the SHA-256 of the inventory into the SVG for the test. The poster is public: no IP address and no path. `-ShowAddress` adds the addresses for a private copy (do not commit it). Needs no draw.io and no network. |
| `Sync-HomelabMapIcon.ps1` | Downloads the icons of `docs/map/icons/icons.psd1` from their pinned commits. Rejects an SVG with active content. `-WhatIf` writes nothing. |

## Test-HomelabMap.ps1

The script writes one object for each finding: `Check`, `Severity`, `Item`, `Detail`.

| Check | Compares |
|---|---|
| CADDY | The routes of `nodes/the-grid/caddy/Caddyfile` with the routes of the inventory: name, backend and exposure. |
| EXPOSURE | Gives a warning for each Caddy route that is private by DNS only. A route with `AcceptedRisk` in the inventory gives INFO. |
| DNS | The public A records of each route, through DNS over HTTPS (Cloudflare). The router, Diversion and NextDNS do not change the answer. The output does not show the public IP of the home. |
| RUNTIME | `docker ps -a` on each host with `Docker = $true`. The format has the name and the state only. Also the Scheduled Tasks (`Kind = 'task'`) of the local host: they must exist and must not be disabled. |
| PORT | One TCP connection to each route backend and each `Endpoint`. The script sends no data. |
| HOMEPAGE | The cards of `nodes/scope/homepage/conf/services.yaml`: `siteMonitor` and `href`. |
| DRAWING | The items with `map_id` on each page (Edge, Hosts, Media): missing items, old items, duplicates and a missing page. Since v1.1 also the two ends of each line: a route, uplink or link must connect the items that the inventory gives. |
| POSTER | Since v1.2: `docs/map/homelab-poster.svg` exists and its SHA-256 of the inventory is the hash of the inventory now. A different hash means that the poster is older than the inventory. Each `CalendarKey` of `Backups` must be in `CALENDARIO-OPERAZIONI.md`. |

| Severity | Meaning |
|---|---|
| ERROR | The script could not read a source. |
| WARN | A difference, or a risk that nobody accepted. |
| INFO | A known item, for example an accepted risk. |

Exit code: `0` = no WARN and no ERROR. `1` = one or more WARN. `2` = one or more ERROR.

`-Skip Dns,Runtime,Port` skips the checks that use the network. The script does not run on a
schedule. Before you add a Scheduled Task, read `CALENDARIO-OPERAZIONI.md`.

Use `& ./tools/homelab-map/Test-HomelabMap.ps1` in a PowerShell session. With `pwsh -File`, the
`exit` at the end can stop the table before PowerShell shows it.

## Traps

- **PowerShell formatter hook.** A formatter hook of this machine applies the rule
  `PSUseSingularNouns`. On 2026-10-20 it changed `Resolve-HomelabPublicDns` to
  `Resolve-HomelabPublicDn` and the call failed. Give each function a noun that is singular for
  the rule (the function is now `Resolve-HomelabPublicName`).
- **`0xFFFFFFFF` in PowerShell** is the `Int32` value `-1`, not 4294967295. `Test-HomelabIpInCidr`
  uses the decimal value.
- **draw.io is a GUI program.** `&` does not wait for it, and `$LASTEXITCODE` stays empty.
  `Export-HomelabMap.ps1` uses `Start-Process -Wait`.
- **Hashtables and `Set-StrictMode`.** From version 2, a missing key of a hashtable stops the
  script. The inventory has optional keys, thus the module uses version 1.
- **A line can disconnect in draw.io.** On 2026-10-21 a change by hand of the page Edge released
  an end of the line `route:qbit.homelab.example` in an empty area. draw.io removed `source` and
  `target` and moved the line into the box of ARCADE. The line looked correct, and the test
  v1.0 did not find it, because the test looked only for the `map_id`. Test v1.1 compares the two
  ends of each line with `From` and `To` of `Get-HomelabViewItem`. The generator reads the same
  `From` and `To`.
- **draw.io Desktop writes a backup file** `.$homelab-map.drawio.bkp` next to the drawing when
  you save. `.gitignore` excludes it.
- **Dark icons on the dark theme.** Some icons are black or dark green (Tailscale, QNAP, Caddy,
  Komodo, Paperless-ngx, Cleanuparr, Debian). On a dark tile they are not visible. `Tile = 'light'`
  in `docs/map/icons/icons.psd1` gives them a light tile. Before you add an icon, look at it on
  the background `#0D2633`.
- **`-Restyle` replaces the style and the label.** A colour or a text that you change by hand in
  draw.io goes back to the theme at the next `-Restyle`. Change `$script:Theme` or the inventory
  instead. The places, the sizes and the bend points do not change.
- **Data URI of an image in SVG and in draw.io.** draw.io wants `data:image/png,<base64>` with no
  `;base64` (the `;` separates the style keys). An SVG `<image>` wants `data:image/png;base64,...`.
  `Get-HomelabIconDataUri` gives the draw.io form, and `Export-HomelabPoster.ps1` adds `;base64`.
- **Icon size limit.** `Sync-HomelabMapIcon.ps1` rejects a file larger than 200 KB. On 2026-10-26
  the script rejected the PNG of qbit_manage (323 KB), so qbit_manage shows two letters.
- **Text width in the poster.** An SVG has no font metrics. The script estimates the width of a
  text from the number of characters. A tile name that is too long gets a smaller font, then an
  ellipsis. Look at the export after a new service with a long name.
