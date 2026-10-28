# systemd — the-grid

This directory has a versioned copy of systemd configuration. The real configuration is **outside**
the repo, on the real host. Root owns it, and it is outside any bind mount. The system does not apply
these files automatically. Use them to regenerate the configuration by hand if someone reinstalls the
host. Use them also to understand what changed and why.

The incident of 2026-09-18 to 2026-09-19 caused this configuration. The incident was a power outage
with an unclean reboot, and then 5 containers were down at boot. For the full details, read
`PROBLEMI-E-SOLUZIONI.md` §2.10.

## The problem

`docker.service` starts before `tailscaled` finishes assigning the tailnet IP to the interface. Every
container that publishes a port on the static Tailscale IP of the node fails the bind at boot. The
port is on `198.51.100.20:PORTA`, not on `0.0.0.0`. The error is `cannot assign requested address`.

The container also has `RestartCount: 0`. The reason: the failure is in the *network setup* phase of
the restore. It is not a normal crash with automatic retry.

## The files and where to install them

| File here | Real destination on the-grid | Permissions |
|---|---|---|
| `tailscale-wait-online.sh` | `/usr/local/bin/tailscale-wait-online.sh` | `755`, root |
| `tailscale-wait-online.service` | `/etc/systemd/system/tailscale-wait-online.service` | `644`, root |
| `wait-tailscale.conf` | `/etc/systemd/system/docker.service.d/wait-tailscale.conf` | `644`, root |

Before Docker starts, the script polls `tailscale ip -4` (interval 2s, timeout 60s). When the timeout
ends, the script still exits with `exit 0`. If Tailscale never connects, Docker starts anyway. The
Tailscale-bound containers will fail as before, but the rest of the machine stays operational. The
script is not meant to block the boot indefinitely.

## Activation after a change

```bash
sudo systemctl daemon-reload
systemd-analyze verify docker.service   # checks the syntax, no service is touched
```

The fix applies by itself at the next restart of `docker.service`: a reboot, or an explicit
`systemctl restart docker`. **A `restart docker` to test the fix affects all the containers of the
host.** A first draft also gave this restart as the cause of the detachment of some containers from
the network. This statement was changed on 2026-09-19. Those containers were already without network since
their manual start after the failed boot. For the cause and the "SENZA RETE" check, read
`PROBLEMI-E-SOLUZIONI.md` §2.10.

**Do not confuse these two cases.** A `restart docker` alone leaves `/run/docker.sock` intact. An
`apt upgrade` of `docker-ce` also restarts `docker.socket`. With `live-restore`, the containers that
mount the socket (`dvb-local`, `dvb-remote-scope`, `watchtower`, `beszel-agent`) stay attached to the
old file. Restart these containers by hand after every upgrade. The "STALE" check is ready in
`PROBLEMI-E-SOLUZIONI.md` §2.11.

## Verification that it is active

```bash
systemctl show docker.service --property=After,Wants | tr ' ' '\n' | grep tailscale
systemctl status tailscale-wait-online.service
```

---

## Post-boot sanity check — `docker-boot-sanity-check.*`

This check is a second level of defense. It is independent of the fix above. A few minutes after
every boot, it checks the state of **all** the containers of the host, not only the containers that the
incident affected. It sends a Telegram notification **only if it finds a problem**. Silence means that
all is ok.

The check uses the same Telegram bot as watchtower: the variable `WATCHTOWER_NOTIFICATION_URL` in
`nodes/the-grid/watchtower/.env`, in the shoutrrr format `telegram://TOKEN@telegram?chats=CHAT_ID`.
You do not need to create or duplicate a secret. At runtime, the script does `source` of that file.
It never prints the file.

| File here | Real destination on the-grid | Permissions |
|---|---|---|
| `docker-boot-sanity-check.sh` | `/usr/local/bin/docker-boot-sanity-check.sh` | `755`, root |
| `docker-boot-sanity-check.service` | `/etc/systemd/system/docker-boot-sanity-check.service` | `644`, root |
| `docker-boot-sanity-check.timer` | `/etc/systemd/system/docker-boot-sanity-check.timer` | `644`, root |

