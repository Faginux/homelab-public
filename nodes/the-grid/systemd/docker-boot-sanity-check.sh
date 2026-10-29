#!/usr/bin/bash
set -euo pipefail

# Shared "Ops" bot: the token and the chat are in the files of
# /srv/docker/_secrets/telegram (0400 ops, inside the encrypted backup), the
# same as for komodo-gate. Since 2026-10-13 the script does not read watchtower/.env
# any more, because it goes away with the removal of Watchtower
# (PIANO-KOMODO-SECRETS-GATE.md, Phase 4). Before, this script ran `source` on it,
# which means that it ran a .env file as root code.
TELEGRAM_DIR="/srv/docker/_secrets/telegram"
HOST_LABEL="the-grid"

BOT_TOKEN=$(tr -d '[:space:]' < "$TELEGRAM_DIR/bot_token")
CHAT_ID=$(tr -d '[:space:]' < "$TELEGRAM_DIR/chat_id")

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="${message}" > /dev/null
}

problems=()

# Stopped containers that must be up (restart policy different from "no").
while IFS= read -r name; do
    [ -z "$name" ] && continue
    policy=$(docker inspect "$name" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "")
    if [ -n "$policy" ] && [ "$policy" != "no" ]; then
        status=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "sconosciuto")
        problems+=("🔴 ${name}: ${status} (restart policy: ${policy})")
    fi
done < <(docker ps -a --filter 'status=exited' --filter 'status=restarting' --format '{{.Names}}')

# Containers that are up but with a failed healthcheck (not "starting"). Docker
# reports unhealthy only after the retries that follow start_period fail.
while IFS= read -r name; do
    [ -z "$name" ] && continue
    problems+=("🟠 ${name}: unhealthy")
done < <(docker ps --filter 'health=unhealthy' --format '{{.Names}}')

if [ "${#problems[@]}" -gt 0 ]; then
    body=""
    for p in "${problems[@]}"; do
        body="${body}${p}%0A"
    done
    send_telegram "🔴 🐧 <b>${HOST_LABEL} · 🩺 Sanity check post-boot</b>%0A${body}"
fi
