# Recyclarr (ARCADE)

Recyclarr keeps the custom format (CF) definitions of Radarr and Sonarr equal to the TRaSH
Guides. It manages only the CFs in `configs/*.yml`. It does not set a score: Faginux sets the scores
in the UI of the app (decision O16 of the plan). Recyclarr does not add a CF, does not delete a CF
and does not change the quality profiles. The plan and the decisions D1 to D13 are in `PLAN-RECYCLARR.md` at the root
of the repo.

Radarr and Sonarr are bare metal Windows services on this host. Recyclarr reaches them on the
LAN address of the host, because their Allowed Hosts list rejects `host.docker.internal`.

## Files

| File | Location | In git | Content |
|---|---|---|---|
| `docker-compose.yml` | this folder | yes | Recyclarr 8.8.1 and Apprise API 2.2.0 |
| `configs/radarr.yml`, `configs/sonarr.yml` | this folder, read-only on `/config/configs` | yes | The instances and the trash IDs of the managed CFs, with no score (step R5) |
| `Export-ArrCfState.ps1` | this folder | yes | Read-only export: CFs, quality profiles, score matrix |
| `New-RecyclarrSecretsFile.ps1` | this folder | yes | Writes `secrets.yml` and prints no value |
| `New-RecyclarrConfig.ps1` | this folder | yes | Writes the `custom_formats` block of `configs/*.yml` from the CF mapping and the baseline scores |
| `Compare-ArrCfState.ps1` | this folder | yes | Mode `Config`: the files against the baseline scores. Mode `State`: a new export against the baseline |
| CF mapping | `S:\docker-appdata\recyclarr\baseline\mapping_<date>` | no | The class and the decision for each CF (step R4) |
| `secrets.yml` | `S:\docker-appdata\recyclarr\config` | no | The URLs and the API keys of the two apps |
| `recyclarr.cfg` | `S:\docker-appdata\recyclarr\apprise` | no | The Discord URL for Apprise. Faginux writes it |
| Baseline exports | `S:\docker-appdata\recyclarr\baseline\<date>` | no | The output of `Export-ArrCfState.ps1` |

## Secrets

No secret is in git, in the compose file or in the environment. Thus `docker inspect` and the
deployed configuration of Komodo show no secret.

To write `secrets.yml` (PowerShell 7 or 5.1 on ARCADE):

```powershell
.\New-RecyclarrSecretsFile.ps1 -HostAddress <LAN IPv4 address of ARCADE>
```

The script tests each URL before it writes the file. It does not overwrite the file. After a key
rotation in Radarr or Sonarr, run it again with `-Force`.

## Baseline export

```powershell
.\Export-ArrCfState.ps1
```

The script only reads from the apps (GET). It writes into a new folder below
`S:\docker-appdata\recyclarr\baseline`. At the end it gives the number of files that contain an
API key. Expect 0.

## State

Since 2026-11-22 (step R8 of the plan): the two containers run, and the Stack `recyclarr` is in
Komodo. The built-in cron of the image starts `recyclarr sync` every day at 09:43
(`CRON_SCHEDULE`, `TZ=Europe/Rome`). The two syncs take about 18 s.

Each `docker compose` command that starts or stops a container is a state transition. The
Regola numero uno (rule number one) of `CLAUDE.md` applies. A Komodo Deploy is also a state
transition.

## Notifications

Recyclarr sends the result of each sync to the Apprise API of the stack
(`S:\docker-appdata\recyclarr\config\settings.yml`). Apprise sends it to Discord.

- `verbosity: normal` (D11): a message only when a sync changes something, or for a warning or an
  error. No message when nothing changes.
- `APPRISE_CONFIG_LOCK=yes`: the API cannot read the Discord URL. With the lock, Apprise API 2.x
  sends only to a specific tag. Thus `settings.yml` has `tags: recyclarr`, and the line of
  `recyclarr.cfg` has the same tag: `recyclarr=discord://<webhook_id>/<webhook_token>`. With no
  tag, Apprise gives HTTP 400 and Recyclarr writes `Failed to send notification` in its log.
- A fatal error sends no message. Test of 2026-11-23 (step R9.4): an instance that refuses the
  connection gives `Fatal error: Connection refused` and exit code 1, and no request reaches
  Apprise. Thus an outage of Radarr or Sonarr at the cron time shows in the files of
  `logs/cli/` (line `ERR Exiting due to fatal error`), not in Discord.
- Since 2026-11-23 the stack uses Apprise API 2.2.0. This version adds reminders (a scheduler
  process and the route `/reminder/<key>`). The stack does not use them, so the compose file sets
  `APPRISE_REMINDER_ENABLED=no`. With this variable, 2.2.0 gives the same answers as 2.1.0: HTTP
  200 with the tag `recyclarr`, 400 with no tag or with `all`, 424 for another tag, 403 on the read
  of the configuration. Do the same test again before the next Apprise bump: start a temporary
  container of the old and of the new version with the same lock, a test file `recyclarr.cfg`
  that points to a local sink, and compare the status codes.
- To change the Discord URL, Faginux writes the file again. Claude never reads it.
