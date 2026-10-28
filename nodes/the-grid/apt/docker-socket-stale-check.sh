#!/usr/bin/bash
# Reports the containers that mount docker.sock but started before the last
# activation of docker.socket. With live-restore they stay connected to the old
# socket, which is now closed (PROBLEMI-E-SOLUZIONI.md §2.11). Read only: it does
# not restart anything, it only prints. It always exits 0 and runs as an apt hook.
set -uo pipefail

command -v docker >/dev/null 2>&1 || exit 0
# Never query the CLI when the daemon does not run. Socket activation would start it.
# It would also start all the containers that have a restart policy.
systemctl is-active --quiet docker.service || exit 0

socket_since=$(systemctl show docker.socket -p ActiveEnterTimestamp --value)
[ -n "$socket_since" ] || exit 0
socket_epoch=$(date -d "$socket_since" +%s) || exit 0

stale=()
while IFS='|' read -r name started mounts; do
    case " $mounts " in
        *" /var/run/docker.sock "* | *" /run/docker.sock "*) ;;
        *) continue ;;
    esac
    started_epoch=$(date -d "$started" +%s) || continue
    if (( started_epoch < socket_epoch )); then
        stale+=("${name#/}")
    fi
done < <(docker ps -q | xargs -r docker inspect --format '{{.Name}}|{{.State.StartedAt}}|{{range .Mounts}}{{.Source}} {{end}}')

if (( ${#stale[@]} > 0 )); then
    echo
    echo "ATTENZIONE: docker.socket riattivato il ${socket_since}."
    echo "Questi container montano il socket vecchio e non parlano piu' col daemon:"
    printf '  - %s\n' "${stale[@]}"
    echo "Fix: docker restart ${stale[*]}"
    echo "(PROBLEMI-E-SOLUZIONI.md §2.11)"
    echo
fi
exit 0
