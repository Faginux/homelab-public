#!/usr/bin/bash
# Every hour: reports on Telegram the network problems that are not visible
# from "docker ps". The containers stay "Up" and even "healthy":
#  - a container has no network, or it has ports configured but not published
#    (PROBLEMI-E-SOLUZIONI.md §2.10: tautulli/seerr/flaresolverr, about 15 h
#    and nobody noticed);
#  - Caddy sees the Docker gateway in place of the tailnet client, so all the
#    private routes give 404 (§1.7: Tailscale upgrade of 2026-11-12).
# It warns only when the situation CHANGES, also for the return to normal. A
# failure at night must not produce one message every hour.
set -euo pipefail

# Shared "Ops" bot: the token and the chat are in the files of
# /srv/docker/_secrets/telegram, the same as for komodo-gate (since 2026-10-13.
# Before, watchtower/.env, which goes away with the removal of Watchtower). The
# script reads them only when it sends.
TELEGRAM_DIR="/srv/docker/_secrets/telegram"
HOST_LABEL="the-grid"
# StateDirectory= in the systemd unit sets STATE_DIRECTORY.
STATE_FILE="${STATE_DIRECTORY:-/var/lib/docker-network-check}/last"
# DRY_RUN=1: print the problems, send nothing, save nothing.
DRY_RUN="${DRY_RUN:-0}"
# The Caddy check counts the requests of this time window. A test can make it
# longer, to find a failure of the past.
CADDY_WINDOW_SECONDS="${CADDY_WINDOW_SECONDS:-3600}"
# A curl from the-grid itself to a private route also comes from the Docker gateway
# (1 request on 2026-11-04). During the failure of §1.7 there were about 130
# requests each hour. The threshold is far from both values.
CADDY_404_THRESHOLD=5

# Never query the CLI when the daemon does not run. Socket activation would start it.
systemctl is-active --quiet docker.service || exit 0

find_container_problems() {
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
    done
}

# Tailscale must not apply SNAT to the packets that Docker forwards (§1.7).
# Without NoSNAT, the next restart of tailscaled puts the problem back, and the
# auto-update of Tailscale is on. This alarm comes before the failure.
# "tailscale debug prefs" is the only way to read the preference without root.
# It is a debug command, so its format can change. A value that the script
# cannot read is also a problem: a false alarm is better than silence.
find_tailscale_problems() {
    local nosnat="" attempt
    command -v tailscale > /dev/null 2>&1 || return 0
    for attempt in 1 2; do
        nosnat=$(tailscale debug prefs 2> /dev/null | python3 -I -c '
import json, sys
print(json.load(sys.stdin).get("NoSNAT"))' 2> /dev/null) || nosnat=""
        [ -n "$nosnat" ] && break
        # tailscaled can be in a restart for an update: wait, then try again one time.
        [ "$attempt" = 1 ] && sleep 20
    done
    case "$nosnat" in
        True) ;;
        False) echo "TAILSCALE CON SNAT: al prossimo riavvio di tailscaled Caddy blocca il tailnet -> sudo tailscale set --snat-subnet-routes=false" ;;
        *) echo "TAILSCALE: preferenza NoSNAT non leggibile -> tailscale debug prefs | grep NoSNAT" ;;
    esac
}

# Caddy must see the real IP of the tailnet clients (100.64.0.0/10). If it
# sees the Docker range, the remote_ip matcher fails and the private routes go
# to the 404 fallback. The public routes continue to work, so nothing else
# shows the failure. This check finds the failure for each cause, also a cause
# that is not Tailscale.
# The file on the host is root 600: the script reads it through the container.
# The text of the line does not contain the count. If it did, the state would
# change each hour and the alarm would repeat each hour.
find_caddy_problems() {
    local since count
    [ "$(docker inspect caddy --format '{{.State.Running}}' 2> /dev/null)" = true ] || return 0
    since=$(( $(date +%s) - CADDY_WINDOW_SECONDS ))
    # 20000 lines are more than one hour, also during the failure (about 280
    # lines each hour). grep removes the lines that are not 404 before python.
    count=$(docker exec caddy tail -n 20000 /var/log/caddy/access.log \
        | { grep -F '"status":404' || true; } \
        | python3 -I -c '
import ipaddress, json, sys
since = float(sys.argv[1])
docker_range = ipaddress.ip_network("172.16.0.0/12")
count = 0
for line in sys.stdin:
    try:
        entry = json.loads(line)
        if entry["ts"] < since or entry.get("status") != 404:
            continue
        if ipaddress.ip_address(entry["request"]["remote_ip"]) in docker_range:
            count += 1
    except (ValueError, KeyError, TypeError):
        continue
print(count)' "$since") || count=""
    if [ -z "$count" ]; then
        echo "CADDY: access.log non leggibile -> docker exec caddy tail -n 3 /var/log/caddy/access.log"
    elif [ "$count" -ge "$CADDY_404_THRESHOLD" ]; then
        echo "CADDY VEDE IP DOCKER: le route private danno 404 al tailnet -> tailscale debug prefs | grep NoSNAT"
    fi
}

current=$(
    {
        find_container_problems
        find_tailscale_problems
        find_caddy_problems
    } | sort
)
previous=$(cat "$STATE_FILE" 2> /dev/null || true)

if [ "$DRY_RUN" = 1 ]; then
    printf 'problemi adesso:\n%s\n\nultimo stato notificato:\n%s\n' "${current:-(nessuno)}" "${previous:-(nessuno)}"
    exit 0
fi

[ "$current" = "$previous" ] && exit 0

if [ -n "$current" ]; then
    message="🔴 🐧 ${HOST_LABEL} · 🌐 Rete container

${current}

Risultano Up ma sono irraggiungibili. Dettagli: PROBLEMI-E-SOLUZIONI.md §2.10 (container), §1.7 (tailnet e Caddy)."
else
    message="🔁 🐧 ${HOST_LABEL} · 🌐 Rete container

Di nuovo tutto a posto: rete e porte dei container, tailnet su Caddy."
fi

bot_token=$(tr -d '[:space:]' < "$TELEGRAM_DIR/bot_token")
chat_id=$(tr -d '[:space:]' < "$TELEGRAM_DIR/chat_id")

# The script saves the state only after a successful send. If Telegram fails, the script
# tries again at the next hour and does not lose the warning.
curl -fsS --max-time 30 -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${message}" > /dev/null
printf '%s' "$current" > "$STATE_FILE"