What it reports:
- Stopped containers (`Exited`/`Restarting`) whose restart policy is **not** `no`. These are the
  containers that should have started again by themselves, and did not.
- `unhealthy` containers. Docker reports this state only **after** the retries that follow the
  `start_period` failed. Docker does not report it during a normal `health: starting`. For this
  reason, you do not need to fear false positives because of timing.

**The check does not cover** containers with the restart policy `no` that someone stopped on purpose.
The check ignores them, as expected. It also does not check if "the application service really
responds". It checks only the state that Docker itself reports.

### Activation (different from the fix above: here the `enable` of the timer is also needed)

```bash
sudo chmod +x /usr/local/bin/docker-boot-sanity-check.sh
sudo systemctl daemon-reload
sudo systemctl enable --now docker-boot-sanity-check.timer
```

`OnBootSec=5min` is relative to the current boot. If you enable the timer more than 5 minutes after
boot, `--now` makes the check run almost immediately, one time. This is useful as an immediate test.
It is not a bug.

### Verification

```bash
systemctl list-timers docker-boot-sanity-check.timer
sudo systemctl start docker-boot-sanity-check.service   # manual run, for a test
journalctl -u docker-boot-sanity-check.service --no-pager | tail -20
```

---

## Weekly Docker updates notification — `docker-updates-check.*`

Docker upgrades on the-grid stay **manual**, by choice. Each upgrade restarts `docker.socket`, and with
`live-restore` you must restart the containers that mount the socket by hand
(`PROBLEMI-E-SOLUZIONI.md` §2.11, apt hook in `../apt/`). The risk of the manual way is that you
forget to update the containers. This timer prevents this risk.

Every Saturday at 10:00, the timer checks if the Docker repo has new versions of the installed
packages (`docker-*`, `containerd.io`). It sends the result to Telegram. Silence means that there is
nothing to update. **The timer installs nothing.**

| File here | Real destination on the-grid | Permissions |
|---|---|---|
| `docker-updates-check.sh` | `/usr/local/bin/docker-updates-check.sh` | `755`, root |
| `docker-updates-check.service` | `/etc/systemd/system/docker-updates-check.service` | `644`, root |
| `docker-updates-check.timer` | `/etc/systemd/system/docker-updates-check.timer` | `644`, root |

Non-obvious choices:

- **The script reads only the apt cache. It does not start `apt update`.** `apt-daily.timer` already
  updates the lists (06:00 and 18:00, plus up to 12h random). The timer is active through
  `APT::Periodic::Update-Package-Lists "1"`. The lists include the Docker repo. The cache is at most
  about one day old. For this reason, the script needs neither root nor the apt lock.
- **The service runs as `User=ops`, not as root.** It reads the apt cache (readable by all) and
  the `.env` of watchtower (owned by the user).
- **The script uses the same Telegram bot as the sanity check.** It takes the variable
  `WATCHTOWER_NOTIFICATION_URL` from `../watchtower/.env`. Unlike the sanity check, the script reads
  the file with `grep`, **not with `source`**. The file is a data file. Bash interprets characters
  like `&` in the URL when it runs the file as a shell script.
- **`Persistent=true`:** If the-grid is off on Saturday at 10:00, the check starts at the first useful
  boot. The check does not skip the week.
- **The message repeats every week until you update.** This is intended. It works as a reminder.

### Activation

```bash
cd ~/github/homelab/nodes/the-grid/systemd
sudo install -m 755 -o root -g root docker-updates-check.sh /usr/local/bin/
sudo install -m 644 -o root -g root docker-updates-check.service docker-updates-check.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-updates-check.timer
```

Unlike `docker-boot-sanity-check.timer` (`OnBootSec`), `--now` does **not** make the check run
immediately here. The timer waits for the next Saturday at 10:00.

### Verification

