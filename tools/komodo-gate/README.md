# komodo-gate — the CVE "gate" for Komodo updates

komodo-gate replaces the CVE part of DockHand (`PIANO-KOMODO-SECRETS-GATE.md`, Phase 3). The
Komodo poll marks the services that have a newer image. For each of these services, the gate scans
**the running image and the candidate image** with Trivy. It applies the rule **"More than
current"**. It writes to Telegram when something changes.

**The gate never deploys.** Faginux presses Deploy in Komodo, after `docker compose --dry-run up -d`
(`PROBLEMI-E-SOLUZIONI.md` §2.13).

## One round

1. The gate calls `ListStacks`. It selects the services with `update_available`. The Procedure
   "Poll updates (mai deploy)" writes this flag at 07:00.
2. For each service, the gate reads two digests. The candidate digest is in
   `info.latest_services[].image_digest` in the response of `GetStack`. The running digest is in
   `image_digests` in the response of `ListStackServices`.
3. If there is at least one image to scan, the gate updates the Trivy DBs **once**. Then it runs
   all the scans with `--skip-db-update`. The gate compares the current image and the candidate on
   the same DB.
4. The result is **PASSA** if the candidate has a total of vulnerabilities ≤ the current image.
   Otherwise the result is **BLOCCA**. The message shows the total and the serious
   (CRITICAL+HIGH) counts, current -> candidate, and the CRITICAL/HIGH CVEs that are **only** in
   the candidate (maximum 5 ids).
5. The gate writes to Telegram **only when something changes**: a new candidate, a different
   outcome, or an error that appears or recovers. It saves the state only after a successful send.

The message has these outcomes:

| Line | What it means | What to do |
|---|---|---|
| `✅ stack/servizio` (verdict PASSA) | The candidate does not get worse. | Deploy in Komodo when you want, after the dry-run. |
| `⛔ stack/servizio` (verdict BLOCCA) | The candidate has more vulnerabilities. | Wait for a new candidate. Or read the new CVEs and decide by hand. |
| `❌ stack/servizio` (verdict ERRORE) | The scan or the read failed (registry, Trivy, missing digest). | Read the detail. This is **not** a green light. |
| `ERRORE gate (API Komodo / DB di Trivy)` | The whole round did not start. | Run `journalctl -u komodo-gate`. |
| `Rientrato: stack/servizio` | There are no more updates for that service. | Usually this means: the Deploy is done. |

## Non-obvious choices

- **The gate has only Read on Komodo.** The service user `komodo-gate` has the Read permission on
  all the Stacks, and no permission on Logs, Inspect or Terminal. With Read, `GetStack` also returns
  the resolved config of the compose. The structs in `komodo.go` decode **only** the fields that the
  gate uses. The gate discards the rest. The rest never appears in logs, state or messages
  (`TestFullRun` checks this).
- **Trivy runs without the Docker socket.** The gate runs `docker run --rm` with `aquasec/trivy`
  (tag and digest) and `--image-src remote`. Trivy scans the running image from the registry too, by
  digest. The gate does not pull images into the image store of Docker. The cache (DB and layer
  analysis) is in the volume `komodo-gate-trivy-cache`. This volume belongs to the gate.
- **Regola numero uno (rule number one):** the gate starts **temporary** Trivy containers without
  asking. It does not touch any existing container. Faginux approved this with the plan (2026-09-25).
- **If there is no update, Trivy does not start.**
- **An unrecognized operating system gives ERRORE, not PASSA.** If Trivy does not recognize the
  operating system of an image, it does not scan the packages of the image. It reports 0 and gives no
  error. If the current image has an operating system and the candidate does not, the counts are not
  comparable.
- **The gate compares images with only a binary normally.** Images with only the binary
  (beszel-agent) have no operating system on either side. A change of operating system (for example
  `alpine 3.23.5 -> alpine 3.23.6`) goes into the detail.
- **The Telegram token does not appear in the journal.** The token is in the URL of the request. The
  network errors of Go print the URL. `notify.go` keeps only the cause (`TestTelegramErrorHidesToken`).
- **The counts are the counts of Trivy.** There is one entry per package. The same CVE on two
  packages counts twice. This is the same for the current image and the candidate, so the comparison
  holds.
- Komodo does **not** check images that are pinned by digest. For these images, the gate sees
  nothing.

## Apply a PASSA (recipe of 2026-09-25)

The gate says only that the candidate does not get worse. The Deploy stays manual. Deploy one
service at a time, with these steps. The example is `yamtrack-redis`, a stack in
`nodes/the-grid/yamtrack`:

