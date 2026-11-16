#!/usr/bin/env bash
# Email a backup-failure alert through Brevo SMTP. Runs inside CT 153 (OnFailure of closet-backup.service).
# SMTP login lives in /etc/closet-backup/netrc (root, 600), written by deploy/closet/alert-env.sh; the
# recipient is in /etc/closet-backup/alert.conf (ALERT_TO=...). Nothing secret is passed on argv.
set -euo pipefail
CONF=/etc/closet-backup
# shellcheck disable=SC1091
. "$CONF/alert.conf"
: "${ALERT_TO:?}" "${ALERT_FROM:=Closet Backup <intel@ericminish.com>}"
SMTP=smtp-relay.brevo.com
log=$(journalctl -u closet-backup.service -n 30 --no-pager 2>&1 || true)
msg=$(mktemp); trap 'rm -f "$msg"' EXIT
{
  printf 'From: %s\nTo: %s\nSubject: [closet] nightly backup FAILED on %s\n\n' "$ALERT_FROM" "$ALERT_TO" "$(hostname)"
  printf 'closet-backup.service failed at %s.\nThe PBS job will copy whatever dumps exist; check /var/backups/closet.\n\nLast log lines:\n%s\n' \
    "$(date -u +%FT%TZ)" "$log"
} > "$msg"
from_addr=$(sed -E 's/.*<([^>]+)>.*/\1/' <<<"$ALERT_FROM")
curl -sS --ssl-reqd --netrc-file "$CONF/netrc" "smtp://$SMTP:587" \
  --mail-from "$from_addr" --mail-rcpt "$ALERT_TO" --upload-file "$msg"
