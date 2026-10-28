#!/usr/bin/bash
# Every hour: reports on Telegram the active containers that have no network, or
# that have ports configured but not published. They can stay "Up" and even
# "healthy" (PROBLEMI-E-SOLUZIONI.md §2.10: tautulli/seerr/flaresolverr, about 15 h
# and nobody noticed). It warns only when the situation CHANGES, also for the
# return to normal. A failure at night must not produce one message every hour.
set -euo pipefail

# Shared "Ops" bot: the token and the chat are in the files of
# /srv/docker/_secrets/telegram, the same as for komodo-gate (since 2026-10-13.
# Before, watchtower/.env, which goes away with the removal of Watchtower). The
# script reads them only when it sends.
TELEGRAM_DIR="/srv/docker/_secrets/telegram"
HOST_LABEL="the-grid"
# StateDirectory= in the systemd unit sets STATE_DIRECTORY.
STATE_FILE="${STATE_DIRECTORY:-/var/lib/docker-network-check}/last"

# Never query the CLI when the daemon does not run. Socket activation would start it.
systemctl is-active --quiet docker.service || exit 0

find_problems() {
    local c mode nets bindings
    for c in $(docker ps --format '{{.Names}}'); do
        mode=$(docker inspect "$c" --format '{{.HostConfig.NetworkMode}}')
        # host/none/container:<id> have no network of their own by design.
        case "$mode" in host | none | container:*) continue ;; esac
        nets=$(docker inspect "$c" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')
        if [ -z "$nets" ]; then
            echo "SENZA RETE: $c -> docker network connect $mode $c && docker restart $c"
            continue
        fi
        # The network is present but the ports are not published again (case of §7.5).
        bindings=$(docker inspect "$c" --format '{{len .HostConfig.PortBindings}}')
        if [ "$bindings" -gt 0 ] && [ -z "$(docker port "$c")" ]; then
            echo "PORTE NON PUBBLICATE: $c -> docker restart $c"
        fi
    done | sort
}

current=$(find_problems)
previous=$(cat "$STATE_FILE" 2>/dev/null || true)

[ "$current" = "$previous" ] && exit 0

if [ -n "$current" ]; then
    message="🔴 🖧 ${HOST_LABEL} · 🌐 Rete container

${current}

Risultano Up ma sono irraggiungibili. Dettagli: PROBLEMI-E-SOLUZIONI.md §2.10."
else
    message="🔁 🖧 ${HOST_LABEL} · 🌐 Rete container

Tutti i container hanno di nuovo rete e porte."
fi

bot_token=$(tr -d '[:space:]' < "$TELEGRAM_DIR/bot_token")
chat_id=$(tr -d '[:space:]' < "$TELEGRAM_DIR/chat_id")

# The script saves the state only after a successful send. If Telegram fails, the script
# tries again at the next hour and does not lose the warning.
curl -fsS --max-time 30 -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${message}" > /dev/null
printf '%s' "$current" > "$STATE_FILE"
