# VLESS + XTLS-Vision + Nginx Docker

One-click deployment for VLESS proxy with XTLS-Vision and Nginx fallback.

## Structure

```
vless-xtls-docker/
├── deploy.sh                    # Main script
├── docker-compose.yml           # Docker compose
├── xray/
│   └── config.json.template     # Xray config template
├── nginx/
│   ├── nginx.conf.template      # Nginx config template
│   └── html/                    # Fallback website
└── scripts/
    ├── renew-cert.sh            # Certificate renewal
    └── optimize.sh              # System optimization
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

## Commands

### Basic

| Command | Description |
|---------|-------------|
| `./deploy.sh install` | Install service |
| `./deploy.sh uninstall` | Uninstall service |
| `./deploy.sh start` | Start service |
| `./deploy.sh stop` | Stop service |
| `./deploy.sh restart` | Restart service |
| `./deploy.sh status` | Show status |
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

### Maintenance

| Command | Description |
|---------|-------------|
| `./deploy.sh update` | Update Docker images |
| `./deploy.sh optimize` | Optimize system (BBR) |

## Client Configuration

| Parameter | Value |
|-----------|-------|
| Protocol | VLESS |
| Port | 443 |
| Flow | xtls-rprx-vision |
| Encryption | none |
| Network | tcp |
| Security | tls |
| Fingerprint | chrome |

### Share Link Format

```
vless://UUID@domain:443?encryption=none&security=tls&sni=domain&fp=chrome&type=tcp&flow=xtls-rprx-vision#name
```

### Recommended Clients

| Platform | Client |
|----------|--------|
| Windows | v2rayN, Clash Verge |
| macOS | V2rayU, Clash Verge |
| Linux | v2rayA, Clash Verge |
| Android | v2rayNG, Clash Meta |
| iOS | Shadowrocket, Stash |

## Certificate

Auto-renewal is configured via cron (daily at 3 AM).

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

### Check ports
```bash
ss -tlnp | grep -E '443|8080'
```

### Test TLS
```bash
openssl s_client -connect domain:443 -servername domain
```

## License

MIT License
