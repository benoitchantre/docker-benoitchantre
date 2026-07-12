#!/usr/bin/env bash
#
# Restore a site's database (and optionally its content) from a backup
# produced by backup.sh.
#
# Usage:
#   ./restore.sh <site> <db-dump.sql.gz> [content-archive.tar.gz]
#
# Example:
#   ./restore.sh benoitchantre.com \
#       backups/benoitchantre.com/benoitchantre.com-db-20260711-020000.sql.gz
#
# WARNING: this overwrites the target site's live database. For a dry-run /
# verification restore into a scratch environment instead, see the "restore
# into a scratch DB" section of infra/README.md.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <site> <db-dump.sql.gz> [content-archive.tar.gz]" >&2
    exit 1
fi

SITE="$1"
DB_DUMP="$2"
CONTENT_ARCHIVE="${3:-}"

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="$INFRA_DIR/sites/$SITE"
ENV_FILE="$SITE_DIR/.env"

[ -d "$SITE_DIR" ] || { echo "No such site: $SITE_DIR" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE" >&2; exit 1; }
[ -f "$DB_DUMP" ] || { echo "No such dump: $DB_DUMP" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

read -r -p "This will OVERWRITE the live database for $SITE. Type the site name to confirm: " CONFIRM
if [ "$CONFIRM" != "$SITE" ]; then
    echo "Aborted." >&2
    exit 1
fi

db_container="$(docker compose -f "$SITE_DIR/docker-compose.yml" ps -q db)"
[ -n "$db_container" ] || { echo "db container not running for $SITE" >&2; exit 1; }

echo "==> Restoring database from $DB_DUMP"
gunzip -c "$DB_DUMP" | docker exec -i "$db_container" \
    mariadb -u root -p"${DB_ROOT_PASSWORD}" "${DB_NAME}"

if [ -n "$CONTENT_ARCHIVE" ]; then
    [ -f "$CONTENT_ARCHIVE" ] || { echo "No such archive: $CONTENT_ARCHIVE" >&2; exit 1; }
    echo "==> Restoring content from $CONTENT_ARCHIVE"
    tar xzf "$CONTENT_ARCHIVE" -C "$SITE_DIR"
fi

echo "==> Restarting $SITE stack"
(cd "$SITE_DIR" && docker compose restart)

echo "==> Done. Verify the site in a browser before trusting this restore."
