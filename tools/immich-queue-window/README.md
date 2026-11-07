# immich-queue-window: the ML queues of Immich run at night only

`Set-ImmichMlQueue.ps1` pauses four queues of Immich in the day and resumes them at night. In the
day, the GPU of ARCADE then has free VRAM for the local LLM (`PLAN-LOCAL-LLM.md`, step M1b-B).

## Why

Immich ML is the largest GPU user of the host. After step M1b-A (OCR off, model TTL 60 s,
concurrency 1), a busy Immich ML still uses about 1.5 GB of VRAM. The local LLM works in the day,
when Claude Code works. The ML jobs of new photos can wait until the night.

## Queues

| Queue | In the day | Reason |
|---|---|---|
| `smartSearch` | Paused | CLIP embeddings (GPU). Duplicate detection uses them. |
| `faceDetection` | Paused | Face models (GPU). |
| `facialRecognition` | Paused | It needs the faces of `faceDetection`. |
| `videoConversion` | Paused | NVENC transcode in `immich-server` (GPU). |
| `thumbnailGeneration`, `metadataExtraction` | Active | A new photo shows at once. |
| `duplicateDetection` | Active | It uses the database, not the GPU. It waits for the CLIP embeddings. |

Immich keeps the jobs of a paused queue. When the queue is active again, the jobs run.

## Usage

```powershell
.\Set-ImmichMlQueue.ps1 -State Auto              # dry run: read the queues, show the change
.\Set-ImmichMlQueue.ps1 -State Paused -Apply     # pause the four queues now
.\Set-ImmichMlQueue.ps1 -State Active -Apply     # resume the four queues now
.\Set-ImmichMlQueue.ps1 -State Auto -Apply       # the command of the Scheduled Task
```

`Auto` gives `Paused` from `DayStart` to `DayEnd` (local time) and `Active` in the other hours.
The script compares the time one minute ahead, so a trigger that starts a little early gets the
state of the new window. Each run of `Auto` gives the correct state: also a late run after a boot,
or two runs in the wrong order.

With `-Apply`, the script reads each queue again after the change. If the state did not change, the
run fails. The script writes one line to the run log for each `-Apply` run. A dry run writes nothing.

## Settings and API key

The settings are outside the repo, because `tools/` is public:
`~/.config/immich-queue-window/settings.psd1`. The file has no secret.

| Key | Value |
|---|---|
| `BaseUrl` | The URL of `immich-server`, with no `/api` |
| `ApiKeyFile` | The file with the API key (one line, no other text) |
| `TelegramConfigPath` | The config of the shared "Ops" bot. The script reads it only to send a failure message |
| `RunLog` | The NDJSON run log |
| `DayStart`, `DayEnd` | The day window, for example `07:30` and `22:30` |

The API key:

1. An admin user makes it: the queue routes are for admins only.
2. In the web UI (English labels): avatar → *Account Settings* → *API Keys* → *New API Key*.
3. The key has only the permissions `queue.read` and `queue.update`.
4. The operator writes the key to `ApiKeyFile` with `Read-Host -AsSecureString`. Never paste the key
   in a chat or in a file of the repo.

Checked on 2026-11-07 with Immich v3.3.5: with this key, `/api/queues` answers 200, and
`/api/users/me`, `/api/system-config` and `/api/assets/statistics` answer 403.

## Schedule

| What | Value |
|---|---|
| Scheduled Task | `Immich-MlQueueWindow`, two daily triggers: 07:30 and 22:30 (local time, `StartBoundary` with no UTC offset) |
| Launcher | `Set-ImmichMlQueue.vbs` (`wscript.exe`, no console window). It finds the script in its own folder and returns the exit code of pwsh |
| Account | The normal user, Limited. `StartWhenAvailable`, time limit 5 minutes |

## Failure

- With `-Apply`, the script tries 3 times, with 60 s between the tries. At a boot, the task can
  start before Docker Desktop and Immich are up.
- After 3 failures, it sends one Telegram message (🔴, in Italian) and exits with code 1.
- The message never contains the API key or the bot token.

Run log fields: `ts`, `requested`, `target`, `result`, `attempts`, `seconds`, `queues` (state before
and after, and the counts `Held`, `Waiting`, `Active`, `Delayed`, `Failed`), `error`, `telegram`.

`Held` is the `paused` count of the queue. In a paused queue, the new jobs go to this count, not to
`Waiting`. Test of 2026-11-07: three uploads in the day gave `Held` 3 in `smartSearch` and in
`faceDetection`, and the thumbnails were ready at once.

## Limits

- Immich keeps the pause in Redis. `immich-redis` has no volume, so a recreate of that container
  removes the pause. The next run of the task makes the pause again.
- A video that comes in the day gets its transcode at night. Until then, a browser can fail to play
  an HEVC video from a phone.
- A very large upload can make a backlog that runs after 01:45 (database dump of Immich) or 03:00
  (Plex maintenance).

## Rollback

1. Remove the Scheduled Task `Immich-MlQueueWindow`.
2. Run `.\Set-ImmichMlQueue.ps1 -State Active -Apply`.
