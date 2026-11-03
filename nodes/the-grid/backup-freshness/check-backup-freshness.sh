#!/bin/bash
# ==============================================================
# BACKUP FRESHNESS — daily check of the backup folders on the-grid
# Host: the-grid. Cron of ops: every day at 08:40 (crontab.txt in this folder).
#
# Why: on 2026-11-01 the offsite copy of ARCADE stopped (dvb v2.50.0 wanted the host
# key of the-grid). No message came: the error came before the notifications of dvb, and nobody
# saw that the weekly ✅ was missing. Refer to PROBLEMI-E-SOLUZIONI.md 13.9.
#
# The script reads only the time and the size of the files. It reads no archive, it stops
# no container, and it needs no sudo.
#
# Problems that each check finds:
#  - stale:   the newest archive is older than the limit of the folder;
#  - small:   the newest archive is less than half of the archive before it
#             (an archive that is truncated or empty);
#  - missing: the folder is not there, or it has no archive.
# Telegram (shared "Ops" bot, uniform format of CENSIMENTO-BOT-TELEGRAM.md):
#  - 🔴 when a check goes from good to bad, and again each day while it stays bad;
#  - 🔁 when a check is good again.
# No message when all checks are good. The state is in $STATE_DIR, one file for each check.
# The script writes the new state only after Telegram accepts the message: if the send
# fails, the next run sends the message again.
#
# Options:
#  --dry-run          show the result and the messages. No Telegram, no state change.
#  --state-dir DIR    use a different state folder (for tests).
#  --max-age-hours N  use N hours as the limit of all checks (for tests).
#  --test             add the line "🧪 PROVA" to the messages.
# ==============================================================

set -euo pipefail

SECRETS_DIR="/srv/docker/_secrets/telegram"
STATE_DIR="${HOME}/.local/state/backup-freshness"
HEADER_SERVICE="🐧 the-grid · 💾 Freschezza backup"
# An archive smaller than this percentage of the archive before it is "small".
SIZE_RATIO_MIN=50

# name | folder | file pattern | limit in hours | label in the message (Italian)
# The limits: one normal interval plus one day. A skipped run gives an alert the next
# morning, or the same morning for the Tuesday and Friday runs.
CHECKS=(
    "offsite-v4|/srv/backup/from-arcade|arcade-volumes-*.tar.gz.age|192|Copia offsite di ARCADE (dvb-remote-the-grid, dom 06:00)"
    "volumes-the-grid|/srv/backup/docker-volumes|the-grid-volumes-*.tar.gz.age|96|Backup volumi di the-grid (dvb-local, mar+ven 03:00)"
    "bitwarden|/srv/backup/bitwarden-dumps|bitwarden_vault_*.sql.gz|192|Dump Bitwarden (dom 02:45)"
)

DRY_RUN=0
TEST=0
MAX_AGE_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --test) TEST=1 ;;
        --state-dir) STATE_DIR="$2"; shift ;;
        --max-age-hours) MAX_AGE_OVERRIDE="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

NOW=$(date +%s)

fmt_size() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.1f GB", b / 1073741824
        else if (b >= 1048576) printf "%.0f MB", b / 1048576
        else printf "%.0f KB", b / 1024
    }' | tr . ,
}

fmt_days() {
    awk -v s="$1" 'BEGIN { printf "%.1f", s / 86400 }' | tr . ,
}

fmt_limit() {
    if [ $(( $1 % 24 )) -eq 0 ]; then
        echo "$(( $1 / 24 )) giorni"
    else
        echo "$1 ore"
    fi
}

fmt_date() {
    date -d "@$1" '+%d/%m %H:%M'
}

