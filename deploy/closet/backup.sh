#!/usr/bin/env bash
# Dump the closet Postgres to /var/backups/closet. Runs INSIDE the closet LXC (CT 153).
#   backup.sh nightly      # systemd timer: daily dump, plus a weekly copy on Sundays
#   backup.sh premigrate   # deploy.sh, before pulling images and running alembic
# The nightly PBS job (vzdump --all, 21:45 America/New_York on m720q1) carries these files off-host;
# the timer runs 30 min earlier so each PBS snapshot holds a consistent dump.
# Retention: 7 daily, 4 weekly, 5 premigrate. A dump only lands after `pg_restore --list` reads it.
set -euo pipefail
MODE=${1:-nightly}
ROOT=/var/backups/closet
CONTAINER=wardrobe_postgres
DB=wardrobe
DB_USER=wardrobe

case "$MODE" in
  nightly|premigrate) ;;
  *) echo "usage: $0 nightly|premigrate" >&2; exit 2 ;;
esac

umask 077
mkdir -p "$ROOT/daily" "$ROOT/weekly" "$ROOT/premigrate"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
dir=$ROOT/$([ "$MODE" = nightly ] && echo daily || echo premigrate)
out=$dir/closet-$stamp.dump
tmp=$out.partial
trap 'rm -f "$tmp"' EXIT

docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB" -Fc > "$tmp"
# Verify the archive is readable and holds table data before keeping it.
entries=$(docker exec -i "$CONTAINER" pg_restore --list < "$tmp" | grep -c 'TABLE DATA' || true)
[ "$entries" -gt 0 ] || { echo "dump unreadable or empty: $entries TABLE DATA entries" >&2; exit 1; }
mv "$tmp" "$out"
trap - EXIT
echo "wrote $out ($(stat -c %s "$out") bytes, $entries tables with data)"

prune() { # prune DIR KEEP: keep the newest KEEP dumps
  find "$1" -maxdepth 1 -name 'closet-*.dump' -printf '%f\n' | sort -r | tail -n +"$(($2 + 1))" \
    | while read -r f; do rm -f "$1/$f"; done
}
if [ "$MODE" = nightly ]; then
  [ "$(date +%u)" = 7 ] && cp "$out" "$ROOT/weekly/"
  prune "$ROOT/daily" 7
  prune "$ROOT/weekly" 4
else
  prune "$ROOT/premigrate" 5
fi
