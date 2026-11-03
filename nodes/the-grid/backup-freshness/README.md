# backup-freshness — the-grid

A daily check of the backup folders on the-grid. It sends a Telegram message when a backup
chain stops, also when the backup job itself sends nothing.

## Why

On 2026-11-01 the offsite copy of ARCADE (`dvb-remote-the-grid`) stopped after an update
(v2.50.0 wants the SSH host key of the-grid). The error came before the notifications of the tool,
so no message came. The only signal was a missing weekly ✅, and nobody saw it. Read
`stacks/volume-backup/README.md`, section *Host key of the-grid*.

## What it checks

| Check | Folder on the-grid | Files | Normal rhythm | Limit |
|---|---|---|---|---|
| `offsite-v4` | `/srv/backup/from-arcade` | `arcade-volumes-*.tar.gz.age` | Sunday 06:00 | 8 days |
| `volumes-the-grid` | `/srv/backup/docker-volumes` | `the-grid-volumes-*.tar.gz.age` | Tuesday and Friday 03:00 | 4 days |
| `bitwarden` | `/srv/backup/bitwarden-dumps` | `bitwarden_vault_*.sql.gz` | Sunday 02:45 | 8 days |

Each limit is one normal interval plus one day. For each folder the script finds these
problems:

- **stale**: the newest archive is older than the limit.
- **small**: the newest archive is less than half of the archive before it (truncated or empty).
- **missing**: the folder is not there, or it has no archive.

The script reads only the time and the size of the files. It reads no archive, it stops no
container, and it needs no `sudo`.

## Messages

Shared "Ops" bot, uniform format (`CENSIMENTO-BOT-TELEGRAM.md`), text in Italian:

- `🔴 🐧 the-grid · 💾 Freschezza backup` when a check goes from good to bad. The same message
  comes again each day while the problem stays (`📌 Promemoria`).
- `🔁 🐧 the-grid · 💾 Freschezza backup` when the check is good again.
- No message when all checks are good.

The script reads the token from `/srv/docker/_secrets/telegram/` and gives it to `curl` on
stdin (`--config -`), not in the arguments. The state is in
`~/.local/state/backup-freshness/`, one file for each check (`ok` or `bad`). The script writes
the state only after Telegram accepts the message, so a failed send comes again at the next run.

## Schedule

User crontab of `ops`, every day at 08:40. The line and the reasons for the time are in
`crontab.txt`. The script runs from the clone of the repo. Output goes to journald:

```bash
journalctl -t backup-freshness -n 20 --no-pager
```

## Manual run

Do these commands on the-grid, in any folder:

```bash
# 1. Show the result and the messages. No Telegram, no state change.
~/github/homelab/nodes/the-grid/backup-freshness/check-backup-freshness.sh --dry-run

# 2. Test of Telegram, with a separate state: a limit of 1 hour makes all checks stale.
~/github/homelab/nodes/the-grid/backup-freshness/check-backup-freshness.sh --test --state-dir /tmp/bf-test --max-age-hours 1
rm -rf /tmp/bf-test
```

Result of step 1: one line for each check (`ok`, `stale`, `small` or `missing`) and
`dry run: no state written`. The run takes less than 0.1 s (0.05 s on 2026-11-03).

## Add a folder

Add one line to `CHECKS` in the script: name, folder, file pattern, limit in hours, label
(Italian, for the message). Then do a dry run.

## Remove

Remove the line from the crontab of `ops` (`crontab -e`), then remove
`~/.local/state/backup-freshness/`.
