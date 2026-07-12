#!/usr/bin/env bash
#
# Brings up the full production stack in the correct order: shared network
# and log volume, then Caddy, then each site (db healthy before wp/web).
# Idempotent — safe to re-run on an already-running stack.
#
# This does NOT import database dumps or run first-time migration steps —
# it assumes each site's DB volume already has data (either from a prior
# migration or a previous run). See infra/README.md for first-time setup
# and infra/sites/*/MIGRATION.md for data migration.
#
# Usage: ./start.sh [site ...]
#   ./start.sh                                   # everything
#   ./start.sh benoitchantre.com                 # just one site (+ shared infra)

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_DIR"

sites=("$@")
if [ ${#sites[@]} -eq 0 ]; then
    mapfile -t sites < <(find sites -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
fi

echo "==> Shared network + volume"
docker network inspect web >/dev/null 2>&1 || docker network create web
docker volume inspect caddy_logs >/dev/null 2>&1 || docker volume create caddy_logs

# A Caddy failure is reported but doesn't abort the whole run — a broken
# image pull or ACME hiccup shouldn't block getting the sites back up. Site
# bring-up below still uses `set -e` semantics per site.
echo "==> Caddy"
(cd caddy && docker compose up -d) || echo "!! Caddy failed to start — sites will be up but unreachable from outside until this is fixed" >&2

for site in "${sites[@]}"; do
    site_dir="sites/$site"
    if [ ! -f "$site_dir/docker-compose.yml" ]; then
        echo "skip: $site (no docker-compose.yml at $site_dir)" >&2
        continue
    fi
    if [ ! -f "$site_dir/.env" ]; then
        echo "skip: $site (no .env — copy .env.example and fill it in first)" >&2
        continue
    fi

    echo "==> $site: db"
    (cd "$site_dir" && docker compose up -d db)

    db_container="$(cd "$site_dir" && docker compose ps -q db)"
    echo -n "    waiting for db healthy"
    for _ in $(seq 1 30); do
        hc="$(docker inspect --format='{{.State.Health.Status}}' "$db_container" 2>/dev/null || echo "")"
        [ "$hc" = "healthy" ] && { echo " - healthy"; break; }
        echo -n "."
        sleep 2
    done

    echo "==> $site: wp + web"
    (cd "$site_dir" && docker compose up -d --build)
done

echo "==> Done. 'docker compose ps' in each directory, or 'docker ps', to check status."
