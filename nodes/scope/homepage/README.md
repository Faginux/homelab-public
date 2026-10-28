# Homepage — scope

Homepage (`gethomepage/homepage`, GPL-3.0) is the start page of the homelab. It shows a link to
each service, a status dot for each service and the Komodo summary.

Homepage is **not** a monitor. It does not keep history and it does not send alerts. Beszel,
`komodo-watchdog` and the "Ops" bot do that work.

- URL: `https://home.homelab.example` (tailnet only)
- Container: `homepage`, port `198.51.100.30:3000`
- Deployment steps and status: `PIANO-HOMEPAGE.md`

## Why these decisions

| Decision | Reason |
|---|---|
| Homepage, not Homarr, Dashy or Glance | The config is YAML in git. Secrets come from `.env` with `{{HOMEPAGE_VAR_*}}`. There is no state to back up. Homarr keeps its config in a database. |
| scope, not the-grid | The scope is the "testing-monitoring" node (`PIANO-DECLASSAMENTO-scope.md`). If you move the stack to the-grid, change only the IP in the Caddyfile and in `ports`. |
| Port on the Tailscale IP only | Homepage has **no authentication**. The upstream docs say that a public deployment must have a reverse proxy or a VPN that does the authentication. |
| Caddy route with `remote_ip 100.64.0.0/10` | It is the only access control. The `*.homelab.example` wildcard goes to Cloudflare, so a private DNS record alone is not sufficient. This is the same schema as `komodo` and `dockhand`. |
| `tailscale-wait-online` on the scope | Without it, Docker can start before Tailscale has its IP, and the port bind fails at boot. This is the same fix as on the-grid (`nodes/scope/systemd/README.md`). |
| No Docker socket | Komodo gives the container state through its API. A socket in a container with a web UI is root on the host. |
| Config read-only from the repo clone | A change is a commit, a push and a `git pull` on the scope. Homepage reads the files again when the page loads, so a restart is not necessary. Tested on 14/10/2026 (P8): the new icons and the new `custom.css` showed without a restart of the container. |
| Directory `conf/`, not `config/` | `.gitignore` ignores `nodes/*/*/config/`. A `config/` directory would not go into git, and git would show no error. |
| All 9 config files are in `conf/` | Homepage copies a default file when a file is missing. In a read-only directory the copy fails and the container stops (`checkAndCopyConfig`, `process.exit(1)`). |
| `LOG_TARGETS=stdout` | Without it, Homepage writes `logs/homepage.log` into the config directory. Read the logs with `docker logs homepage`. |
| `mem_limit: 384m` | This protects the Beszel hub on a node with about 4 GB of RAM. The value is an estimate. Measure the real use (`PIANO-HOMEPAGE.md`, P9). |
| Image `v2.5.0` | It is the release of the source code that was read to write this config (10/10/2026). The digest is added before the first start (P3). |

## Widgets

### Phase 1 (this stack)

| Service | Widget | Credentials |
|---|---|---|
| Komodo | `komodo`, `showSummary: true` (servers, stacks, containers) | API key **read-only**. The widget sends `POST <url>/read` with the headers `X-API-Key` and `X-API-Secret`. |
| Seerr | `seerr` (requests: pending, approved, completed). On since E1 (14/10/2026) | API key of Seerr, with **admin rights** (there is no read-only key). The widget sends `GET <url>/api/v1/request/count` with the header `X-API-Key`. |
| Tdarr | `tdarr` (queue, processed, errors, space saved). On since L5 (14/10/2026) | Tdarr API key (`HOMEPAGE_VAR_TDARR_KEY`). Tdarr has `auth=true`, so the widget needs a key. The key has **full rights**: there is no read-only key. Make a new key only for Homepage in *Tools > API Keys*, so you can revoke it alone. The widget sends `POST <url>/api/v2/cruddb` with the header `x-api-key` and reads counters only. The key crosses the home LAN in plain HTTP (scope to ARCADE), because Tdarr listens on `192.0.2.10` only. Caddy uses the same path for the Tdarr web page. To close this gap, add the Tailscale IP of ARCADE to the `ports` of the Tdarr stack, then use that IP in `conf/services.yaml`. |
| Beszel | **Off.** Link and status dot only | See below |
| All the other services | Link and status dot (`siteMonitor`) | None |

**The Beszel widget is off, on purpose.** Faginux decided on 14/10/2026 not to turn it on. The widget
signs in on the PocketBase collection `_superusers` (`authv2`). The version 1 endpoint
(`admins/auth-with-password`) does not exist on hub 0.18.7, so only a superuser works. A superuser
can change all the data of the hub, and there is no read-only mode. The password would stay in a
container without authentication. The status dot (`siteMonitor`) already shows if the hub answers.
The commented `widget:` block in `conf/services.yaml` stays as a note. The facts are in
`PIANO-HOMEPAGE.md`, section *E5 dropped*.

### Host metrics (Glances)

The top panel shows three blocks of numbers, one for each host. The `resources` widget can only
read the host where Homepage runs, so the other two hosts use the `glances` widget.

