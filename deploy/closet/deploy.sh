#!/usr/bin/env bash
# Ship this branch to the closet LXC and (re)start the stack. Run from the desktop:
#   secret-broker run -c closet_forward_auth_secret=FAS -c closet_secret_key=SK -c closet_nextauth_secret=NAS \
#          -c closet_postgres_password=PGP -c synthetic_api_key=AIK -- deploy/closet/deploy.sh
# Secrets go to /opt/closet/.env (mode 600) over ssh stdin and are never echoed. Existing data volumes
# are untouched.
set -euo pipefail
LXC_IP=${LXC_IP:-192.168.9.70}
DIR=/opt/closet
cd "$(git rev-parse --show-toplevel)"
: "${FAS:?}" "${SK:?}" "${NAS:?}" "${PGP:?}" "${AIK:?}"

# Ship the tracked tree at HEAD plus this deploy dir (it may not be committed yet).
{ git archive --format=tar HEAD; } | ssh -o BatchMode=yes root@"$LXC_IP" "mkdir -p $DIR && tar -x -C $DIR"
tar -c deploy/closet | ssh -o BatchMode=yes root@"$LXC_IP" "tar -x -C $DIR"

cat <<EOF | ssh -o BatchMode=yes root@"$LXC_IP" "umask 077 && cat > $DIR/.env"
POSTGRES_USER=wardrobe
POSTGRES_PASSWORD=$PGP
POSTGRES_DB=wardrobe
SECRET_KEY=$SK
NEXTAUTH_SECRET=$NAS
FORWARD_AUTH_SECRET=$FAS
NEXTAUTH_URL=https://closet.ericminish.com
APP_URL=https://closet.ericminish.com
FORWARD_AUTH_LOGOUT_URL=https://closet.ericminish.com/cdn-cgi/access/logout
TRUSTED_PROXY_COUNT=2
# Synthetic (flat-rate subscription), not free Gemini: free-tier quota ran out too fast and trains on the photos.
# The LiteLLM gateway is loopback-only, so the LXC calls Synthetic directly.
AI_BASE_URL=https://api.synthetic.new/openai/v1
AI_API_KEY=$AIK
AI_VISION_MODEL=hf:moonshotai/Kimi-K3
AI_TEXT_MODEL=hf:moonshotai/Kimi-K3
AI_REASONING_EFFORT=none
AI_TIMEOUT=120
AI_TAGGING_CONCURRENCY=2
BG_REMOVAL_PROVIDER=rembg
BG_REMOVAL_MODEL=u2net
LOG_LEVEL=INFO
EOF

# Pre-migration dump (upstream: back up before upgrading; an alembic downgrade loses data). Skipped only on
# the very first deploy, when Postgres isn't running yet.
ssh -o BatchMode=yes root@"$LXC_IP" "chmod 755 $DIR/deploy/closet/*.sh; if docker ps --format '{{.Names}}' | grep -qx wardrobe_postgres; then $DIR/deploy/closet/backup.sh premigrate; else echo 'postgres not running: no pre-migration dump (first deploy)'; fi"

# Nightly dump timer (+ failure alert). Units are refreshed on every deploy.
ssh -o BatchMode=yes root@"$LXC_IP" "install -m 644 $DIR/deploy/closet/closet-backup.service $DIR/deploy/closet/closet-backup.timer $DIR/deploy/closet/closet-backup-alert.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now closet-backup.timer >/dev/null && systemctl list-timers closet-backup.timer --no-pager | sed -n 2p"

ssh -o BatchMode=yes root@"$LXC_IP" "cd $DIR && docker compose -f docker-compose.prod.yml -f deploy/closet/compose.closet.yml pull -q && docker compose -f docker-compose.prod.yml -f deploy/closet/compose.closet.yml up -d && docker compose -f docker-compose.prod.yml -f deploy/closet/compose.closet.yml exec -T backend alembic upgrade head && docker compose -f docker-compose.prod.yml -f deploy/closet/compose.closet.yml ps --format '{{.Name}}\t{{.Status}}'"