```bash
systemctl list-timers docker-updates-check.timer        # next run: Saturday 10:00
sudo systemctl start docker-updates-check.service       # real run: silent if there are no updates
journalctl -u docker-updates-check.service --no-pager | tail -5
```

This is an end-to-end test with a **fake** update. It sends a real Telegram message, marked
`[TEST]`, with the version `99.0.0`. Run it as `ops`. The script reads the token from the `.env`:

```bash
sed -e "/^upgradable=/c\upgradable='docker-ce/trixie 5:99.0.0-1~test amd64 [upgradable from: 5:29.8.1-1~debian.13~trixie]'" \
    -e 's/^message="/message="[TEST] /' \
    /usr/local/bin/docker-updates-check.sh | bash
```

---

## Hourly check of containers without network — `docker-network-check.*`

The incident described in `PROBLEMI-E-SOLUZIONI.md` §2.10 caused this check. After the failed boot
of 2026-09-18, `tautulli`, `seerr` and `flaresolverr` stayed **about 15 hours** without network.
They were `Up`, and one was even `healthy`, but they were unreachable. The post-boot sanity check could
not see this problem. The sanity check runs only once, and it looks only at `Exited` and `unhealthy`
containers. The detachment happened later, at the manual start.

This check examines the active containers at :30 of every hour, and 10 minutes after every boot. It
reports these problems:

- **SENZA RETE**: the container has no network attached (`NetworkSettings.Networks` is empty).
- **PORTE NON PUBBLICATE**: the container has ports in `HostConfig.PortBindings`, but
  `docker port` is empty. This is the case of §7.5: the network is attached again while the container
  runs, and the ports are not published again.

Each line of the message already contains the fix command. The command has the name of the network
from `HostConfig.NetworkMode`. The check excludes the containers that use `host`, `none` or
`container:<id>`, because by construction these containers have no network of their own.

| File here | Real destination on the-grid | Permissions |
|---|---|---|
| `docker-network-check.sh` | `/usr/local/bin/docker-network-check.sh` | `755`, root |
| `docker-network-check.service` | `/etc/systemd/system/docker-network-check.service` | `644`, root |
| `docker-network-check.timer` | `/etc/systemd/system/docker-network-check.timer` | `644`, root |

Non-obvious choices:

- **The check warns only when the situation changes.** The last notified state is in
  `/var/lib/docker-network-check/last` (`StateDirectory=`, owned by `ops`). A failure produces
  one message at the start and one message at the recovery. It does not produce one message per hour
  for the whole night. The check updates the state only **after** a successful send. If Telegram
  fails, the check tries again the next hour.
- **The check runs at :30, not at :00.** At :00, it falls in the middle of other operations: the
  restart of `flaresolverr` (cron of 04:00), the `dvb` backups (03:00, 05:00) and watchtower (06:00).
  A container stopped at that moment is not a failure.
- **The unit has `After=docker.service` without `Requires=`.** The script exits immediately if the
  daemon is not active. A read-only check must not start again a Docker that someone stopped on
  purpose. This is true for a direct start and for a start through socket activation.
- **The check fixes nothing by itself.** The fix commands are in the message. Faginux decides when to
  start them (Regola numero uno, rule number one).

### Activation

```bash
cd ~/github/homelab/nodes/the-grid/systemd
sudo install -m 755 -o root -g root docker-network-check.sh /usr/local/bin/
sudo install -m 644 -o root -g root docker-network-check.service docker-network-check.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-network-check.timer
sudo systemctl start docker-network-check.service   # real run now: silent if all is correct
```

Unlike the timer of the updates, `--now` here makes a first check run **immediately**.
`OnBootSec=10min` is already over, and an expired monotonic timer starts as soon as someone activates
it. On 2026-09-19, the check ran twice, 5 seconds apart: once from the timer and once by hand.

### Verification

```bash
systemctl list-timers docker-network-check.timer
systemctl show docker-network-check.service -p Result,ExecMainStatus   # success / 0
ls -la /var/lib/docker-network-check/                                   # folder of the user ops
```

