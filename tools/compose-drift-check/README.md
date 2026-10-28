# compose-drift-check: drift check for the stacks of ARCADE

`Invoke-ComposeDriftCheck.ps1` compares the containers of ARCADE with the compose files in
`stacks/`. It sends a Telegram message when the list of differences changes. It is the V4 copy of
`nodes/the-grid/systemd/docker-compose-drift-check.sh` (the-grid). It uses the same rules and the
same lines in the message.

**The script reads only.** It never recreates a container. It runs `docker compose config` only
with `--hash`, which prints "service hash" and no value.

## Why

A commit that changes image, labels, environment, ports or volumes does not apply until
someone recreates the container (`PROBLEMI-E-SOLUZIONI.md` §2.12). Since 2026-10-14, Komodo deploys all
the stacks of V4 that are in scope from the repo. Thus the repo and the containers must agree.
This closes item 2b.3 D of `PIANO-KOMODO-SECRETS-GATE.md`.

## What it reports

| Line | Meaning |
|---|---|
| `ERRORE` | `docker compose config` or the dry-run fails for that stack. |
| `SENZA CONTAINER` | A service of the compose has no container. |
| `DRIFT` | The config-hash of the container is not the hash of the compose, and the dry-run recreates it. |
| `IMMAGINE NON APPLICATA` | The local image of the tag is not the image that the container uses (pull done, `up` not done). |
| `RICREEREBBE` | Hash and image are equal, but `up -d` recreates the container (stale image label, networks or volumes, `PROBLEMI-E-SOLUZIONI.md` §2.13). |

The script skips `kometa` and `umtk`. They are `docker compose run --rm` jobs, so they have no
container between two runs.

## A difference from the the-grid script

A different config-hash counts as `DRIFT` only if the dry-run also recreates the container. With
`network_mode: service:X`, `docker compose config --hash` hashes the static config. But `up`
saves the hash after it resolves the network to `container:<id>`. The hashes then differ, while
compose says `Running` (`tdarr-node`, 2026-10-14). No stack on the-grid uses `network_mode: service:`,
so the the-grid script does not need this change today.

## Schedule and files

| What | Where |
|---|---|
| Scheduled Task | `Compose-Drift-Check`, every day at **21:10**, user `ARCADE\arcade`, Limited, `StartWhenAvailable`, limit 5 min |
| Launcher | `Invoke-ComposeDriftCheck.vbs` (`wscript.exe`, no console window, it returns the exit code of pwsh) |
| State | `S:\docker-appdata\compose-drift-check\last.txt` (the last list that the script sent) |
| Run log | `S:\docker-appdata\compose-drift-check\drift-check.ndjson` (one line for each run) |
| Telegram | `S:\Scripts\Tmm\telegram.config.psd1`, the shared "Ops" bot. The script reads it only to send. |

The the-grid check runs at 21:00. A run takes about 6 s (measured on 2026-10-14, 7 stacks). If Docker
Desktop does not run, the script stops with no message. The watchdog on the scope already reports
V4 down.

In `New-ScheduledTaskPrincipal`, write the full user name `ARCADE\arcade`. The bare name
is also the name of the computer, and the registration fails with "Parametro non corretto".

## Tests

```powershell
.\Invoke-ComposeDriftCheck.ps1 -NoSend                     # print the message, no Telegram, state unchanged
.\Invoke-ComposeDriftCheck.ps1 -NoSend -StacksDir <copy>   # check a copy of a stack folder
.\Invoke-ComposeDriftCheck.ps1 -Force                      # send even if the list did not change
```

Results on 2026-10-14:

- A real run found `RICREEREBBE` for `watchtower` only. Watchtower of V4 updates itself and keeps
  the old image label.
- A copy of `cleanuparr` with one more label gave `DRIFT`.
- A start of the Scheduled Task sent the message (exit 0). The run after it was `unchanged`.