# Sets STATUS (ok, stale, small or missing), DETAIL (Italian text for the message) and
# NEWEST (name, size and date of the newest archive).
evaluate() {
    local dir="$1" pattern="$2" max_hours="$3"
    local list first second m1 s1 n1 m2 s2 n2 age
    STATUS="ok"
    DETAIL=""
    NEWEST=""
    if [ ! -d "$dir" ]; then
        STATUS="missing"
        DETAIL="la cartella $dir non c'è"
        return 0
    fi
    # The two newest archives, newest first: "<mtime> <size> <name>".
    # A find error (for example no permission) gives an empty list, so "missing".
    list=$(find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %s %f\n' 2>/dev/null \
        | sort -rn | head -n 2) || true
    if [ -z "$list" ]; then
        STATUS="missing"
        DETAIL="nessun archivio $pattern in $dir"
        return 0
    fi
    first=$(sed -n 1p <<< "$list")
    second=$(sed -n 2p <<< "$list")
    read -r m1 s1 n1 <<< "$first"
    m1=${m1%.*}
    NEWEST="$n1 ($(fmt_size "$s1"), $(fmt_date "$m1"))"
    age=$(( NOW - m1 ))
    if [ "$age" -gt $(( max_hours * 3600 )) ]; then
        STATUS="stale"
        DETAIL="l'ultimo archivio è di $(fmt_days "$age") giorni fa (soglia $(fmt_limit "$max_hours"))"
    fi
    if [ -n "$second" ]; then
        read -r m2 s2 n2 <<< "$second"
        if [ "$s2" -gt 0 ] && [ $(( s1 * 100 )) -lt $(( s2 * SIZE_RATIO_MIN )) ]; then
            if [ "$STATUS" = "ok" ]; then
                STATUS="small"
            fi
            DETAIL="${DETAIL:+$DETAIL; }l'ultimo archivio pesa $(fmt_size "$s1"), meno della metà del precedente ($(fmt_size "$s2"))"
        fi
    fi
    return 0
}

# Returns 0 if Telegram accepted the message.
send_telegram() {
    if [ ! -r "$SECRETS_DIR/bot_token" ] || [ ! -r "$SECRETS_DIR/chat_id" ]; then
        echo "WARN: cannot read the Telegram files in $SECRETS_DIR, no message sent"
        return 1
    fi
    # The token and the chat_id go to curl through --config on stdin. In the arguments of
    # the process they would be visible in `ps` during the call.
    if printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\n' \
        "$(tr -d '[:space:]' < "$SECRETS_DIR/bot_token")" "$(tr -d '[:space:]' < "$SECRETS_DIR/chat_id")" \
        | curl -fsS --max-time 30 --config - --data-urlencode "text=$1" > /dev/null; then
        return 0
    fi
    echo "WARN: the Telegram send failed"
    return 1
}

# $1 = status emoji, then one block of text for each line.
build_message() {
    local emoji="$1" block
    shift
    printf '%s %s\n' "$emoji" "$HEADER_SERVICE"
    if [ "$TEST" -eq 1 ]; then
        printf '🧪 PROVA: messaggio di test, nessun problema reale\n'
    fi
    printf '\n'
    for block in "$@"; do
        printf '%s\n\n' "$block"
    done
    printf '🕒 %s\n🔍 Dettagli: journalctl -t backup-freshness' "$(date '+%Y-%m-%d %H:%M:%S')"
}

# Sends the message, or shows it in a dry run. Returns 0 if the state can change.
deliver() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "--- message (dry run, not sent) ---"
        echo "$1"
        echo "--- end of message ---"
        return 0
    fi
    send_telegram "$1"
}

ALERTS=()
RECOVERIES=()
NAMES=()
NEW_STATES=()

for entry in "${CHECKS[@]}"; do
    IFS='|' read -r name dir pattern max_hours label <<< "$entry"
    if [ -n "$MAX_AGE_OVERRIDE" ]; then
        max_hours="$MAX_AGE_OVERRIDE"
    fi
    evaluate "$dir" "$pattern" "$max_hours"
    previous="ok"
    if [ -r "$STATE_DIR/$name" ]; then
        previous=$(head -n 1 "$STATE_DIR/$name")
    fi
    echo "$name: $STATUS (before: $previous, limit ${max_hours} h) newest: ${NEWEST:-none}"
    if [ "$STATUS" != "ok" ]; then
        if [ "$previous" = "ok" ]; then
            kind="Primo avviso"
        else
            kind="Promemoria: il problema c'era già al giro precedente"
        fi
        ALERTS+=("❌ $label: $DETAIL"$'\n'"📦 ${NEWEST:-nessun archivio}"$'\n'"📌 $kind")
        NEW_STATES+=("bad")
    else
        if [ "$previous" != "ok" ]; then
            RECOVERIES+=("✅ $label: di nuovo in regola"$'\n'"📦 $NEWEST")
        fi
        NEW_STATES+=("ok")
    fi
    NAMES+=("$name")
done

delivered=1
if [ "${#ALERTS[@]}" -gt 0 ]; then
    deliver "$(build_message "🔴" "${ALERTS[@]}")" || delivered=0
fi
if [ "${#RECOVERIES[@]}" -gt 0 ]; then
    deliver "$(build_message "🔁" "${RECOVERIES[@]}")" || delivered=0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry run: no state written"
elif [ "$delivered" -eq 1 ]; then
    mkdir -p "$STATE_DIR"
    for i in "${!NAMES[@]}"; do
        echo "${NEW_STATES[$i]}" > "$STATE_DIR/${NAMES[$i]}"
    done
    echo "state written in $STATE_DIR"
else
    echo "WARN: state not written, the next run sends the messages again"
fi

echo "done: ${#ALERTS[@]} problem(s), ${#RECOVERIES[@]} recovery(ies)"