The `last` file in the directory **appears only after the first warning**. While all is well, the
file does not exist. An absent file means "no problem". It is not an installation error.

This is an end-to-end test with a **fake** failure. It sends a real Telegram message. It uses a
temporary state directory, so it does not touch the state directory of the service. Run it as
`ops`:

```bash
sed 's|^current=$(find_problems)$|current="SENZA RETE: [TEST] container finto, ignora"|' \
    /usr/local/bin/docker-network-check.sh | STATE_DIRECTORY=$(mktemp -d) bash
```

---

## Evening check of compose ↔ container drift — `docker-compose-drift-check.*`

`PROBLEMI-E-SOLUZIONI.md` §2.12 describes the incident that caused this check. The pins and labels of
commit `000a359` (2026-09-14) stayed **only in the repo** for 8 days, because no container was
recreated. On 2026-10-01, Watchtower was scheduled to update the edge and paperless by itself. A
commit on `image:`, `labels:`, `environment:`, `ports:` or `volumes:` has no effect until someone
recreates the container. Nothing signaled this.

Every evening at 21:00, the check compares every stack of `nodes/the-grid/` with what is running.
It reports these cases:

- **DRIFT**: the `config-hash` of the compose (`docker compose config --hash`) is different from the
  label `com.docker.compose.config-hash` of the container. The compose changed, and the container was
  not recreated.
- **IMMAGINE NON APPLICATA**: the config matches, but the local image of the configured tag is not the
  image in use. This is the case of a `pull` without `up`. The `config-hash` does not see this case.
- **RICREEREBBE** (since 2026-09-24): the config and the image match, but
  `docker compose --dry-run up -d` says `Recreate`. Compose also recreates a container when the label
  `com.docker.compose.image` does not match the expected digest, or when networks and volumes are
  different. The typical case is a container that **Watchtower** recreated. Watchtower clones the
  labels of the old container, and this label too (`PROBLEMI-E-SOLUZIONI.md` §2.13).
- **SENZA CONTAINER**: the service is in the repo, but its container was never created.
- **ERRORE**: `docker compose config` or the dry-run fails for that stack (a broken compose or a
  missing `.env`). A check that fails silently is useless.

Each line already contains the command to realign the container. Run the command **after** you check
what it changes (§2.12: commit after creation, digests).

| File here | Real destination on the-grid | Permissions |
|---|---|---|
| `docker-compose-drift-check.sh` | `/usr/local/bin/docker-compose-drift-check.sh` | `755`, root |
| `docker-compose-drift-check.service` | `/etc/systemd/system/docker-compose-drift-check.service` | `644`, root |
| `docker-compose-drift-check.timer` | `/etc/systemd/system/docker-compose-drift-check.timer` | `644`, root |

Non-obvious choices:

- **No secret passes through the check.** `docker compose config --hash "*"` prints only
  `servizio hash`. It never prints the values of the config. For this reason, the check does not use
  the complete `docker compose config`, and it does not use `--format json`.
- **The check compares with the working tree of the-grid**, that is with what an `up -d` uses. It does not
  compare with GitHub. A `git pull` that brings a change to a compose produces a warning the same
  evening. This is the case that we want to catch.
- **The check warns only when the situation changes**, like the network check. The state is in
  `/var/lib/docker-compose-drift-check/last`. The check updates it only after a successful send.
- **The check runs at 21:00**, with `Persistent=true`. In the evening, you can intervene. 21:00 is also
  well ahead of the Watchtower round (06:00 on the first day of the month). If the-grid is off, the check starts at the first
  useful boot.
- **The errors of `docker inspect` do not truncate the list.** A container that vanished in the middle
  of a round must not make the list look empty. An empty list can look like a "recovery".
- **`DRY_RUN=1`** prints the message instead of sending it. It **does not read the token**. It is for
  tests.
