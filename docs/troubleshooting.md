# Troubleshooting

## Panel won't start: "PANEL_ADMIN_PASS is too weak"

The admin password must be ≥8 chars with an uppercase, lowercase, digit and
special character. Set a strong `PANEL_ADMIN_PASS` in `deploy/panel/.env`. For
local testing only, `PANEL_ALLOW_WEAK_PASS=1` bypasses the check.

## Sessions drop on every panel restart

`PANEL_JWT_SECRET` is unset, so an ephemeral one is generated each boot. Set a
stable value: `openssl rand -hex 32`.

## Node shows offline in the panel

- Check the agent logs: `./deploy.sh logs node`.
- The agent dials `PANEL_URL` **outbound** — make sure it's correct and
  reachable from the node (DNS + firewall). Use the public `https://` URL, not a
  private/internal address the node can't resolve.
- `NODE_TOKEN` must match the token from the panel's *Install* dialog.
- Time skew can break TLS; keep clocks in sync.

## Node online but clients can't connect

- **TLS-Vision** needs a valid cert at `deploy/node/certs/{fullchain,privkey}.pem`.
  Missing/expired certs break that inbound (REALITY still works). See
  [deployment.md](deployment.md#tls-certificates).
- Confirm `REALITY_SERVER_NAME` matches the SNI in the client's REALITY link and
  the value nginx routes on.
- The user must be **active** (enabled, not expired, under quota) and **assigned
  to that node**.

## Cert renewed but Xray still serves the old one

The agent watches `XRAY_CERT` and re-applies the config on change (which reloads
Xray, and re-enables TLS-Vision if the cert had been missing); it polls every
~30s. Confirm the new cert actually replaced the file the agent mounts
(`deploy/node/certs/`), and check agent logs for `tls cert changed`.

## Traffic isn't updating

- Traffic is sampled every `STATS_INTERVAL` seconds (default 60) and only sent
  when non-zero. Generate some traffic and wait a cycle.
- Check the agent can reach Xray's stats API: it runs `docker exec xray xray api
  statsquery …` inside the xray container.

## Device list / count is empty

Devices come from the Xray **access log** (`XRAY_ACCESS_LOG`). Ensure the log is
being written (it is enabled by default) and that the agent mounts the log
directory read-only (it does in the shipped compose). Counts cover the last 30
days of distinct source IPs.

## Telegram: nothing happens

- Set **both** `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ADMIN_IDS` in
  `deploy/panel/.env`, then recreate: `./deploy.sh panel`.
- Your numeric chat id must be in `TELEGRAM_ADMIN_IDS`. Message the bot; if it
  replies "Unauthorized … your chat id is N", add `N`.
- Use **Security → Send test message** in the panel to verify end-to-end.

## Healthcheck / reverse proxy

The panel's liveness endpoint is `GET /healthz` (unauthenticated, returns `ok`).
Point your load balancer / compose healthcheck at it, not at an authenticated
route.

## Reset the admin password

`PANEL_ADMIN_PASS` is re-synced to the DB on every boot. Change it in
`deploy/panel/.env` and recreate the panel (`./deploy.sh panel`).
