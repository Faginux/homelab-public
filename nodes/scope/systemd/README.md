# systemd — scope

## komodo-watchdog

komodo-watchdog sends a Telegram alert (bot "Ops") when a Komodo Server or the API stops
responding. For what it does and why, read `tools/komodo-watchdog/README.md`. That file is not in
the sparse-checkout of the scope. Read it on ARCADE or on GitHub.

| File | What |
|---|---|
| `komodo-watchdog.service` | oneshot. It uses `DynamicUser`. systemd passes the secrets from `/etc/komodo-watchdog/` with `LoadCredential`. |
| `komodo-watchdog.timer` | It runs every 5 minutes, at the minutes :01, :06, …, :56. |

The state is in `/var/lib/private/komodo-watchdog/state.json`. Root can read this file, but
`ops` cannot.

### Installation

Prerequisites:

- The 4 secrets are in `/etc/komodo-watchdog/` (`root:root 0400`). For details, read the README of
  komodo-watchdog.
- The `linux/arm64` binary is compiled on ARCADE.

Copy the binary to `/tmp` on the scope with this command:

```powershell
scp $env:TEMP\komodo-watchdog scope:/tmp/komodo-watchdog
```

Then Faginux runs these commands on the scope. The commands need `sudo`:

```bash
cd ~/homelab-min/nodes/scope/systemd
sudo install -m 0755 -o root -g root /tmp/komodo-watchdog /usr/local/bin/komodo-watchdog
sudo install -m 0644 -o root -g root komodo-watchdog.service komodo-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start komodo-watchdog.service     # first run by hand: it never sends
                                                 # anything (threshold 2), it prints the states
journalctl -u komodo-watchdog -n 20 --no-pager   # the user is in the group adm: no sudo
sudo systemctl enable --now komodo-watchdog.timer
rm /tmp/komodo-watchdog
```

The journal of the first run must contain these lines:

- `the-grid: Ok`
- `arcade: Ok`
- `niente di nuovo: nessun messaggio`

The first two lines show the state as Komodo returns it.

### Verification

```bash
systemctl list-timers komodo-watchdog.timer --no-pager
journalctl -u komodo-watchdog --since "-1h" --no-pager
systemd-analyze security komodo-watchdog.service --no-pager | tail -1
```

### Uninstallation

```bash
sudo systemctl disable --now komodo-watchdog.timer
sudo rm /etc/systemd/system/komodo-watchdog.{service,timer} /usr/local/bin/komodo-watchdog
sudo systemctl daemon-reload
sudo rm -rf /var/lib/private/komodo-watchdog /etc/komodo-watchdog
```

Then revoke the key of the service user `komodo-watchdog` in Komodo.

## tailscale-wait-online

Added on 2026-10-14 for Homepage (`PIANO-HOMEPAGE.md`, P5). It is a copy of the the-grid fix
(`nodes/the-grid/systemd/`, `PROBLEMI-E-SOLUZIONI.md`, race at boot between `docker.service`
and `tailscaled.service`). A container that publishes a port on the Tailscale IP
(`198.51.100.30`) fails at boot with `cannot assign requested address` if Docker starts before
Tailscale has its IP.

| File | What |
|---|---|
| `tailscale-wait-online.sh` | It waits until `tailscale ip -4` gives an address. Timeout 60 s, then it exits with 0: Docker must start anyway. |
| `tailscale-wait-online.service` | oneshot, `After=tailscaled.service`. |
| `wait-tailscale.conf` | Drop-in for `docker.service`: `After=` and `Wants=` this unit. |

### Installation

Faginux runs these commands on the scope. The commands need `sudo`. They do not restart Docker:
the new order has an effect at the next boot.

```bash
cd ~/homelab-min/nodes/scope/systemd
sudo install -m 0755 -o root -g root tailscale-wait-online.sh /usr/local/bin/tailscale-wait-online.sh
sudo install -m 0644 -o root -g root tailscale-wait-online.service /etc/systemd/system/
sudo install -d -m 0755 /etc/systemd/system/docker.service.d
sudo install -m 0644 -o root -g root wait-tailscale.conf /etc/systemd/system/docker.service.d/
sudo systemctl daemon-reload
```

There is no `systemctl enable`: the unit has no `[Install]` section. The `Wants=` of the
drop-in starts it together with `docker.service`.

Before the copy, make sure that `/etc/systemd/system/docker.service.d/` has no other file with
the same name.

### Verification

```bash
systemctl show docker.service -p After -p Wants | tr ' ' '\n' | grep tailscale-wait-online
systemctl is-enabled tailscale-wait-online.service    # static (correct: no [Install] section)
```

The real test is a reboot of the scope (with the OK of Faginux): after the boot, `homepage` must be
`Up` and `journalctl -b -u tailscale-wait-online` must show no timeout.

### Uninstallation

```bash
sudo rm /etc/systemd/system/tailscale-wait-online.service /usr/local/bin/tailscale-wait-online.sh
sudo rm /etc/systemd/system/docker.service.d/wait-tailscale.conf
sudo systemctl daemon-reload
```