- **The check uses the dry-run of compose, not a copy of the logic of compose.** A first attempt
  computed the expected digest by hand (manifest `linux/amd64`). This gave a false positive on
  paperless-gotenberg, which stays `Running` at the real `up`. `docker compose --dry-run up -d` runs
  the true reconciliation without write calls. It prints only `Container <name> <action>`, and no
  config.
- **The check runs the dry-run only if the hash and the image are fine.** For this reason, every line
  has a single cause. A whole round takes about 6 s.
- **The check does not cover** the tags that the maintainer republishes with a different image (Caddy,
  §2.12). Only a query of the registry shows this case. For Caddy, the pin by digest solves it at the
  root.

### Activation

```bash
cd ~/github/homelab/nodes/the-grid/systemd
sudo install -m 755 -o root -g root docker-compose-drift-check.sh /usr/local/bin/
sudo install -m 644 -o root -g root docker-compose-drift-check.service docker-compose-drift-check.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-compose-drift-check.timer
sudo systemctl start docker-compose-drift-check.service   # real run now: silent if all is aligned
```

### Verification

```bash
systemctl list-timers docker-compose-drift-check.timer                     # next run: 21:00
systemctl show docker-compose-drift-check.service -p Result,ExecMainStatus  # success / 0
ls -la /var/lib/docker-compose-drift-check/                                # folder of the user ops
```

As for the network check, the `last` file appears only after the first warning.

This test needs no installation and no Telegram. Run it from the repo on ARCADE. It is a real
round in `DRY_RUN`, and the expected result is silence:

```bash
ssh the-grid 'D=$(mktemp -d); DRY_RUN=1 STATE_DIRECTORY=$D bash -s; rm -rf "$D"' \
    < nodes/the-grid/systemd/docker-compose-drift-check.sh
```

This is an end-to-end test with a **fake** drift. It sends a real Telegram message. Run it as
`ops` after the installation:

```bash
sed 's|^current=$(find_drift)$|current="DRIFT: [TEST] drift finto, ignora"|' \
    /usr/local/bin/docker-compose-drift-check.sh | STATE_DIRECTORY=$(mktemp -d) bash
```

## SHA-256 manifest of the backups — `backup-sha256-manifest.*`

This timer exists since 2026-10-02 (`PIANO-DECLASSAMENTO-scope.md`, A.2). ARCADE downloads the
backups of the-grid with the user `v4pull`. This user has only read-only SFTP, and it cannot run
`sha256sum` on the-grid (`tools/the-grid-backup-pull/README.md`). the-grid prepares the hash for ARCADE.

Every day at 03:40, the timer writes `<archivio>.sha256` next to every complete archive that does not
have one. This applies to `/srv/backup/docker-volumes` (`*.tar.gz.age`) and to
`/srv/backup/bitwarden-dumps` (`*.sql.gz`). The timer skips the second directory until it exists.

| File here | Real destination on the-grid | Permissions |
|---|---|---|
| `backup-sha256-manifest.sh` | `/usr/local/bin/backup-sha256-manifest.sh` | `755`, root |
| `backup-sha256-manifest.service` | `/etc/systemd/system/backup-sha256-manifest.service` | `644`, root |
| `backup-sha256-manifest.timer` | `/etc/systemd/system/backup-sha256-manifest.timer` | `644`, root |

Non-obvious choices:

- **The format is the Linux format `<hash>  <nome>`** (two spaces). You can also check the file with
  `sha256sum -c` from the directory.
- **The timer processes only files that are unchanged for 10 minutes.** An archive that dvb is still
  writing (for example a dvb that someone started by hand) gives a hash that never matches.
- **The timer writes a `.tmp` file first, and then runs `mv`.** In this way, ARCADE never reads a
  manifest that is half written.
- **The timer deletes the orphans.** The timer deletes the `.sha256` of an archive that the retention
  of dvb pruned, at the next round.
- **The service uses these settings.** `User=ops`: this user owns the directories. The archives
  are `root 644`, so this user can read them. The service also uses `Nice=10` and
  `IOSchedulingClass=idle`, and `ProtectSystem=strict` with `ReadWritePaths=/srv/backup`.