| Host | Source | Notes |
|---|---|---|
| scope | `resources` widget | CPU, RAM, disk `/`, temperature, uptime. |
| the-grid | Container `glances` (`nodes/the-grid/glances/`), `198.51.100.20:61208` | Image `nicolargo/glances:4.5.8-full` pinned by digest. The port is open on the Tailscale IP only. No Docker socket, no `pid: host`. `mem_limit: 192m`. The disk is `/etc/hosts`: inside the container `/` is not a mount point, and Docker mounts that file from the root disk. The CPU sensor is `Tctl`. |
| ARCADE | Windows service `Glances` (NSSM, Glances 4.2.1), `198.51.100.10:18208` | The service existed before Homepage. Since 14/10/2026 it listens on the Tailscale IP only (before, on `0.0.0.0` with no password). Since 17/10/2026 the port is 18208, not 61208. After a boot, Windows reserved 61195 to 61294. Glances could not bind, and the block showed an API error (see `tools/glances-lhm/README.md`, *Problems*). Set the parameters with `tools/glances-lhm/Set-GlancesLauncher.ps1`. Glances has no CPU temperature on Windows, so the service starts through `tools/glances-lhm` (a launcher that reads `Tctl` from LibreHardwareMonitor, from `C:\Program Files\GlancesLhm`). The disk is `C:\`. The first answer after a pause can take 3 to 7 seconds, and the block shows "Attendere prego" until it comes. |

The Glances web page of each host has no password. Because of this, both ports must stay on the
Tailscale IP. The Glances blocks have no link in the page (`pointer-events: none` in `custom.css`).

### Not done on purpose

Faginux decided not to add the widgets of Radarr, Sonarr and Paperless (14/10/2026). Each one uses
the only API key of the service, and that key has **full rights** (for example, it can delete
movies in Radarr). The decision is in `PIANO-HOMEPAGE.md`, section *Evaluation of the widgets*.

The card *Tdarr Node* has no widget. The state of the node is only in `/api/v2/get-nodes`, and that
answer holds the API key of the node (`config.apiKey`). The widget `customapi` sends the whole
answer to the browser. Every viewer of the page could then read the key in the network tab.

## The look

The look is "dark glass". It has three parts:

| File | What it does |
|---|---|
| `conf/settings.yaml` | Dark theme, `headerStyle: boxed`, equal height of the cards, no version text, and the order and the columns of the groups. Monitoring has 6 columns and Media has 4. |
| `conf/widgets.yaml` | The top panel: a Google search bar, and the resources of the scope, the-grid and ARCADE (CPU, RAM, disk, temperature, uptime). It also has the date and the weather (Open-Meteo). |
| `conf/custom.css` | The photo background. A gradient shows if the photo is missing. The "liquid glass" cards: blur, saturation, a bright edge and a fine grain. The titles of the groups. The layout of the top panel. The search bar has no logo of Google, and its text is in the center. The date and the weather are one bubble at the top right. The cards Tdarr and Tdarr Node have half of the width each. |
| `images/background.jpg` | The background photo: 3200 px wide, JPEG, 484 KB. Docker mounts the folder read-only on `/app/public/images`. A new or changed image needs a restart of the container, because Next.js reads the folder once, at the start. Do not mount the whole `/app/public`. |

The transparency of all the glass bubbles has one setting: `--glass` at the top of `custom.css`.
`1` is the first look (14/10/2026), and `0.8` is 20% more transparent. A lower number gives less
contrast for the text on the photo.

The weather uses the coordinates in `conf/widgets.yaml`, rounded to 2 decimals (about 1 km) on
purpose. The scope sends them to `api.open-meteo.com`, and the weather does not need the exact
position of the house.

Do not use `cardBlur` or `background` in `settings.yaml`: `custom.css` does the same work, and the
two would fight each other. The CSS uses the class names and the ids of Homepage v2.5.0. After an
update of the image, look at the page on a desktop and on a phone, because a new version can rename
them. The icons are SVG files from the dashboard-icons collection. Use a `-light` variant for an
icon that is dark, because it is not readable on the dark background.

The photo is a wallpaper that Faginux chose (the original file is `bonsai-rock-milky-5120x3413-21130.jpg`,
5120 x 3413, 8.2 MB). The file in `images/` is a smaller copy for the web. The repository is private.
Check the licence of the photo before you make the repository public.

Homepage has no settings menu: the configuration is in the YAML files. The only control in the footer
is the refresh icon at the bottom right. The theme and color switchers exist, but they are hidden
because `settings.yaml` fixes the theme and the color.

The `resources` widget shows the numbers of the scope, not of the container. The API of the widget
gives a total RAM of 3.98 GB, the same as `free` on the scope (checked on 14/10/2026). The upstream
docs say the opposite.

## The status dots

`siteMonitor` makes the Homepage server send a `HEAD` request (and a `GET` if `HEAD` fails) to
the backend address. Each address in `conf/services.yaml` is the address that Caddy uses (read
from the Caddyfile on 14/10/2026). It is not the public URL: from the scope, a public URL goes
through Cloudflare. If a backend changes IP or port, change the Caddyfile **and** this file.

The icon names (`komodo.png`, `beszel.png`, …) come from the dashboard-icons collection. They
were not checked one by one. A wrong name shows an empty icon and causes no other problem.

## Operations

All the commands that change the state of a container need the OK of Faginux (rule number one).

```bash
# On the scope. Validate the config. The output is the exit code only.
cd ~/homelab-min/nodes/scope/homepage && docker compose config --quiet; echo $?

# Logs (LOG_TARGETS=stdout)
docker logs --tail 50 homepage

# Change of conf/*.yaml: commit and push from ARCADE, then on the scope:
cd ~/homelab-min && git fetch origin && git merge --ff-only origin/main
```

Update of the image: change the tag and the digest in `docker-compose.yml`, then `pull` and
`up -d` with the OK of Faginux. The scope has no Watchtower.
