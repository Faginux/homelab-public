#!/usr/bin/bash
# Wait until Tailscale has an IPv4 address, then exit.
# docker.service starts after this unit (drop-in wait-tailscale.conf), so
# containers that publish a port on the Tailscale IP do not fail at boot
# with "cannot assign requested address".
# Copy of the the-grid fix (nodes/the-grid/systemd/, PROBLEMI-E-SOLUZIONI.md).
# After the timeout the script exits with 0: Docker must start anyway.
set -euo pipefail

TIMEOUT=60
INTERVAL=2
elapsed=0

while ! tailscale ip -4 >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "tailscale-wait-online: timeout after ${TIMEOUT}s, no IP yet. Docker starts anyway." >&2
        exit 0
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

exit 0
