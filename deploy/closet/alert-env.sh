#!/usr/bin/env bash
# Write the backup-alert SMTP login into CT 153 without the values touching argv or output. Run from the desktop:
#   secret-broker run -c brevo_smtp_user=BU -c brevo_smtp_password=BP -- deploy/closet/alert-env.sh you@example.com
set -euo pipefail
LXC_IP=${LXC_IP:-192.168.9.70}
TO=${1:?usage: alert-env.sh RECIPIENT_EMAIL}
: "${BU:?}" "${BP:?}"
printf 'machine smtp-relay.brevo.com login %s password %s\n' "$BU" "$BP" \
  | ssh -o BatchMode=yes root@"$LXC_IP" 'umask 077; mkdir -p /etc/closet-backup; cat > /etc/closet-backup/netrc'
printf 'ALERT_TO=%s\n' "$TO" \
  | ssh -o BatchMode=yes root@"$LXC_IP" 'umask 077; cat > /etc/closet-backup/alert.conf'
ssh -o BatchMode=yes root@"$LXC_IP" 'stat -c "%n %a %s bytes" /etc/closet-backup/netrc /etc/closet-backup/alert.conf'
