# closet deploy

How this fork runs at `closet.ericminish.com` on a homelab LXC: upstream `docker-compose.prod.yml`
plus an overlay. Cloudflare Access is the only login.

Request path: Cloudflare Access → cloudflared on the LXC (checks the Access JWT) → Caddy on
loopback `:8081`. Caddy maps the Access email to wardrowbe's forward-auth headers → upstream nginx.

| File | Purpose |
|---|---|
| `compose.closet.yml` | Pins the upstream images and adds the Caddy service |
| `Caddyfile` | Strips client-sent `Remote-*` headers and maps `Cf-Access-Authenticated-User-Email` |
| `cf-provision.sh` | One-time and idempotent: creates the Access app, the tunnel with JWT validation, DNS and the connector |
| `deploy.sh` | Ships HEAD, writes `.env` from secret-broker, pulls, runs `up -d` and `alembic upgrade head` |

```bash
secret-broker run -c cloudflare_api_token=CF -- deploy/closet/cf-provision.sh
secret-broker run -c closet_forward_auth_secret=FAS -c closet_secret_key=SK -c closet_nextauth_secret=NAS \
  -c closet_postgres_password=PGP -c synthetic_api_key=AIK -- deploy/closet/deploy.sh
```

AI: Synthetic's OpenAI-compatible API, `hf:moonshotai/Kimi-K3`, for both tagging and suggestions.
To add a user, edit the "closet users" Access policy, or re-run `cf-provision.sh` with `EXTRA_EMAILS`.
