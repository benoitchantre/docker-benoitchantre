#!/usr/bin/env bash
#
# Back up every site under infra/sites/: a mysqldump of its DB container plus
# a tar of its bind-mounted content (wp-content, or public/ for Bedrock-style
# sites). Writes timestamped archives to infra/backups/ and prunes old ones.
#
# Usage:
#   ./backup.sh                 # back up all sites
#   ./backup.sh benoitchantre.com   # back up just one site (dir name under sites/)
#
# Intended to run via cron as the deploying user (needs docker group
# membership). See infra/README.md for the crontab line.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_DIR="$INFRA_DIR/sites"
BACKUP_DIR="$INFRA_DIR/backups"
KEEP_DAYS=14
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

sites=("$@")
if [ ${#sites[@]} -eq 0 ]; then
    mapfile -t sites < <(find "$SITES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
fi

for site in "${sites[@]}"; do
    site_dir="$SITES_DIR/$site"
    env_file="$site_dir/.env"

    if [ ! -f "$env_file" ]; then
        echo "skip: $site (no .env found at $env_file)" >&2
        continue
    fi

    # shellcheck disable=SC1090
    source "$env_file"

    db_container="$(docker compose -f "$site_dir/docker-compose.yml" ps -q db 2>/dev/null | head -n1)"
    if [ -z "$db_container" ]; then
        echo "skip: $site (db container not running)" >&2
        continue
    fi

    site_backup_dir="$BACKUP_DIR/$site"
    mkdir -p "$site_backup_dir"

    echo "==> $site: dumping database"
    docker exec "$db_container" \
        mariadb-dump --single-transaction --quick --no-tablespaces \
        -u root -p"${DB_ROOT_PASSWORD}" "${DB_NAME}" \
        > "$site_backup_dir/${site}-db-${TIMESTAMP}.sql"
    gzip -f "$site_backup_dir/${site}-db-${TIMESTAMP}.sql"

    echo "==> $site: archiving content"
    tar czf "$site_backup_dir/${site}-content-${TIMESTAMP}.tar.gz" \
        -C "$site_dir" wp-content/

    echo "==> $site: pruning backups older than ${KEEP_DAYS} days"
    find "$site_backup_dir" -name "${site}-*" -mtime "+${KEEP_DAYS}" -delete

    echo "==> $site: done ($site_backup_dir)"
done
