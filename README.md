# Homelab

This repo has the configuration of a small homelab with three hosts: Docker stacks, systemd units,
small tools in PowerShell, Go and shell, a generated map, and some dotfiles.

It is a public copy of a private repo. A script makes the copy from a fixed list of paths. The
copy has a new history, and the script replaces the private values before it publishes. Read
*What the script changes* below.

The repo is shared as it is. It is not a turnkey install and it has no support.

## The hosts

The names are aliases. The real names of the hosts are not in this repo.

| Host | Role |
|---|---|
| `arcade` | Windows 11 workstation with a GPU: Plex, Radarr, Sonarr and the Kometa jobs |
| `the-grid` | Mini PC with Debian: the public edge (Caddy and CrowdSec) and most of the apps |
| `scope` | Raspberry Pi 4 with Debian: Beszel hub, `komodo-watchdog`, and a test node |

## The folders

| Folder | Content |
|---|---|
| `nodes/the-grid/` | Compose files, systemd units and notes of the host `the-grid` |
| `nodes/scope/` | Beszel, Homepage and systemd units of the host `scope` |
| `stacks/` | The stacks that run on `arcade` (Docker Desktop) |
| `tools/` | Small tools: the CVE gate, the watchdog, the release check, backup helpers, the map scripts |
| `docs/map/` | The inventory of the homelab and the scripts that draw the map |
| `dotfiles/`, `dotfiles-windows/` | Neovim, tmux, starship, zsh, Windows Terminal |
| `docs/STE100-GLOSSARY.md` | The project terms for the writing style (read *Language*) |

## What the script changes

The script replaces these private values with fixed placeholders:

| Value | In this repo |
|---|---|
| The domain | `homelab.example` |
| The LAN addresses | `192.0.2.0/24`: router `.1`, `arcade` `.10`, `the-grid` `.20`, `scope` `.30` |
| The tailnet addresses | `198.51.100.0/24`: `arcade` `.10`, `the-grid` `.20`, `scope` `.30`, the phone `.40` |
| The Unix users | `ops` |
| The private trackers | `private tracker A` and `private tracker B` |
| The owner | the handle `Faginux` |

The real tailnet uses the range `100.64.0.0/10`. The text of this range stays in the files.

Before each publish, a gate checks the copy for secrets, addresses, keys, emails, home folders and
the public IP address of the home. It also runs gitleaks and checks the syntax of the scripts.

## Things to know

- **Language.** The documents and the comments are written in simplified technical English, with
  the rules of ASD-STE100. The notifications and the messages of the scripts (Telegram, logs, errors)
  are in Italian. They are the output of the tools, not the documentation.
- **Private notes.** Some files name other documents, for example `PIANO-*.md` or
  `PROBLEMI-E-SOLUZIONI.md`. These documents are private notes. They are not in this repo.
- **No real secrets.** Each stack has a `.env.example` file with dummy values. The real `.env`
  files are never committed. The compose files read them from the host.
- **Absolute paths.** A bind mount points to an absolute path on the host. Change the paths
  before you use a compose file.
- **Not included.** Some stacks and some host configurations are not part of this copy.

## Language

The names of the project terms are in `docs/STE100-GLOSSARY.md`.

## Licence

The code and the documents are under the MIT licence (`LICENSE`). The icons in `docs/map/icons/`
and some other files belong to other owners. Read `NOTICE`.
