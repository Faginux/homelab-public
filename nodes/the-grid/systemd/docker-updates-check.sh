#!/usr/bin/bash
# Weekly: if the Docker repo has new versions of the installed packages, it
# notifies on Telegram. It installs nothing. The upgrades of Docker stay manual
# (PROBLEMI-E-SOLUZIONI.md §2.11). Silence = nothing to update.
set -euo pipefail

# Shared "Ops" bot: the token and the chat are in the files of
# /srv/docker/_secrets/telegram, the same as for komodo-gate (since 2026-10-13.
# Before, watchtower/.env, which goes away with the removal of Watchtower). The
# script reads them only when it sends.
TELEGRAM_DIR="/srv/docker/_secrets/telegram"
HOST_LABEL="the-grid"

# apt-daily.timer updates the cache (APT::Periodic::Update-Package-Lists). Here the
# script only reads it: no root and no network.
upgradable=$(apt list --upgradable 2>/dev/null)

# docker-ce/trixie 5:29.8.2-1~debian.13~trixie amd64 [upgradable from: 5:29.8.1-1~debian.13~trixie]
# -> "docker-ce: 29.8.1 -> 29.8.2" (without the epoch "5:" and the package suffix)
updates=$(printf '%s\n' "$upgradable" | awk -F'[/ ]' '
    /^(docker-|containerd\.io\/)/ {
        new = $3; old = $7
        sub(/\]$/, "", old)
        sub(/^[0-9]+:/, "", new); sub(/^[0-9]+:/, "", old)
        sub(/-[^-]*$/, "", new);  sub(/-[^-]*$/, "", old)
        print $1 ": " old " -> " new
    }')

[ -n "$updates" ] || exit 0

bot_token=$(tr -d '[:space:]' < "$TELEGRAM_DIR/bot_token")
chat_id=$(tr -d '[:space:]' < "$TELEGRAM_DIR/chat_id")

message="⬆️ 🐧 ${HOST_LABEL} · 📥 Aggiornamenti Docker

${updates}

Da applicare a mano (apt upgrade). Subito dopo, l'hook apt elenca i container da riavviare (PROBLEMI-E-SOLUZIONI.md §2.11).
Note di rilascio: https://docs.docker.com/engine/release-notes/"

# --data-urlencode: newlines and special characters arrive intact with no escape by
# hand. No output, because the URL has the token.
curl -fsS --max-time 30 -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${message}" > /dev/null
