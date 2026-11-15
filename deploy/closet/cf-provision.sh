#!/usr/bin/env bash
# Provision Cloudflare for closet.ericminish.com: Access app, a remotely-managed tunnel with
# Access-JWT validation at the origin, and the DNS CNAME. Then install the connector on the LXC.
# Idempotent: it reuses the app, tunnel or record if one already exists.
#
# Run from the desktop (never paste the token anywhere):
#   secret-broker run -c cloudflare_api_token=CF -- deploy/closet/cf-provision.sh
# Prints only names and IDs; the tunnel token goes over ssh stdin and is never echoed.
set -euo pipefail

HOST=closet.ericminish.com
LXC_IP=${LXC_IP:-192.168.9.70}
ZONE=9cfe326c0ccf520e9d83ab575cc78570
TEAM=minish1
# Who may sign in: copied from the Vacation Planner app's policy. Add friends later by
# editing the "closet users" policy in the dashboard (or re-running with EXTRA_EMAILS="a@x b@y").
SOURCE_APP="Vacation Planner"
EXTRA_EMAILS=${EXTRA_EMAILS:-}

: "${CF:?run under secret-broker run -c cloudflare_api_token=CF}"
API=https://api.cloudflare.com/client/v4
cf() { local m=$1 p=$2; shift 2; curl -sS -X "$m" -H "Authorization: Bearer $CF" -H "Content-Type: application/json" "$API$p" "$@"; }
ok() { jq -e '.success' >/dev/null <<<"$1" || { echo "CF API error: $(jq -c '.errors' <<<"$1")" >&2; exit 1; }; }

ACCT=$(cf GET "/zones/$ZONE" | jq -r .result.account.id)

# 1. Access app
APP=$(cf GET "/accounts/$ACCT/access/apps" | jq -c --arg d "$HOST" '[.result[] | select(.domain==$d)][0] // empty')
if [ -z "$APP" ]; then
  INCLUDE=$(cf GET "/accounts/$ACCT/access/apps" | jq -c --arg n "$SOURCE_APP" '[.result[] | select(.name==$n)][0].policies[0].include')
  [ "$INCLUDE" != "null" ] || { echo "source policy not found" >&2; exit 1; }
  for e in $EXTRA_EMAILS; do INCLUDE=$(jq -c --arg e "$e" '. + [{"email":{"email":$e}}]' <<<"$INCLUDE"); done
  BODY=$(jq -n --arg d "$HOST" --argjson inc "$INCLUDE" '{
    name:"Closet (wardrowbe)", domain:$d, type:"self_hosted", session_duration:"720h",
    app_launcher_visible:false,
    policies:[{name:"closet users", decision:"allow", include:$inc, precedence:1}] }')
  R=$(cf POST "/accounts/$ACCT/access/apps" --data "$BODY"); ok "$R"; APP=$(jq -c .result <<<"$R")
  echo "created Access app $(jq -r .id <<<"$APP")"
else
  echo "Access app exists $(jq -r .id <<<"$APP")"
fi
AUD=$(jq -r .aud <<<"$APP")

# 2. Tunnel (remotely managed)
TUN=$(cf GET "/accounts/$ACCT/cfd_tunnel?name=closet&is_deleted=false" | jq -r '.result[0].id // empty')
if [ -z "$TUN" ]; then
  R=$(cf POST "/accounts/$ACCT/cfd_tunnel" --data '{"name":"closet","config_src":"cloudflare"}'); ok "$R"
  TUN=$(jq -r .result.id <<<"$R"); echo "created tunnel $TUN"
else
  echo "tunnel exists $TUN"
fi

# 3. Ingress: cloudflared itself rejects requests without a valid Access JWT for this app.
CFG=$(jq -n --arg h "$HOST" --arg t "$TEAM" --arg a "$AUD" '{config:{ingress:[
  {hostname:$h, service:"http://localhost:8081",
   originRequest:{access:{required:true, teamName:$t, audTag:[$a]}}},
  {service:"http_status:404"}]}}')
R=$(cf PUT "/accounts/$ACCT/cfd_tunnel/$TUN/configurations" --data "$CFG"); ok "$R"; echo "ingress set"

# 4. DNS
REC=$(cf GET "/zones/$ZONE/dns_records?name=$HOST" | jq -r '.result[0].id // empty')
DNS=$(jq -n --arg n "$HOST" --arg c "$TUN.cfargotunnel.com" '{type:"CNAME", name:$n, content:$c, proxied:true}')
if [ -z "$REC" ]; then R=$(cf POST "/zones/$ZONE/dns_records" --data "$DNS"); else R=$(cf PUT "/zones/$ZONE/dns_records/$REC" --data "$DNS"); fi
ok "$R"; echo "DNS $HOST -> tunnel"

# 5. Connector on the LXC (token via stdin, never argv on this side)
if ssh -o BatchMode=yes root@"$LXC_IP" 'systemctl is-active --quiet cloudflared'; then
  echo "connector already running"
else
  cf GET "/accounts/$ACCT/cfd_tunnel/$TUN/token" | jq -r .result \
    | ssh -o BatchMode=yes root@"$LXC_IP" 'read -r T; cloudflared service install "$T" >/dev/null 2>&1; systemctl is-active cloudflared'
fi
