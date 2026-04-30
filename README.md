# VLESS Vision + REALITY + Nginx Stream Docker

One-click deployment for VLESS Vision with both TLS and REALITY on public port
443. Nginx stream uses SNI preread to split traffic to the proper Xray inbound,
while normal HTTPS fallback content is still served by Nginx.

## Architecture

```text
client -> :443 -> nginx stream (ssl_preread)
                  ├── SNI = REALITY_SERVER_NAME -> xray:10443  VLESS + REALITY + Vision
                  └── default / your domain     -> xray:10444  VLESS + TLS + Vision
                                                       └── fallback -> nginx:8080 website
```

## Structure

```
vless-xtls-docker/
├── deploy.sh                    # Main script
├── docker-compose.yml           # Docker compose
├── .env.example                  # Example generated configuration
├── .env.telegram.example         # Example Telegram bot secrets
├── clash_config.yaml.template    # Clash config template
├── data/                         # Runtime user database (generated)
├── backups/                      # Runtime backups (generated)
├── xray/
│   └── config.json.template     # Xray config template
├── nginx/
│   ├── nginx.conf.template      # Nginx config template
│   └── html/                    # Fallback website
├── scripts/
│   ├── lib/common.sh             # Shared shell helpers
│   ├── renew-cert.sh            # Certificate renewal
│   ├── optimize.sh              # System optimization
│   ├── telegram-bot.sh          # Telegram management bot
│   ├── traffic-manager.sh       # Traffic stats and quota enforcement
│   └── user-log-splitter.sh     # Split Xray access log by user
└── LICENSE
```

## Quick Start

### Requirements

- VPS (Ubuntu 20.04+ recommended)
- Domain pointing to server IP
- Ports 80 and 443 open

### Install

```bash
chmod +x deploy.sh scripts/*.sh
sudo ./deploy.sh install
```

The installer prompts before applying optional global network optimization
settings. You can skip it during install and run it later with:

```bash
sudo ./deploy.sh optimize
```

## Commands

### Basic

| Command | Description |
|---------|-------------|
| `./deploy.sh install` | Install service |
| `./deploy.sh uninstall` | Uninstall service |
| `./deploy.sh start` | Start service |
| `./deploy.sh stop` | Stop service |
| `./deploy.sh restart` | Restart service |
| `./deploy.sh status` | Show service summary |
| `./deploy.sh doctor` | Run diagnostics |
| `./deploy.sh logs` | Show logs |

### Configuration

| Command | Description |
|---------|-------------|
| `./deploy.sh config` | Show configuration |
| `./deploy.sh backup` | Backup configuration |

### User Management

| Command | Description |
|---------|-------------|
| `./deploy.sh users` | List users |
| `./deploy.sh adduser` | Add user |
| `./deploy.sh deluser` | Delete user |
| `./deploy.sh enableuser <tag>` | Enable user |
| `./deploy.sh disableuser <tag>` | Disable user |
| `./deploy.sh expireuser <tag> <YYYY-MM-DD\|never>` | Set expiry |
| `./deploy.sh userlog <tag> [lines]` | Show one user's separated access log |

### Traffic and Quotas

| Command | Description |
|---------|-------------|
| `./deploy.sh traffic [tag]` | Show persisted traffic usage |

### Maintenance

| Command | Description |
|---------|-------------|
| `./deploy.sh update` | Update Docker images |
| `./deploy.sh optimize` | Optimize system (BBR) |

### Telegram Bot

| Command | Description |
|---------|-------------|
| `./deploy.sh bot-install` | Install/start Telegram management bot |
| `./deploy.sh bot-uninstall` | Remove Telegram bot service |

Docker images are pinned by default and can be changed in `.env` after you test
the new versions:

- `XRAY_IMAGE`
- `NGINX_IMAGE`
- `CERTBOT_IMAGE`

Runtime users are stored in `data/users.json`. `xray/config.json` is generated
from `xray/config.json.template` plus the enabled, non-expired users in this
database. User mutations create timestamped backups under `backups/` and will
roll back if rendering or restarting xray fails.

Per-user access logs are split from `logs/xray/access.log` into
`logs/users/<tag>.log` by the `vless-user-log-splitter` systemd service.

Traffic accounting uses Xray StatsService (`127.0.0.1:10085`). The
`vless-traffic-manager.timer` periodically updates `data/users.json` and
`data/traffic.json`; normal users get `TRAFFIC_DEFAULT_LIMIT="20G"` by default.
The admin user is unlimited. Users who reach their quota are automatically
disabled, and traffic is reset monthly on the first day of the month.

## Client Configuration

| Parameter | Value |
|-----------|-------|
| Protocol | VLESS |
| Port | 443 |
| Flow | xtls-rprx-vision |
| Encryption | none |
| Network | tcp |
| Security | tls / reality |
| Fingerprint | chrome |

### Share Link Format

```
vless://UUID@domain:443?encryption=none&security=tls&sni=domain&fp=chrome&type=tcp&flow=xtls-rprx-vision#name
vless://UUID@domain:443?encryption=none&security=reality&sni=REALITY_SERVER_NAME&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp&flow=xtls-rprx-vision#name
```

