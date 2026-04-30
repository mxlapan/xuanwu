#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$INSTALL_DIR/.env"
LOG_FILE="/var/log/vless-cert-renew.log"
DEFAULT_CERTBOT_IMAGE="certbot/certbot:v5.5.0"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Error: Config not found"
    exit 1
fi

parse_env_value() {
    local value="$1"
    value="${value%$'\r'}"
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value#\"}"
        value="${value%\"}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value#\'}"
        value="${value%\'}"
    fi
    printf '%s' "$value"
}

load_config() {
    local key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        value="$(parse_env_value "$value")"
        case "$key" in
            DOMAIN|EMAIL|CERT_SOURCE|CERTBOT_IMAGE)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    if [[ -z "${DOMAIN:-}" ]]; then
        log "Error: DOMAIN missing in config"
        exit 1
    fi

    CERT_SOURCE="${CERT_SOURCE:-project}"
    CERTBOT_IMAGE="${CERTBOT_IMAGE:-$DEFAULT_CERTBOT_IMAGE}"
}

docker_compose() {
    if docker compose version &> /dev/null; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

set_cert_permissions() {
    chmod 644 "$INSTALL_DIR/certs/fullchain.pem"
    chmod 600 "$INSTALL_DIR/certs/privkey.pem"
}

copy_project_certificate() {
    cp "$INSTALL_DIR/certs/live/$DOMAIN/fullchain.pem" "$INSTALL_DIR/certs/fullchain.pem"
    cp "$INSTALL_DIR/certs/live/$DOMAIN/privkey.pem" "$INSTALL_DIR/certs/privkey.pem"
    set_cert_permissions
}

copy_system_certificate() {
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$INSTALL_DIR/certs/fullchain.pem"
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$INSTALL_DIR/certs/privkey.pem"
    set_cert_permissions
}

SERVICES_STOPPED=0
restart_services_if_needed() {
    if [[ "$SERVICES_STOPPED" -eq 1 ]]; then
        log "Starting service..."
        docker_compose up -d || log "Error: failed to restart service"
    fi
}

load_config

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
mkdir -p "$INSTALL_DIR/certs"
chmod 700 "$INSTALL_DIR/certs"

trap restart_services_if_needed EXIT

if [[ "$CERT_SOURCE" == "system" && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    if command -v certbot &> /dev/null; then
        certbot renew --cert-name "$DOMAIN" --non-interactive || log "Warning: system certbot renew returned non-zero"
    else
        log "Warning: certbot command not found; copying existing system certificate only"
    fi

    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        copy_system_certificate
        log "System certificate synchronized"
    else
        log "Error: system certificate files not found"
        exit 1
    fi
else
    docker_compose down
    SERVICES_STOPPED=1

    docker run --rm \
        -v "$INSTALL_DIR/certs:/etc/letsencrypt" \
        -p 80:80 \
        "$CERTBOT_IMAGE" renew --standalone --non-interactive

    if [[ -f "$INSTALL_DIR/certs/live/$DOMAIN/fullchain.pem" ]]; then
        copy_project_certificate
        log "Project certificate renewed"
    else
        log "Error: Renewal failed, certificate files not found"
        exit 1
    fi
fi

docker_compose up -d
SERVICES_STOPPED=0
trap - EXIT

log "Service restarted"
