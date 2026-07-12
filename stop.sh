#!/usr/bin/env bash
#
# Stops the stack. By default stops containers only (data/volumes untouched,
# fast to bring back up with start.sh). Pass --down to remove containers +
# networks too (still keeps named volumes, i.e. DB data, unless you also
# pass --volumes — which is destructive, see warning below).
#
# Usage:
#   ./stop.sh                       # stop everything (containers paused, not removed)
#   ./stop.sh benoitchantre.com     # stop just one site (Caddy untouched)
#   ./stop.sh --down                # stop + remove containers/networks for everything
#   ./stop.sh --down --volumes       # also DELETE named volumes (DB data!) — destructive

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_DIR"

MODE="stop"
REMOVE_VOLUMES=false
sites=()

for arg in "$@"; do
    case "$arg" in
        --down) MODE="down" ;;
        --volumes) REMOVE_VOLUMES=true ;;
        *) sites+=("$arg") ;;
    esac
done

if [ "$REMOVE_VOLUMES" = true ] && [ "$MODE" != "down" ]; then
    echo "--volumes requires --down" >&2
    exit 1
fi

if [ ${#sites[@]} -eq 0 ]; then
    mapfile -t sites < <(find sites -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
    stop_shared=true
else
    stop_shared=false
fi

compose_cmd() {
    if [ "$MODE" = "down" ]; then
        if [ "$REMOVE_VOLUMES" = true ]; then
            echo "!! Removing volumes for $1 — this deletes the database. !!" >&2
            read -r -p "Type the site/service name to confirm: " confirm
            [ "$confirm" = "$1" ] || { echo "Aborted." >&2; exit 1; }
            docker compose down --volumes
        else
            docker compose down
        fi
    else
        docker compose stop
    fi
}

for site in "${sites[@]}"; do
    site_dir="sites/$site"
    [ -f "$site_dir/docker-compose.yml" ] || { echo "skip: $site (not found)" >&2; continue; }
    echo "==> $site"
    (cd "$site_dir" && compose_cmd "$site")
done

if [ "$stop_shared" = true ]; then
    echo "==> Caddy"
    (cd caddy && compose_cmd "caddy")
fi

echo "==> Done."
