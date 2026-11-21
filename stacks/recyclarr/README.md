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
| `docker-compose.yml` | this folder | yes | Recyclarr 8.8.1 and Apprise API 2.1.0 |
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

On 2026-11-21: step R3 of the plan. The files exist. No container exists. Until step R8 creates
the containers, the drift check of ARCADE (21:10) shows the two services as
`SENZA CONTAINER`. This is the expected result. **Do not run the `docker compose up -d` of that
message before step R8.** The configs bind is live: a running container syncs the files at the
cron time, also before Faginux approves the preview (step R6).

Each `docker compose` command that starts or stops a container is a state transition. The
Regola numero uno (rule number one) of `CLAUDE.md` applies.
