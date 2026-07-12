#!/usr/bin/env bash
#
# Triggers WordPress's scheduled tasks (post publishing, backups, plugin
# maintenance, etc.) for every site via wp-cli, since DISABLE_WP_CRON is set
# in each site's wp-config.php — WordPress's default pseudo-cron only fires
# on page loads, which is unreliable on low-traffic personal sites.
#
# Intended to run every 5 minutes via host crontab (see infra/README.md for
# the crontab line). Safe to run even if a site's container isn't up (skips
# with a warning rather than failing the whole run), and safe to run
# concurrently with itself finishing late (wp-cli's own cron locking
# prevents double-execution of the same event).
#
# Usage: ./wp-cron.sh [site ...]
#   ./wp-cron.sh                     # all sites
#   ./wp-cron.sh benoitchantre.com   # one site

set -uo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

declare -A CONTAINER_FOR=(
    [benoitchantre.com]=benoit_wp
    [startertheme.benoitchantre.com]=startertheme_wp
)
sites=("$@")
if [ ${#sites[@]} -eq 0 ]; then
    sites=("${!CONTAINER_FOR[@]}")
fi

for site in "${sites[@]}"; do
    container="${CONTAINER_FOR[$site]:-}"

    if [ -z "$container" ]; then
        echo "skip: $site (unknown site)" >&2
        continue
    fi
    if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
        echo "skip: $site (container $container not running)" >&2
        continue
    fi

    # dependencies under PHP 8.5 — noisy but harmless, would otherwise
    # flood cron logs every 5 minutes.
    docker exec --user www-data "$container" wp cron event run --due-now 2>&1 \
        | grep -v "^Deprecated:" | grep -v "^$" \
        | sed "s/^/[$site] /"
done
