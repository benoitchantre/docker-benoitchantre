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
# Output policy: silent when everything is fine. It runs every 5 minutes, so
# logging each successful run would grow wp-cron.log forever. Only problems
# are printed (errors, warnings, skipped sites, a non-zero wp-cli exit
# status), each with a timestamp and the site name. An empty log means healthy.
#
# Usage: ./wp-cron.sh [site ...]
#   ./wp-cron.sh                     # all sites
#   ./wp-cron.sh benoitchantre.com   # one site

set -uo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

timestamp() { date '+%F %T'; }

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
        echo "$(timestamp) skip: $site (unknown site)" >&2
        continue
    fi
    if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
        echo "$(timestamp) skip: $site (container $container not running)" >&2
        continue
    fi

    output="$(docker exec --user www-data "$container" wp cron event run --due-now 2>&1)"
    status=$?

    # Drop what is routine so the log only shows problems:
    #  - "Deprecated:" notices from WordPress/plugin dependencies under PHP 8.5
    #    (noisy but harmless),
    #  - blank lines,
    #  - wp-cli's success output ("Executed the cron event '...' in 0.01s.",
    #    "Success: Executed a total of N cron events.").
    # This is a blacklist on purpose: anything unrecognised (Error:, Warning:,
    # PHP Fatal error, ...) still gets through.
    problems="$(printf '%s\n' "$output" \
        | grep -v -E '^(Deprecated:|$|Executed the cron event |Success: Executed a total of )' || true)"

    if [ -n "$problems" ]; then
        printf '%s\n' "$problems" | sed "s/^/$(timestamp) [$site] /"
    fi
    if [ "$status" -ne 0 ]; then
        echo "$(timestamp) [$site] wp cron event run exited with status $status" >&2
    fi
done
