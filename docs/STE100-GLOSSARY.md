# STE100 glossary

This file lists the technical names and the project terms that stay unchanged in the rewritten
documents. Use each name in the same way every time.

Status: draft. The list covers the pilot files only. Each batch of files adds entries.

## Host names

| Name | Use |
|---|---|
| the-grid | The physical Debian host. Its host name and directory name is `the-grid`. |
| scope | The Raspberry Pi host. Do not write "Pi". |
| ARCADE | The Windows host. Write the full name. Do not write "V4" alone. |

## Product and tool names

Keep the spelling and the capital letters shown here.

| Name | Note |
|---|---|
| age | Encryption tool. Write "age" in lower case. Archive files end in `.age`. |
| Beszel | Product. |
| Bitwarden | Product. "Cloud" and "self-hosted" are the two vaults in the dedup project. |
| Caddy | Product. `Caddyfile` is the file name. |
| cron | Tool. Write "cron" in lower case. |
| Debian | Product. |
| Docker | Product. "Docker Desktop" is the Windows application. |
| DockHand | Product. `dockhand` in lower case is the name of a service or site. Do not change the case. |
| flaresolverr | Service name. Write it in lower case. |
| GitHub | Product. |
| Go | Programming language. |
| Kometa | Product. |
| Komodo | Product. Its parts are Core, MongoDB and Periphery. |
| MongoDB | Product. Do not shorten it to "Mongo". `komodo-mongo` is the container name. |
| Node | Runtime. Write "Node" with a version number, for example "Node 22". |
| npm | Tool. Write "npm" in lower case. |
| Plex | Product. |
| Python | Product. |
| systemd | Tool. Write "systemd" in lower case. |
| Tailscale | Product. "tailnet" is the private network. |
| Telegram | Product. |
| Termius | Product. |
| Watchtower | Product. |
| Windows | Product. |

## Project terms

| Term | Meaning in these documents |
|---|---|
| Regola numero uno | The first rule of the project, in `CLAUDE.md`. `CLAUDE.md` stays in Italian. Write the name in Italian and add "(rule number one)" at the first use in each file. |
| round | One run of a script, for example of the pull script. |
| Run Directory | A Komodo term. Keep the English words and the capital letters. |
| Scheduled Task | A task in the Windows Task Scheduler. Keep the capital letters. |
| sparse-checkout | A Git term. Keep it. |
| Stack | With a capital S: a resource type in Komodo. With a small s: a Docker stack. |
| repo | The Git repository of this project. |
| unit file | The systemd file, for example `komodo-periphery.service`. |
| state transition | A change of state of a container, for example `up`, `down` or `restart`. Faginux starts every state transition. |
| dedup | The deletion of duplicate items in a vault. |
| wipe | The deletion of all data in a vault. |
| pinned | Fixed at one version. |
| onboarding key | The key that attaches a new server to Komodo. |

## Writing conventions

These choices apply to every rewritten file.

1. Write dates in ISO 8601 format, for example `2026-10-06`. The format DD/MM/YYYY is ambiguous in English.
2. Write "directory", not "folder".
3. Use "delete" for the destruction of data. Use "remove" only for the detachment of a part.
4. Use "read" for the action of opening a document. Do not use "see".
5. A table cell may start with a short noun phrase that labels the content. Every other statement in the cell is a complete sentence.
6. Comments inside code blocks stay in the original language. A code block never changes.
