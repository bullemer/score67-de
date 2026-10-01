#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
base=/opt/score67
exec 9>"$base/deploy.lock"
flock -w 900 9
release=$(readlink -f "$base/current")
export RELEASE_SHA=$(basename "$release")
backup="$base/backups/$(date -u +%Y%m%dT%H%M%SZ)-daily.dump"
docker compose --project-name score67 --env-file "$base/shared/.env" \
    -f "$release/deploy/compose.yaml" exec -T db pg_dump -U score67 -d score67 -Fc > "$backup.partial"
mv "$backup.partial" "$backup"
# Keep 14 days of completed database backups; no database or volume is removed.
find "$base/backups" -maxdepth 1 -type f -name '*.dump' -mtime +14 -delete