### Telegram Bot User Management

After the service is installed, configure the bot:

```bash
sudo ./deploy.sh bot-install
```

Bot commands:

```text
/id
/users
/add alice
/add bob 2026-12-31 "temporary user"
/del alice
/enable alice
/disable alice
/expire alice 2026-12-31
/expire alice never
/remark alice main phone
/link alice all
/traffic alice
/userlog alice 100
/userlog alice file
/config alice
/config alice all clash plain
/config alice all shadowrocket plain
/config alice reality shadowrocket tgz
/config alice all clash enc optional-password
/status
/restart
/confirm abc123
/cancel abc123
```

`/config` supports protocol selector, export format, and packaging mode.
Without extra options, Telegram returns an `all clash plain` profile containing
both TLS Vision and REALITY Vision. Clash YAML targets Mihomo / Clash.Meta
compatible clients; classic Clash core does not support VLESS Vision / REALITY.

- Protocol: `tls`, `reality`, `all`.
- Format: `clash` for full Mihomo/Clash.Meta YAML, `shadowrocket` for pure
  `vless://` node links accepted by Shadowrocket.
- Mode: `plain`, `tgz`, `enc`.

- `plain`: send `.yaml` for `clash`, or `.txt` pure nodes for `shadowrocket`.
- `tgz`: send a compressed `.tar.gz` config archive.
- `enc`: send a `.tar.gz.enc` encrypted archive using `openssl enc -aes-256-cbc -pbkdf2`.

Destructive Telegram actions such as `/del`, `/disable`, and `/restart`
require `/confirm <code>`. Bot actions are audited in
`logs/telegram-bot/audit.log`.

Telegram secrets are stored separately in `.env.telegram`. Only Telegram user
IDs listed in `.env.telegram` `TELEGRAM_ADMIN_IDS` can manage users.
If you do not know your user ID yet, leave the admin ID empty during
`bot-install`, send `/id` to the bot, then rerun `sudo ./deploy.sh bot-install`
and set the returned `user_id`.

### Clash Template Options

These `.env` values affect generated Clash files:

| Key | Default | Description |
|-----|---------|-------------|
| `CLASH_PROXY_NAME_PREFIX` | empty | Optional proxy name prefix |
| `CLASH_ALLOW_LAN` | `true` | Generated `allow-lan` value |
| `CLASH_MODE` | `rule` | Generated Clash mode |
| `CLASH_RULESET` | `loyalsoldier` | Reserved ruleset selector |

### REALITY Options

These `.env` values are generated during install. `REALITY_SERVER_NAME` must be
different from your own `DOMAIN`, because Nginx uses SNI to distinguish TLS
Vision and REALITY Vision on the same public `443`.

| Key | Default | Description |
|-----|---------|-------------|
| `REALITY_ENABLED` | `true` | Keep REALITY inbound enabled |
| `REALITY_SERVER_NAME` | `www.microsoft.com` | SNI used by REALITY clients and Nginx stream split |
| `REALITY_DEST` | `www.microsoft.com:443` | REALITY handshake destination |
| `REALITY_PRIVATE_KEY` | generated | X25519 private key for server |
| `REALITY_PUBLIC_KEY` | generated | Public key sent to clients |
| `REALITY_SHORT_ID` | generated | REALITY short ID |

### Traffic Options

| Key | Default | Description |
|-----|---------|-------------|
| `ADMIN_USER_TAG` | `admin` | Initial admin user tag; admin is unlimited |
| `TRAFFIC_DEFAULT_LIMIT` | `20G` | Default monthly quota for newly added normal users |
| `TRAFFIC_SYNC_INTERVAL` | `2min` | systemd timer interval for traffic sync/enforcement |

### Recommended Clients

| Platform | Client |
|----------|--------|
| Windows | v2rayN, Clash Verge Rev / Mihomo |
| macOS | V2rayU, Clash Verge Rev / Mihomo |
| Linux | v2rayA, Clash Verge Rev / Mihomo |
| Android | v2rayNG, Clash Meta / Mihomo |
| iOS | Shadowrocket, Stash |

## Certificate

Auto-renewal is configured via cron (daily at 3 AM).

Certificate source is tracked in `.env`:

- `CERT_SOURCE="project"`: certbot metadata is stored under `./certs`.
- `CERT_SOURCE="system"`: certificates are synchronized from `/etc/letsencrypt/live/<domain>`.

Manual renewal:
```bash
sudo ./scripts/renew-cert.sh
```

Check expiry:
```bash
openssl x509 -in certs/fullchain.pem -noout -dates
```

## Troubleshooting

### Check logs
```bash
./deploy.sh logs
```

### Run diagnostics
```bash
sudo ./deploy.sh doctor
```

### Check ports
```bash
ss -tlnp | grep ':443'
```

Nginx publishes `443` as the stream entry point. The fallback website listens
on `8080` inside the Docker network only; `8080` is not published on the host.

### Test TLS
```bash
openssl s_client -connect domain:443 -servername domain
```

## License

MIT License
