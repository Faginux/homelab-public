#!/bin/bash
# Writes <archive>.sha256 next to each complete backup archive that has none.
# The pull from ARCADE needs it (PIANO-DECLASSAMENTO-scope.md, A.2). The user
# v4pull has only read-only SFTP (internal-sftp -R) and cannot run sha256sum here, so
# the-grid prepares the hash for it. Standard Linux format "<hash>  <name>" (two spaces,
# no binary marker). It can also be checked with `sha256sum -c` from the folder.
#
# The .sha256 file says only that the copy on V4 is identical to the original on the-grid.
# Only decryption (A.5) shows that the archive can be restored.
#
# DRY_RUN=1: calculates and prints the hashes that it would write. It does not write
# and does not delete anything.
set -euo pipefail

# "folder|pattern". The script skips folders that do not exist. bitwarden-dumps comes
# with Part B of the plan.
SOURCES=(
    "/srv/backup/docker-volumes|*.tar.gz.age"
    "/srv/backup/bitwarden-dumps|*.sql.gz"
)
# A file touched in the last MIN_AGE_MIN minutes can still be in writing (a dvb
# started by hand). The hash of a half-written archive would never match.
MIN_AGE_MIN=10
DRY_RUN="${DRY_RUN:-0}"

created=0
removed=0
errors=0
start=$(date +%s)

for entry in "${SOURCES[@]}"; do
    dir="${entry%%|*}"
    pattern="${entry#*|}"
    if [ ! -d "$dir" ]; then
        echo "salto $dir: non esiste"
        continue
    fi

    while IFS= read -r -d '' file; do
        [ -e "$file.sha256" ] && continue
        name=$(basename "$file")
        if [ "$DRY_RUN" = 1 ]; then
            echo "DRY_RUN $(cd "$dir" && sha256sum -- "$name")"
            created=$((created + 1))
            continue
        fi
        # First in a .tmp, then mv. V4 must never read a half-written .sha256.
        if (cd "$dir" && sha256sum -- "$name") > "$file.sha256.tmp"; then
            mv -f "$file.sha256.tmp" "$file.sha256"
            created=$((created + 1))
        else
            echo "ERRORE: hash fallito per $file" >&2
            rm -f "$file.sha256.tmp"
            errors=$((errors + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -mmin +"$MIN_AGE_MIN" -print0)

    # .sha256 files left without an archive (the dvb retention deleted the archive)
    # and .tmp files left by an interrupted run.
    while IFS= read -r -d '' sum; do
        [ -e "${sum%.sha256}" ] && continue
        if [ "$DRY_RUN" = 1 ]; then
            echo "DRY_RUN rimuoverei l'orfano $sum"
        else
            rm -f "$sum"
        fi
        removed=$((removed + 1))
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sha256' -print0)
    if [ "$DRY_RUN" != 1 ]; then
        find "$dir" -maxdepth 1 -type f -name '*.sha256.tmp' -mmin +60 -delete
    fi
done

echo "manifest: ${created} creati, ${removed} orfani rimossi, ${errors} errori, $(( $(date +%s) - start )) s"
[ "$errors" -eq 0 ]
