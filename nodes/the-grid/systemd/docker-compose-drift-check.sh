#!/usr/bin/bash
# Every evening: reports on Telegram the containers that do not match the compose
# file of the repo on the-grid. A commit that changes image/labels/environment/ports/volumes
# has no effect until Compose creates the container again. The pins of 000a359 (14/09)
# stayed only in the repo for 8 days. A Watchtower run found them 9 days later
# (PROBLEMI-E-SOLUZIONI.md §2.12). It warns only when the situation CHANGES,
# also for the return to normal. Read only: it does not create anything again.
# DRY_RUN=1 prints the message instead of sending it and does not read the token.
set -euo pipefail

STACKS_DIR="/home/ops/github/homelab/nodes/the-grid"
# Shared "Ops" bot: the token and the chat are in the files of
# /srv/docker/_secrets/telegram, the same as for komodo-gate (since 2026-10-13.
# Before, watchtower/.env, which goes away with the removal of Watchtower). The
# script reads them only when it sends.
TELEGRAM_DIR="/srv/docker/_secrets/telegram"
HOST_LABEL="the-grid"
# StateDirectory= in the systemd unit sets STATE_DIRECTORY.
STATE_FILE="${STATE_DIRECTORY:-/var/lib/docker-compose-drift-check}/last"

# Never query the CLI when the daemon does not run. Socket activation would start it.
systemctl is-active --quiet docker.service || exit 0

find_drift() {
    local dir stack hashes containers dry_run recreate svc hash c running_hash cfg_image local_id
    for dir in "$STACKS_DIR"/*/; do
        dir=${dir%/}
        stack=$(basename "$dir")
        [ -f "$dir/docker-compose.yml" ] || continue
        # --hash prints only "service hash" and no value of the config, so there are
        # no secrets. The compose warnings (variables without a value) go to stderr.
        if ! hashes=$(cd "$dir" && docker compose config --hash "*" 2>/dev/null); then
            echo "ERRORE: $stack -> 'docker compose config' fallisce, compose o .env da controllare"
            continue
        fi
        containers=$(cd "$dir" && docker compose ps -a --format '{{.Service}} {{.Name}}' 2>/dev/null || true)
        # The config hash is not the only criterion of compose. Compose also creates
        # the container again in two cases. In the first case, the label
        # com.docker.compose.image does not match the expected digest.
        # The containers that Watchtower created again keep the label of the old container.
        # In the second case, networks or volumes differ. This happened on 24/09 on tautulli
        # (STATO-THE-GRID.md §5.18). --dry-run does the same reconciliation as the
        # real up, with no write call to the daemon, and it does not print the config.
        # It prints only "Container <name> <action>".
        if ! dry_run=$(cd "$dir" && docker compose --dry-run up -d 2>&1); then
            echo "ERRORE: $stack -> 'docker compose --dry-run up -d' fallisce, da controllare a mano"
            continue
        fi
        recreate=$(awk '$1 == "Container" && $3 == "Recreate" { print $2 }' <<< "$dry_run")
        while read -r svc hash; do
            [ -n "$svc" ] || continue
            c=$(awk -v s="$svc" '$1 == s { print $2; exit }' <<< "$containers")
            if [ -z "$c" ]; then
                echo "SENZA CONTAINER: $stack/$svc -> nel repo ma non creato (cd $dir && docker compose up -d)"
                continue
            fi
            # || true: a container that disappears in the middle of the run must not
            # cut the list. A list that is empty by mistake would look like a "return".
            running_hash=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.config-hash"}}' 2>/dev/null || true)
            if [ "$hash" != "$running_hash" ]; then
                echo "DRIFT: $stack/$svc ($c) -> compose cambiato, container non ricreato (cd $dir && docker compose up -d)"
                continue
            fi
            # Same config but the local image differs from the one in use. The pull
            # finished and the up never ran. The config hash does not see it, because the
            # tag is the same.
            cfg_image=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null || true)
            local_id=$(docker image inspect "$cfg_image" --format '{{.Id}}' 2>/dev/null || true)
            if [ -n "$local_id" ] && [ "$local_id" != "$(docker inspect "$c" --format '{{.Image}}' 2>/dev/null || true)" ]; then
                echo "IMMAGINE NON APPLICATA: $stack/$svc ($c) -> $cfg_image scaricata ma non in uso (cd $dir && docker compose up -d)"
                continue
            fi
            if grep -qxF "$c" <<< "$recreate"; then
                echo "RICREEREBBE: $stack/$svc ($c) -> config e immagine uguali, ma il prossimo up lo ricrea (label immagine, reti o volumi: cd $dir && docker compose --dry-run up -d)"
            fi
        done <<< "$hashes"
    done | sort
}

current=$(find_drift)
previous=$(cat "$STATE_FILE" 2>/dev/null || true)

[ "$current" = "$previous" ] && exit 0

if [ -n "$current" ]; then
    message="🔴 🖧 ${HOST_LABEL} · 🧭 Drift compose

${current}

I container non corrispondono al compose del repo su the-grid. Prima di lanciare up -d verifica cosa cambierebbe: PROBLEMI-E-SOLUZIONI.md §2.12."
else
    message="🔁 🖧 ${HOST_LABEL} · 🧭 Drift compose

Tutti i container corrispondono di nuovo ai compose del repo."
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '[DRY_RUN] %s\n' "$message"
else
    bot_token=$(tr -d '[:space:]' < "$TELEGRAM_DIR/bot_token")
    chat_id=$(tr -d '[:space:]' < "$TELEGRAM_DIR/chat_id")
    # The script saves the state only after a successful send. If Telegram fails, the script
    # tries again at the next run and does not lose the warning.
    curl -fsS --max-time 30 -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${message}" > /dev/null
fi
printf '%s' "$current" > "$STATE_FILE"
