#!/usr/bin/bash
# Apply the PASSA results of komodo-gate on the-grid. This script follows the recipe
# "Apply a PASSA" in README.md, but it uses the CLI instead of the Deploy button.
#
# Usage (Faginux runs it, because it recreates containers - rule number one):
#   ssh the-grid 'bash -s' -- [--check-only] [--db-dump-done] <stack> <service> [<service>...] < apply-passa.sh
# --check-only runs all the checks and stops before any change.
#
# For each service, the script does these checks first. If one check fails, it
# stops before any change:
#   1. The gate verdict in /var/lib/komodo-gate/state.json is PASSA.
#   2. After "docker compose pull <service>", the local image ID is the digest
#      that the gate scanned. A republished tag stops the script.
#   3. A database image (postgres, mariadb, mysql, mongo) needs --db-dump-done.
#   4. "docker compose --dry-run up -d" recreates only the requested services.
# Then, one service at a time: "docker compose up -d --no-deps <service>", and
# a check of the image, the state and the Docker events.
#
# The script never prints environment variables and never runs "compose config"
# without --quiet.
set -euo pipefail

STACKS_DIR="/home/ops/github/homelab/nodes/the-grid"
STATE_FILE="/var/lib/komodo-gate/state.json"

db_dump_done=0
check_only=0
while [ "${1:-}" = "--db-dump-done" ] || [ "${1:-}" = "--check-only" ]; do
    [ "$1" = "--db-dump-done" ] && db_dump_done=1
    [ "$1" = "--check-only" ] && check_only=1
    shift
done
if [ $# -lt 2 ]; then
    echo "Usage: [--check-only] [--db-dump-done] <stack> <service> [<service>...]" >&2
    exit 2
fi
stack="$1"
shift
services=("$@")

cd "$STACKS_DIR/$stack"
docker compose config --quiet

gate_field() { # $1 = stack/service, $2 = field
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["services"].get(sys.argv[2],{}).get(sys.argv[3],""))' \
        "$STATE_FILE" "$1" "$2"
}

declare -A candidate_of image_of
for svc in "${services[@]}"; do
    verdict=$(gate_field "$stack/$svc" verdict)
    candidate=$(gate_field "$stack/$svc" candidate)
    if [ "$verdict" != "PASSA" ] || [ -z "$candidate" ]; then
        echo "STOP: $stack/$svc has no PASSA in the gate state (verdict='$verdict')."
        exit 1
    fi
    container=$(docker compose ps -q "$svc")
    if [ -z "$container" ]; then
        echo "STOP: $stack/$svc has no container."
        exit 1
    fi
    image=$(docker inspect "$container" --format '{{.Config.Image}}')
    case "$image" in
        *postgres*|*mariadb*|*mysql*|*mongo*)
            if [ "$db_dump_done" != "1" ]; then
                echo "STOP: $stack/$svc is a database ($image). Make a dump first, then add --db-dump-done."
                exit 1
            fi
            ;;
    esac
    docker compose pull -q "$svc"
    local_id=$(docker image inspect "$image" --format '{{.Id}}')
    want="${candidate##*@}"
    if [ "$local_id" != "$want" ]; then
        echo "STOP: $stack/$svc local image $local_id is not the digest that the gate scanned ($want)."
        echo "      The tag was republished. Wait for the next gate round."
        exit 1
    fi
    candidate_of[$svc]="$want"
    image_of[$svc]="$image"
    echo "OK check: $stack/$svc verdict=PASSA digest=$want"
done

recreate=$(docker compose --dry-run up -d 2>&1 | awk '$1 == "Container" && $3 == "Recreate" { print $2 }' | sort -u)
expected=$(for svc in "${services[@]}"; do docker inspect "$(docker compose ps -q "$svc")" --format '{{.Name}}' | sed 's#^/##'; done | sort -u)
if [ "$recreate" != "$expected" ]; then
    echo "STOP: the dry-run recreates other containers."
    echo "  dry-run: $(echo $recreate)"
    echo "  wanted:  $(echo $expected)"
    exit 1
fi
echo "OK dry-run: only $(echo $recreate) would be recreated."
if [ "$check_only" = "1" ]; then
    echo "CHECK-ONLY: all checks passed. Nothing changed."
    exit 0
fi

for svc in "${services[@]}"; do
    t0=$(date +%s)
    docker compose up -d --no-deps "$svc" 2>&1 | tail -2
    sleep 3
    t1=$(date +%s)
    container=$(docker compose ps -q "$svc")
    now_image=$(docker inspect "$container" --format '{{.Image}}')
    status=$(docker inspect "$container" --format '{{.State.Status}}')
    # A recreate renames the old container to "<id>_<name>" before it removes it.
    name=$(docker inspect "$container" --format '{{.Name}}' | sed 's#^/##')
    others=$(docker events --since "$t0" --until "$t1" --filter type=container --filter event=destroy \
        --format '{{.Actor.Attributes.name}}' | grep -vE "^([0-9a-f]+_)?${name}\$" || true)
    echo "$stack/$svc: image=$now_image status=$status"
    if [ "$now_image" != "${candidate_of[$svc]}" ] || [ "$status" != "running" ] || [ -n "$others" ]; then
        echo "FAILED: $stack/$svc does not have the expected result. Other containers destroyed: '${others}'"
        exit 1
    fi
    # Wait up to 120 s for a health check, if the image has one.
    for _ in $(seq 1 40); do
        health=$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
        [ "$health" = "starting" ] || break
        sleep 3
    done
    echo "$stack/$svc: health=$health"
    if [ "$health" = "unhealthy" ]; then
        echo "FAILED: $stack/$svc is unhealthy."
        exit 1
    fi
done

final=$(docker compose --dry-run up -d 2>&1 | awk '$1 == "Container" && $3 == "Recreate" { print $2 }')
if [ -n "$final" ]; then
    echo "WARNING: after the update, the dry-run still recreates: $(echo $final)"
    exit 1
fi
echo "DONE: $stack updated. The dry-run shows no other change."
