#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$INSTALL_DIR/.env"
LOG_FILE="/var/log/vless-cert-renew.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Error: Config not found"
    exit 1
fi
source "$CONFIG_FILE"

log "Checking certificate..."

CERT_FILE="$INSTALL_DIR/certs/fullchain.pem"
if [[ -f "$CERT_FILE" ]]; then
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
    CURRENT_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

    log "Certificate expires in ${DAYS_LEFT} days"

    if [[ $DAYS_LEFT -gt 30 ]]; then
        log "Certificate valid, no renewal needed"
        exit 0
    fi
fi

log "Renewing certificate..."

cd "$INSTALL_DIR"

docker compose down 2>/dev/null || docker-compose down

docker run --rm \
    -v "$INSTALL_DIR/certs:/etc/letsencrypt" \
    -p 80:80 \
    certbot/certbot renew --standalone --non-interactive

if [[ -f "$INSTALL_DIR/certs/live/$DOMAIN/fullchain.pem" ]]; then
    cp "$INSTALL_DIR/certs/live/$DOMAIN/fullchain.pem" "$INSTALL_DIR/certs/fullchain.pem"
    cp "$INSTALL_DIR/certs/live/$DOMAIN/privkey.pem" "$INSTALL_DIR/certs/privkey.pem"
    chmod 644 "$INSTALL_DIR/certs/fullchain.pem" "$INSTALL_DIR/certs/privkey.pem"
    log "Certificate renewed"
else
    log "Error: Renewal failed, certificate files not found"
fi

docker compose up -d 2>/dev/null || docker-compose up -d

log "Service restarted"
