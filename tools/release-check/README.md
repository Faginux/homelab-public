# release-check — new versions of the pinned images

release-check reads the `image:` lines of the compose files in the repo. It asks the registries
for newer versions. It writes to Telegram when something changes.

**The tool never pulls and never deploys.** It reads the compose files and the public registries
only. Plan: `PIANO-RELEASE-CHECK.md`.

## One round

1. Read every `docker-compose.yml` under the `roots` of `config.json`. Read only the `image:`
   lines. Lines with a variable (`${...}`) and floating tags without a digest are skipped.
   The log shows each skip.
2. Group the identical references. One image used in 3 places is checked once.
3. For an image with a full version tag (`x.y.z`, `vx.y.z`, `yyyy.m.n`), read the tag list from
   the registry. Keep the tags that have the same `v` prefix, the same variant suffix (`-full`,
   `-cuda`) and the same number of parts. A pre-release (`-rc1`) never matches.
4. Pick two results: the newest version **in the track** ("safe"), and the newest version with a
   **higher first part** that is outside the track ("nuova major"). The tool never mixes them.
5. If the pin has a digest, read the digest of the same tag. A different digest is a **rebuild**
   of the tag.
6. Compare with `state.json`. Send one message if something changed. Save the state **only after
   a successful send**.

| Track | Safe update is | Used for |
|---|---|---|
| `major` (default) | same first part | most images |
| `minor` | same first two parts | `mongo` 8.0.x, `mariadb` 10.11.x (LTS) |
| `any` | any newer version | calendar versions (`bitwarden/lite`) |
| `rebuild` | none, only a new digest for the same tag | `umtk` (`latest` with a digest) |

## Message

The message uses the Telegram HTML parse mode. There is one block for each image, then the plain
lines, then a block to paste in Claude Code.

| Line | Meaning |
|---|---|
| `📦 nome — host stack` | Header of the block of one image. |
| `⬆️ a → b` | A safe update. |
| `🔁 a ricostruita (stesso tag, digest nuovo)` | The registry has a new image under the same tag. |
| `🆕 major a → b (da valutare, non nel comando)` | A higher first part. It is not in the command to paste. |
| `🔗 <url>` | The release notes (`notes` in `config.json`). |
| `ERRORE nome: <causa>` | The registry did not answer. This is **not** "no update". |
| `Rientrato: nome (motivo)` | The pin reached the reported version, or the error ended. |

The `<pre>` block (tap to copy) is a prompt for Claude Code. It lists the safe updates and the
rebuilds. It tells Claude to read the notes, check the backup, edit the pins and show the diff and
`docker compose --dry-run up -d`, then stop. The deploy stays with Faginux (rule number one). A
message with only new majors has no block.

If the message is too long, the tool leaves whole blocks out and adds a "troncato" line. The block to paste
is never cut: a cut tag makes Telegram refuse the message.

An image comes again only when the result for that image changes. The error text is not part of
the state, so the same error does not repeat.

## Config

`config.json` has no secrets. `roots` lists the folders and the host label. `images` is keyed by
the short image name (`mariadb`, `bitwarden/lite`). A key can have `track`, `notes` (URL of the
release notes, added to the message) and `skip`. The tool rejects an unknown key or an unknown
track. A key that matches no pin is a warning in the log.

## Non-obvious choices

- **A rebuild can be a false alarm** if the pin digest is the digest of one platform and not of
  the index. The compose files here pin the digest that `docker pull` shows for the tag. Check the
  first message by hand.
- **`--dry-run` does not save the state.** The first real round then reports everything.
- **Registry limits.** The tool retries 429 and 5xx answers 3 times and respects `Retry-After`.
  `ghcr.io/immich-app` has thousands of tags (about 30 pages) and gave 429 on the first test.
- **No new secret.** The tool needs only the Telegram files in `/srv/docker/_secrets/telegram/`.
  The Telegram token never appears in an error (`TestTelegramErrorHidesToken`).
- **"nuova major" for `mariadb` and `mongo`** shows the highest first part (for example 13.x for
  MariaDB, which is not an LTS). It is information, not a request to update.

## Use

Test (needs only the repo and the network, prints the message, sends nothing, saves nothing):

```powershell
cd S:\github\homelab\tools\release-check
go test ./...
go run . -repo ../.. -dry-run
```

Build for the-grid (static binary):

```powershell
cd S:\github\homelab\tools\release-check
$env:GOOS='linux'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'
go build -trimpath -ldflags '-s -w' -o $env:TEMP\release-check .
Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED
scp $env:TEMP\release-check the-grid:/tmp/release-check
```

Flags: `-repo` (root of the clone, default `.`), `-config`, `-secrets-dir`, `-state` (default
`$STATE_DIRECTORY/state.json`), `-host-label`, `-dry-run` (or `DRY_RUN=1`).

The units are `nodes/the-grid/systemd/release-check.{service,timer}`. They run every day at
08:05 as `ops`. The installation steps are in the README of that folder.
