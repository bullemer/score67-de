#!/usr/bin/env bash
# Root-owned on the server. The GitHub SSH key is forced to run only this script.
set -Eeuo pipefail
umask 077
base=/opt/score67
exec 9>"$base/deploy.lock"
flock -w 900 9
IFS= read -r release_sha
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid release ID' >&2; exit 2; }
export RELEASE_SHA="$release_sha"
release="$base/releases/$release_sha"
incoming=$(mktemp -d "$base/releases/.incoming.XXXXXXXX")
previous=$(readlink -f "$base/current" || true)
started_new=false
cleanup() { rm -rf -- "$incoming"; }
trap cleanup EXIT
rollback() {
    code=$?
    trap - ERR
    echo "Deployment failed for $release_sha" >&2
    if [[ "$started_new" == true && -n "$previous" && -d "$previous" ]]; then
        echo "Restoring application from $(basename "$previous")" >&2
        RELEASE_SHA=$(basename "$previous") docker compose --project-name score67 \
            --env-file "$base/shared/.env" -f "$previous/deploy/compose.yaml" \
            up -d --no-build --wait --wait-timeout 120 app || true
    fi
    exit "$code"
}
trap rollback ERR
# Refuse oversized archives before extraction.
head -c 268435457 > "$incoming/release.tgz"
[[ $(stat -c %s "$incoming/release.tgz") -le 268435456 ]]
python3 - "$incoming" <<'PY'
import pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
with tarfile.open(root / 'release.tgz', 'r:gz') as archive:
    members = archive.getmembers()
    if sum(m.size for m in members) > 512 * 1024 * 1024:
        raise SystemExit('Expanded archive too large')
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] not in {'backend', 'control', 'shared', 'deploy', '.dockerignore'}:
            raise SystemExit('Unexpected archive path')
        if not member.isfile() and not member.isdir():
            raise SystemExit('Only regular files and directories are permitted')
    archive.extractall(root / 'source', members=members)
PY
if [[ -d "$release" ]]; then
    echo 'Reusing existing immutable release'
else
    mv "$incoming/source" "$release"
fi
chmod -R a+rX "$release"
compose=(docker compose --project-name score67 --env-file "$base/shared/.env" -f "$release/deploy/compose.yaml")
"${compose[@]}" config --quiet
"${compose[@]}" build --pull app
"${compose[@]}" up -d --wait --wait-timeout 120 db
backup="$base/backups/$(date -u +%Y%m%dT%H%M%SZ)-predeploy-$release_sha.dump"
"${compose[@]}" exec -T db pg_dump -U score67 -d score67 -Fc > "$backup.partial"
mv "$backup.partial" "$backup"
"${compose[@]}" run --rm --no-deps app .venv/bin/alembic upgrade head
started_new=true
"${compose[@]}" up -d --no-build --wait --wait-timeout 120 app
python3 - "$release_sha" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen('http://127.0.0.1:8067/health', timeout=10) as r:
    state = json.load(r)
assert state == {'status': 'ok', 'release': sys.argv[1]}, state
PY
ln -sfn "$release" "$base/current.next"
mv -Tf "$base/current.next" "$base/current"
printf '%s\n' "$release_sha" > "$base/deployed-sha"
echo "Successfully deployed $release_sha"
