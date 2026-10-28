#!/usr/bin/bash
set -euo pipefail

TIMEOUT=60
INTERVAL=2
elapsed=0

while ! tailscale ip -4 >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "tailscale-wait-online: timeout dopo ${TIMEOUT}s, IP non ancora assegnato — Docker parte comunque" >&2
        exit 0
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

exit 0
