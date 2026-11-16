#!/usr/bin/env bash
# Restore drill: load the newest closet dump into a throwaway Postgres and compare row counts with live.
# Runs INSIDE CT 153:  /opt/closet/deploy/closet/restore-drill.sh [DUMP]
# Exits non-zero if the restore fails or any compared table differs. Rows written to live between the dump
# and the drill show up as a difference, so run it right after a dump (backup.sh nightly) on a quiet system.
set -euo pipefail
ROOT=/var/backups/closet
DUMP=${1:-$(ls -1t "$ROOT"/daily/closet-*.dump "$ROOT"/premigrate/closet-*.dump 2>/dev/null | head -1)}
[ -n "$DUMP" ] && [ -f "$DUMP" ] || { echo "no dump found" >&2; exit 1; }
LIVE=wardrobe_postgres
SCRATCH=closet-restore-drill
TABLES="users clothing_items item_images outfits outfit_items item_history"

docker rm -f "$SCRATCH" >/dev/null 2>&1 || true
trap 'docker rm -f "$SCRATCH" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$SCRATCH" --network none -e POSTGRES_PASSWORD=drill -e POSTGRES_USER=wardrobe \
  -e POSTGRES_DB=wardrobe postgres:15-alpine >/dev/null
for _ in $(seq 1 30); do docker exec "$SCRATCH" pg_isready -U wardrobe -q && break; sleep 1; done
docker exec -i "$SCRATCH" pg_restore -U wardrobe -d wardrobe --no-owner --exit-on-error < "$DUMP"

count() { docker exec "$1" psql -U wardrobe -d wardrobe -tAc "SELECT count(*) FROM $2"; }
echo "dump: $DUMP"
fail=0
for t in $TABLES; do
  live=$(count "$LIVE" "$t"); restored=$(count "$SCRATCH" "$t")
  status=OK; [ "$live" = "$restored" ] || { status=DIFF; fail=1; }
  printf '%-16s live=%-6s restored=%-6s %s\n' "$t" "$live" "$restored" "$status"
done
exit $fail
