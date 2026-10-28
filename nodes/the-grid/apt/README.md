# apt — the-grid

This directory has a versioned copy of apt configuration. The real configuration is **outside**
the repo, on the real host. Root owns it.

The convention is the same as for `../systemd/`. The files do not apply themselves. Reinstall by
hand from these files. Read them also to understand what changed and why.

The incident of 2026-09-19 caused this configuration. For the details, read
`PROBLEMI-E-SOLUZIONI.md` §2.11.

## The problem

At every upgrade, the `postinst` of `docker-ce` restarts `docker.service` **and**
`docker.socket`. The socket unit recreates `/run/docker.sock` with a new inode. With
`"live-restore": true`, the containers survive. But the containers that mount the socket with a
bind (`dvb-local`, `dvb-remote-scope`, `watchtower`, `beszel-agent`) stay attached to the old file.
This file is closed.

There is no error until the container tries to use the file. On 2026-09-19, `dvb-remote-scope`
noticed the problem five hours later and skipped the offsite copy.

## The files and where to install them

| File here | Real destination on the-grid | Permissions |
|---|---|---|
| `docker-socket-stale-check.sh` | `/usr/local/bin/docker-socket-stale-check.sh` | `755`, root |
| `99zz-docker-socket-stale-check` | `/etc/apt/apt.conf.d/99zz-docker-socket-stale-check` | `644`, root |

The script compares two times. The first time is the start of each container that mounts
`docker.sock`. The second time is the last activation of `docker.socket`
(`ActiveEnterTimestamp`). A container that started before the activation has the old socket. The
script compares times and not inodes, because `watchtower` and `beszel-agent` are `scratch`
images. These images have no `stat`.

The apt snippet runs the script after **every** time that apt runs dpkg: upgrade, install,
remove. This includes the runs from `unattended-upgrade`. If everything is correct, the script
prints nothing. If not, it prints the affected containers and the `docker restart` command to
run. **The script does not restart anything by itself.** Faginux decides when to restart the
containers (Regola numero uno, rule number one).

Non-obvious choices:

- **The script always exits 0, and the snippet adds `|| true`.** A `Post-Invoke` that fails makes
  the whole apt operation fail.
- **If `docker.service` is not active, the script does not call the CLI.** With socket
  activation, a simple `docker ps` restarts the daemon, and with it all the containers that have
  a restart policy. A daemon that someone stopped on purpose must stay stopped.
- **`DPkg::Post-Invoke` is a list.** The snippet comes after the snippet of `needrestart`. It
  does not replace that snippet. The rule "the last value wins" in `apt.conf.d`
  (`PROBLEMI-E-SOLUZIONI.md` §3) is true for single values. It is not true for lists.
- **The name starts with `99zz-`.** In lexical order, it comes after `99needrestart`. For this
  reason, the warning is the last text on the screen.

## Installation

Run these commands in the clone of the repo on the-grid:

```bash
cd ~/github/homelab/nodes/the-grid/apt
sudo install -m 755 -o root -g root docker-socket-stale-check.sh /usr/local/bin/
sudo install -m 644 -o root -g root 99zz-docker-socket-stale-check /etc/apt/apt.conf.d/
```

`install` copies the file and sets the owner and the permissions in one step. No reload is
necessary. Every time that apt runs, it reads `apt.conf.d` again.

## Verification

```bash
apt-config dump | grep -i post-invoke          # there must be TWO entries: needrestart and this one
docker-socket-stale-check.sh; echo "exit=$?"   # on a healthy system: no output, exit=0
```

You can test the positive case without breaking anything. Force the socket time to "now" in a
copy that you make on the fly:

```bash
sed 's/^socket_epoch=.*/socket_epoch=$(date +%s)/' /usr/local/bin/docker-socket-stale-check.sh | bash
```

The output must list all the containers that mount the socket. The test was done this way on
2026-09-19.