- **The timer runs at 03:40, every day.** This is 40 minutes after `dvb-local` (Tuesday and Friday at
  03:00). It is far from `cron.hourly` (:17), from the network check (:30) and from `flaresolverr`
  (04:00). Without new archives, the timer exits immediately. The pull of ARCADE runs at 05:40.
- **The timer sends no Telegram message.** If the manifest is missing, the pull of ARCADE notices
  this and warns by itself. The pull sees an archive that still has no `.sha256` after more than 3
  hours. There is a single alarm point.

### Activation

```bash
cd ~/github/homelab/nodes/the-grid/systemd
sudo install -m 755 -o root -g root backup-sha256-manifest.sh /usr/local/bin/
sudo install -m 644 -o root -g root backup-sha256-manifest.service backup-sha256-manifest.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backup-sha256-manifest.timer
sudo systemctl start backup-sha256-manifest.service   # first run, now
```

### Verification

```bash
systemctl list-timers backup-sha256-manifest.timer          # next run: 03:40
journalctl -u backup-sha256-manifest -n 5 --no-pager        # "manifest: N creati, ..."
```

To test without writing anything, run
`ssh the-grid 'DRY_RUN=1 bash -s' < nodes/the-grid/systemd/backup-sha256-manifest.sh` from the repo
on ARCADE. On 2026-10-02, the test processed 4 archives (about 1.8 GB) in 2 s. The first real
round took 1 s. The hashes were identical to the hashes of the dry-run.

## CVE gate on Komodo updates — `komodo-gate.*`

The code, the choices and the tests are in `tools/komodo-gate/README.md`
(`PIANO-KOMODO-SECRETS-GATE.md`, Phase 3). This section has only the installation.

The timer runs every morning at **07:45**. This is 45 minutes after the Procedure
"Poll updates (mai deploy)" of Komodo (07:00). For every service with an update, Trivy scans the
current image and the candidate image. The result is **PASSA** if the candidate has no more
vulnerabilities.

The timer sends a Telegram message only when something changes. **It never deploys.** It is the only
timer here that starts containers: the temporary containers of Trivy (`docker run --rm`), and only if
there is something to scan.

| File | Real destination on the-grid | Permissions |
|---|---|---|
| binary `komodo-gate`. Build it on ARCADE (read the README of the tool). | `/usr/local/bin/komodo-gate` | `755`, root |
| `komodo-gate.service` | `/etc/systemd/system/komodo-gate.service` | `644`, root |
| `komodo-gate.timer` | `/etc/systemd/system/komodo-gate.timer` | `644`, root |

Faginux wrote the secrets. The permissions are `0400` and the owner is `ops`. The secrets are in
`/srv/docker/_secrets/komodo-gate/` (`api_key`, `api_secret`) and in `/srv/docker/_secrets/telegram/`
(`bot_token`, `chat_id`). **The token comes from these files, not from the `.env` of Watchtower**, as
in the scripts above. The scripts above must also use these files before Faginux decommissions
Watchtower (Phase 4 of the plan).

### Activation

First copy the binary to `/tmp/komodo-gate` with `scp` (read the README of the tool). Then run:

```bash
sudo install -m 755 -o root -g root /tmp/komodo-gate /usr/local/bin/komodo-gate && rm /tmp/komodo-gate
cd ~/github/homelab/nodes/the-grid/systemd
sudo install -m 644 -o root -g root komodo-gate.service komodo-gate.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now komodo-gate.timer
sudo systemctl start komodo-gate.service   # real run now: first message with the open updates
```

### Verification

```bash
systemctl list-timers komodo-gate.timer                     # next run: 07:45
systemctl show komodo-gate.service -p Result,ExecMainStatus  # success / 0
journalctl -u komodo-gate -n 30 --no-pager                   # un esito per servizio
ls -la /var/lib/komodo-gate/                                 # state.json di ops
```