1. **Pull only the service to update, from the CLI on the-grid:** `docker compose pull yamtrack-redis`.
2. **Make sure that the downloaded digest is the digest of the gate.** Compare the output of
   `docker image inspect redis:8-alpine --format '{{.Id}}'` with `candidate` in
   `/var/lib/komodo-gate/state.json`. If the tag was republished after the last round, the two
   values do not match. Then you are about to apply an image that the gate did **not scan**. Wait for
   the round of the next day, or run `sudo systemctl start komodo-gate.service`.
3. **Run a dry-run:** `docker compose --dry-run up -d`. The output must show `Recreate` **only** for
   that service.
4. **Does the service have state or data?** If it is a database, do these actions:
   - Make a backup right before the Deploy. For Postgres, use `pg_dump -Fc` in a directory under
     `/srv/docker`.
   - Check the version jump. For a tag like `postgres:16`, compare the digest with the `16.x` tags
     on Docker Hub. The result shows if the new image has the same version, a minor version or a
     major version.
5. **Deploy in Komodo** with the **Deploy** button. With Pre Pull off, Komodo uses the image that you
   just downloaded. Do **not** use Pull. The Pull of Komodo downloads *all* the services of the
   stack. Then the Deploy recreates all of them.
6. **Check the result:**
   - Record the Docker events live. They must show that only that service was recreated.
   - The `.Image` of the container must be equal to the digest of the gate.
   - The dry-run must show `Running` for all the services.
   - Read the logs. The clients of a redis reconnect by themselves in about 2 s.
   - Faginux checks the UI.

At the gate round of the next day, the message `Rientrato: stack/servizio` arrives. It shows
that Komodo sees the updated service.

### The same recipe from the CLI: `apply-passa.sh`

`apply-passa.sh` (2026-10-13) does steps 1-3 and 6 of the recipe for one stack on the-grid. It stops
before any change if a check fails:

- The gate verdict is not PASSA.
- The pulled image is not the digest that the gate scanned.
- A database service has no `--db-dump-done` flag.
- The dry-run recreates a container that you did not request.

The script recreates containers. Faginux runs it, because rule number one applies:

```bash
ssh the-grid 'bash -s' -- --check-only paperless broker db < tools/komodo-gate/apply-passa.sh
ssh the-grid 'bash -s' -- --db-dump-done paperless broker db < tools/komodo-gate/apply-passa.sh
```

Step 4 (the database dump) stays manual. The CLI does not write an Update in Komodo. The poll of
the next morning shows the new state.

## Secrets

The gate reads the secrets from files. It never reads them from environment variables. It never
prints them.

| File | Content |
|---|---|
| `/srv/docker/_secrets/komodo-gate/api_key` | API key of the service user |
| `/srv/docker/_secrets/komodo-gate/api_secret` | Secret of the same key |
| `/srv/docker/_secrets/telegram/bot_token` | Token of the bot. It is the same as the token of Watchtower. |
| `/srv/docker/_secrets/telegram/chat_id` | Destination chat |

The permissions are `0400`. The owner is `ops`. The files have no trailing newline. Faginux wrote
the files.

## Development and build (on ARCADE)

The gate uses Go 1.27 (`winget install GoLang.Go`) and only the standard library.

```powershell
cd S:\github\homelab\tools\komodo-gate
gofmt -l . ; go vet ./... ; go test ./...
$env:GOOS='linux'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'
go build -trimpath -ldflags '-s -w' -o $env:TEMP\komodo-gate .
Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED
```

The tests use a fake Komodo HTTP server and a fake Trivy. The tests cover these cases:

- pass
- block
- scanner in error
- unreachable registry
- Komodo down and recovery
- failed Telegram send
- no update

## Test on the-grid without Telegram and without installing

```powershell
scp $env:TEMP\komodo-gate the-grid:/tmp/komodo-gate
ssh the-grid 'D=$(mktemp -d); /tmp/komodo-gate -dry-run -state "$D/state.json"; rm -rf "$D" /tmp/komodo-gate'
```

`-dry-run` (or `DRY_RUN=1`) prints the message instead of sending it. It does not read the Telegram
files. It still reads the Komodo API. If there are updates, it really starts Trivy.

## Installation and verification

The units are in `nodes/the-grid/systemd/`: `komodo-gate.service` and `komodo-gate.timer`. The
timer runs every day at 07:45. For the instructions, read the README in that directory.

## Maintenance

- **Update Trivy.** Set the new version in `defaultTrivyImage` (`main.go`). Change the tag **and**
  the digest.
- **The cache is about 3 GB** after the first round (2026-09-25: vulnerability DB, Java DB and layer
  analysis). It grows with the layer analyses. To delete the analyses, run
  `docker run --rm -v komodo-gate-trivy-cache:/root/.cache/trivy <immagine trivy> clean --scan-cache`.
- **License:** The license is not chosen yet. The plan requires a free license and no code from
  DockHand.
