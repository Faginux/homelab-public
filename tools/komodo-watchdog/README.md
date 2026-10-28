# komodo-watchdog — Telegram alert if a Komodo Server stops responding

This tool closes the gap described in `PROBLEMI-E-SOLUZIONI.md` §13.1. On 2026-09-24, Docker
Desktop on ARCADE was off for 17 hours, and nothing sent a warning.

Beszel does not notice this. On ARCADE, Beszel is a Windows service and it keeps running.
Periphery notices. It is a container, and when Docker Desktop stops, the Server `arcade`
becomes `NotOk` in Komodo. For the plan, read `PIANO-KOMODO-SECRETS-GATE.md`, Phase 2b.

The tool runs on the **scope** to watch the-grid and ARCADE from outside. A tool on the-grid stops
together with Komodo.

## One round (every 5 minutes)

1. The tool sends `POST https://komodo.homelab.example/read` with `ListServers`. The response has the
   name and the `info.state` of each Server (`Ok` / `NotOk` / `Disabled`), and `info.err` for the
   cause. The Periphery of ARCADE uses the same route (`wss://komodo.homelab.example`).
2. The tool sends an alert when a Server is not `Ok` (and not `Disabled`) in **2 checks in a
   row**. An unknown state value counts as a failure. A false alarm is better than silence if the
   API changes.
3. A failure also happens when an expected Server (`-expect the-grid,arcade`) does not appear in
   the list. A removed permission or a renamed Server must not look like "all fine".
4. The tool gives the same treatment to an API that does not respond (the-grid, Core or Caddy is down).
   The API is a target of its own. In the meantime, the state of the Servers stays as before. The
   tool does not reset it.
5. The tool sends a Telegram message **only when something changes**. It saves the state only after
   a successful send.

The "Ops" bot uses a uniform format (`CENSIMENTO-BOT-TELEGRAM.md`). The message has a header,
`<stato> 🍓 scope · 🐕 Komodo watchdog`, and then one line for each changed target. The state in the
header is the state of the most serious line: 🔴 if there is a failure, otherwise 🔁, otherwise ℹ️.

```
🔴 🍓 scope · 🐕 Komodo watchdog

🔴 Server arcade NON risponde: primo controllo fallito alle 14:46, 2 di fila
   stato NotOk: <causa riportata da Komodo>
```

| Line | What it means |
|---|---|
| `🔴 Server arcade NON risponde: primo controllo fallito alle 14:02, 2 di fila` + cause | Periphery is disconnected. On ARCADE, the usual reason is that Docker Desktop is down. |
| `🔴 API di Komodo NON risponde` + error | The scope cannot reach Komodo. The problem is in one of these: the-grid, Core or Caddy. |
| `🔁 ... di nuovo OK alle 14:19 (... giù per ~17 min)` | The target is OK again. The duration is the time from the first failed check to the first OK. The precision is ±5 min. |
| `ℹ️ Server ... non più controllato` | The Server was in alert. The Server is now disabled or removed in Komodo. |

The tool sends no message when a failure recovers within one check (for example, when the Docker
Desktop backend restarts in 2-3 s).

**The tool exits 0 even when the API is down.** The API is the thing that the tool watches. A down
API is not a failure of the tool. The tool exits 1 only if it cannot work (secrets, state,
Telegram send). In this case, `systemctl --failed` shows the tool.

**Known limit:** when the scope stops, nobody receives a warning. The Beszel hub has the same limit.

## Non-obvious choices

- **The tool uses the service user `komodo-watchdog`. This user has only Read on the Servers.** It
  has no permission on the Stacks. The responses never contain the resolved config of the
  composes. The key is separate from the key of the gate. You can revoke it on its own.
- **The tool decodes only the fields that it uses** (`komodo.go`). `ListServers` also returns the
  public IP, the addresses and the keys of the Peripheries. These fields never appear in logs,
  state or messages (`TestUnusedFieldsNeverLeak`).
- **`DynamicUser` and `LoadCredential`** (unit in `nodes/scope/systemd/`). On the scope, `ops` is
  in the `docker` group. In practice, this group is the same as root. The watchdog runs with a
  disposable user without access to Docker. The secrets are root files. systemd passes them only
  to the watchdog.
- **The Telegram token does not appear in the journal.** `notify.go` is copied from the gate
  (`TestTelegramErrorHidesToken`). The code is copied and not shared. The gate stays intact.

## Secrets

These files are in `/etc/komodo-watchdog/`. The owner is `root:root`. The permissions are `0400`.
Faginux wrote the files.

| File | Content |
|---|---|
| `komodo_api_key`, `komodo_api_secret` | API key of the service user `komodo-watchdog` |
| `telegram_bot_token`, `telegram_chat_id` | The "Ops" bot. It is the same bot as the bot of Watchtower, Kometa and the gate. The values were copied from the-grid and never appeared on the screen. |

## Development and build (on ARCADE)

The tool uses Go 1.27 and only the standard library.

```powershell
cd S:\github\homelab\tools\komodo-watchdog
gofmt -l . ; go vet ./... ; go test ./...
$env:GOOS='linux'; $env:GOARCH='arm64'; $env:CGO_ENABLED='0'
go build -trimpath -ldflags '-s -w' -o $env:TEMP\komodo-watchdog .
Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED
```

The tests use a fake Komodo HTTP server and a clock that advances 5 minutes for each round. The
tests cover these cases:

- all Ok
- failure with alert and recovery
- failure under the threshold
- unknown state
- disabled Server
- missing expected Server
- API down (with the Server counters preserved)
- unreachable API
- Telegram down
- unused fields that do not leak
- hidden token

These flags are useful for a manual test:

- `-dry-run`: the tool prints the messages instead of sending them. It does not read the Telegram
  secrets.
- `-state <file>`
- `-credentials-dir <cartella>`
- `-threshold N`

## Installation

For the installation, read `nodes/scope/systemd/README.md`.
