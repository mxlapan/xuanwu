#!/bin/bash

set -Ee

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.env"
TELEGRAM_CONFIG_FILE="$SCRIPT_DIR/.env.telegram"
COMMON_LIB="$SCRIPT_DIR/scripts/lib/common.sh"
if [[ -f "$COMMON_LIB" ]]; then
    if grep -q $'\r' "$COMMON_LIB" 2>/dev/null; then
        sed -i 's/\r$//' "$COMMON_LIB" 2>/dev/null || true
    fi
    # shellcheck source=scripts/lib/common.sh
    source "$COMMON_LIB"
fi

DEFAULT_XRAY_IMAGE="ghcr.io/xtls/xray-core:26.4.17"
DEFAULT_NGINX_IMAGE="nginx:1.29.8-alpine"
DEFAULT_CERTBOT_IMAGE="certbot/certbot:v5.5.0"
DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-v2.40.2}"
XRAY_INBOUND_TAG="vless-xtls-vision"
TELEGRAM_SERVICE_NAME="vless-telegram-bot"
LOGSPLIT_SERVICE_NAME="vless-user-log-splitter"
TRAFFIC_SERVICE_NAME="vless-traffic-manager"
TRAFFIC_TIMER_NAME="vless-traffic-manager.timer"
TRAFFIC_MONTHLY_SERVICE_NAME="vless-traffic-monthly-reset"
TRAFFIC_MONTHLY_TIMER_NAME="vless-traffic-monthly-reset.timer"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

on_error() {
    local code=$?
    local line="${BASH_LINENO[0]:-?}"
    print_error "Command failed at line ${line} (exit ${code}): ${BASH_COMMAND}"
}
trap on_error ERR

docker_compose() {
    if docker compose version &> /dev/null; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

validate_uuid() {
    local uuid="$1"
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

validate_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

validate_user_tag() {
    local tag="$1"
    [[ "$tag" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

validate_telegram_token() {
    local token="$1"
    [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]
}

validate_telegram_admin_ids() {
    local ids="$1"
    [[ "$ids" =~ ^[0-9]+([,[:space:]]*[0-9]+)*$ ]]
}

validate_telegram_config_mode() {
    local mode="$1"
    [[ "$mode" =~ ^(plain|tgz|enc)$ ]]
}

validate_host_port() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]]
}

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║       VLESS + XTLS-Vision + Nginx Docker Installer       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Please run as root"
        exit 1
    fi
}

check_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        OS="unknown"
    fi
    print_info "Detected OS: $OS"
}

install_docker() {
    if command -v docker &> /dev/null; then
        print_success "Docker installed"
        return
    fi
    print_info "Installing Docker..."

    case "$OS" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y ca-certificates curl gnupg lsb-release
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$OS/gpg" -o /tmp/docker.gpg
            rm -f /etc/apt/keyrings/docker.gpg
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            local codename
            codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
            if [[ -z "$codename" ]] && command -v lsb_release &> /dev/null; then
                codename="$(lsb_release -cs)"
            fi
            if [[ -z "$codename" ]]; then
                print_error "Cannot detect distro codename for Docker apt repository"
                exit 1
            fi
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $codename stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -qq
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        centos|rhel|fedora)
            yum install -y yum-utils ca-certificates curl gnupg2
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        *)
            print_warning "Unsupported OS for package-managed Docker install: $OS"
            read -p "Use Docker convenience script from get.docker.com? [y/N]: " INSTALL_DOCKER
            if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
                curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
                sh /tmp/get-docker.sh
            else
                print_error "Docker installation cancelled"
                exit 1
            fi
            ;;
    esac

    systemctl start docker
    systemctl enable docker
    print_success "Docker installed"
}

install_docker_compose() {
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        print_success "Docker Compose installed"
        return
    fi
    print_info "Installing Docker Compose..."

    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        apt-get install -y docker-compose-plugin && {
            print_success "Docker Compose plugin installed"
            return
        }
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
        yum install -y docker-compose-plugin && {
            print_success "Docker Compose plugin installed"
            return
        }
    fi

    local os arch asset tmpdir
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    asset="docker-compose-${os}-${arch}"
    tmpdir="$(mktemp -d)"

    curl -fsSL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/${asset}" -o "$tmpdir/$asset"
    curl -fsSL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/${asset}.sha256" -o "$tmpdir/${asset}.sha256"
    (cd "$tmpdir" && sha256sum -c "${asset}.sha256")
    install -m 0755 "$tmpdir/$asset" /usr/local/bin/docker-compose
    rm -rf "$tmpdir"

    print_success "Docker Compose installed"
}

check_dependencies() {
    print_info "Checking dependencies..."
    if [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
        yum install -y curl openssl bind-utils jq ca-certificates 2>/dev/null || true
    else
        apt-get update -qq
        apt-get install -y curl openssl dnsutils jq ca-certificates gnupg lsb-release 2>/dev/null || true
    fi
    install_docker
    install_docker_compose
    print_success "Dependencies ready"
}

generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

get_public_ip() {
    curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || curl -s4 ipinfo.io/ip 2>/dev/null
}

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
    if [[ -f "$CONFIG_FILE" ]]; then
        local key value
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
            value="$(parse_env_value "$value")"
            case "$key" in
                DOMAIN|UUID|EMAIL|INSTALL_DATE|CERT_SOURCE|XRAY_IMAGE|NGINX_IMAGE|CERTBOT_IMAGE|ADMIN_USER_TAG|CLASH_PROXY_NAME_PREFIX|CLASH_ALLOW_LAN|CLASH_MODE|CLASH_RULESET|TRAFFIC_DEFAULT_LIMIT|TRAFFIC_SYNC_INTERVAL|REALITY_ENABLED|REALITY_SERVER_NAME|REALITY_DEST|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID)
                    printf -v "$key" '%s' "$value"
                    ;;
            esac
        done < "$CONFIG_FILE"
        if [[ -f "$TELEGRAM_CONFIG_FILE" ]]; then
            while IFS='=' read -r key value || [[ -n "$key" ]]; do
                [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
                value="$(parse_env_value "$value")"
                case "$key" in
                    TELEGRAM_BOT_TOKEN|TELEGRAM_ADMIN_IDS|TELEGRAM_CONFIG_MODE)
                        printf -v "$key" '%s' "$value"
                        ;;
                esac
            done < "$TELEGRAM_CONFIG_FILE"
        fi
        XRAY_IMAGE="${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}"
        NGINX_IMAGE="${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}"
        CERTBOT_IMAGE="${CERTBOT_IMAGE:-$DEFAULT_CERTBOT_IMAGE}"
        CERT_SOURCE="${CERT_SOURCE:-project}"
        CLASH_ALLOW_LAN="${CLASH_ALLOW_LAN:-true}"
        CLASH_MODE="${CLASH_MODE:-rule}"
        CLASH_RULESET="${CLASH_RULESET:-loyalsoldier}"
        ADMIN_USER_TAG="${ADMIN_USER_TAG:-admin}"
        TRAFFIC_DEFAULT_LIMIT="${TRAFFIC_DEFAULT_LIMIT:-20G}"
        TRAFFIC_SYNC_INTERVAL="${TRAFFIC_SYNC_INTERVAL:-2min}"
        REALITY_ENABLED="${REALITY_ENABLED:-true}"
        REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
        REALITY_DEST="${REALITY_DEST:-${REALITY_SERVER_NAME}:443}"
        return 0
    fi
    return 1
}

show_install_config_summary() {
    echo ""
    echo -e "${CYAN}=== Existing Configuration ===${NC}"
    echo "  Domain: $DOMAIN"
    echo "  Admin tag: ${ADMIN_USER_TAG:-admin}"
    echo "  Admin UUID: $UUID"
    echo "  Normal user quota: ${TRAFFIC_DEFAULT_LIMIT:-20G}/month"
    echo "  Email:  $EMAIL"
    echo "  Xray:   ${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}"
    echo "  Nginx:  ${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}"
    echo "  REALITY SNI:  ${REALITY_SERVER_NAME:-www.microsoft.com}"
    echo "  REALITY dest: ${REALITY_DEST:-${REALITY_SERVER_NAME:-www.microsoft.com}:443}"
    if [[ -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]]; then
        echo "  REALITY key:  configured"
    else
        echo "  REALITY key:  will be generated"
    fi
    echo ""
}

verify_domain_dns() {
    print_info "Checking DNS..."
    DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        print_warning "Could not detect server public IPv4, skipping strict DNS check"
        return 0
    fi
    if [[ "$DOMAIN_IP" != "$PUBLIC_IP" ]]; then
        print_warning "Domain $DOMAIN resolves to ${DOMAIN_IP:-empty}"
        print_warning "Server IP is $PUBLIC_IP"
        read -p "DNS may be incorrect. Continue? [y/N]: " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "DNS verified"
    fi
}

save_config() {
    XRAY_IMAGE="${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}"
    NGINX_IMAGE="${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}"
    CERTBOT_IMAGE="${CERTBOT_IMAGE:-$DEFAULT_CERTBOT_IMAGE}"
    CERT_SOURCE="${CERT_SOURCE:-project}"
    INSTALL_DATE="${INSTALL_DATE:-$(date '+%Y-%m-%d %H:%M:%S')}"
    ADMIN_USER_TAG="${ADMIN_USER_TAG:-admin}"
    TRAFFIC_DEFAULT_LIMIT="${TRAFFIC_DEFAULT_LIMIT:-20G}"
    TRAFFIC_SYNC_INTERVAL="${TRAFFIC_SYNC_INTERVAL:-2min}"
    REALITY_ENABLED="${REALITY_ENABLED:-true}"
    REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
    REALITY_DEST="${REALITY_DEST:-${REALITY_SERVER_NAME}:443}"

    write_env_line() {
        local key="$1"
        local value="$2"
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//\$/\\\$}"
        value="${value//\`/\\\`}"
        printf '%s="%s"\n' "$key" "$value"
    }

    {
        write_env_line "DOMAIN" "$DOMAIN"
        write_env_line "UUID" "$UUID"
        write_env_line "EMAIL" "$EMAIL"
        write_env_line "CERT_SOURCE" "$CERT_SOURCE"
        write_env_line "XRAY_IMAGE" "$XRAY_IMAGE"
        write_env_line "NGINX_IMAGE" "$NGINX_IMAGE"
        write_env_line "CERTBOT_IMAGE" "$CERTBOT_IMAGE"
        write_env_line "ADMIN_USER_TAG" "$ADMIN_USER_TAG"
        write_env_line "CLASH_PROXY_NAME_PREFIX" "${CLASH_PROXY_NAME_PREFIX:-}"
        write_env_line "CLASH_ALLOW_LAN" "${CLASH_ALLOW_LAN:-true}"
        write_env_line "CLASH_MODE" "${CLASH_MODE:-rule}"
        write_env_line "CLASH_RULESET" "${CLASH_RULESET:-loyalsoldier}"
        write_env_line "TRAFFIC_DEFAULT_LIMIT" "$TRAFFIC_DEFAULT_LIMIT"
        write_env_line "TRAFFIC_SYNC_INTERVAL" "$TRAFFIC_SYNC_INTERVAL"
        write_env_line "REALITY_ENABLED" "$REALITY_ENABLED"
        write_env_line "REALITY_SERVER_NAME" "$REALITY_SERVER_NAME"
        write_env_line "REALITY_DEST" "$REALITY_DEST"
        write_env_line "REALITY_PRIVATE_KEY" "${REALITY_PRIVATE_KEY:-}"
        write_env_line "REALITY_PUBLIC_KEY" "${REALITY_PUBLIC_KEY:-}"
        write_env_line "REALITY_SHORT_ID" "${REALITY_SHORT_ID:-}"
        write_env_line "INSTALL_DATE" "$INSTALL_DATE"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

get_user_input() {
    echo ""
    PUBLIC_IP=$(get_public_ip)
    print_info "Server IP: $PUBLIC_IP"
    echo ""

    if load_config && [[ -n "${DOMAIN:-}" && -n "${UUID:-}" && -n "${EMAIL:-}" ]]; then
        print_info "Found existing .env"
        show_install_config_summary
        read -p "Use existing configuration? [Y/n]: " USE_EXISTING
        if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
            if ! validate_domain "$DOMAIN"; then
                print_error "Existing DOMAIN is invalid: $DOMAIN"
            elif ! validate_uuid "$UUID"; then
                print_error "Existing UUID is invalid: $UUID"
            elif ! validate_email "$EMAIL"; then
                print_error "Existing EMAIL is invalid: $EMAIL"
            elif [[ "${REALITY_SERVER_NAME:-www.microsoft.com}" == "$DOMAIN" ]]; then
                print_error "Existing REALITY serverName must differ from DOMAIN"
            else
                verify_domain_dns
                return 0
            fi
            print_warning "Existing configuration is incomplete or invalid, reconfiguring..."
        else
            print_info "Reconfiguring. Existing values will be used as defaults."
            echo ""
        fi
    fi

    while true; do
        if [[ -n "${DOMAIN:-}" ]]; then
            read -p "Enter your domain (must point to this server) [$DOMAIN]: " DOMAIN_INPUT
            DOMAIN="${DOMAIN_INPUT:-$DOMAIN}"
        else
            read -p "Enter your domain (must point to this server): " DOMAIN
        fi
        if [[ -z "$DOMAIN" ]]; then
            print_error "Domain cannot be empty"
        elif ! validate_domain "$DOMAIN"; then
            print_error "Invalid domain format"
        else
            break
        fi
    done

    verify_domain_dns

    DEFAULT_UUID="${UUID:-$(generate_uuid)}"
    echo ""
    while true; do
        read -p "Enter admin UUID [$DEFAULT_UUID]: " UUID
        UUID=${UUID:-$DEFAULT_UUID}
        if validate_uuid "$UUID"; then
            break
        else
            print_error "Invalid UUID format"
            UUID=""
        fi
    done

    ADMIN_USER_TAG="${ADMIN_USER_TAG:-admin}"

    echo ""
    while true; do
        DEFAULT_EMAIL="${EMAIL:-admin@$DOMAIN}"
        read -p "Enter email (for certificate) [$DEFAULT_EMAIL]: " EMAIL_INPUT
        EMAIL="${EMAIL_INPUT:-$DEFAULT_EMAIL}"
        if validate_email "$EMAIL"; then
            break
        fi
        print_error "Invalid email format"
        EMAIL=""
    done

    REALITY_ENABLED="${REALITY_ENABLED:-true}"
    REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
    echo ""
    while true; do
        read -r -p "REALITY SNI/serverName [${REALITY_SERVER_NAME}]: " REALITY_SERVER_INPUT
        REALITY_SERVER_NAME="${REALITY_SERVER_INPUT:-$REALITY_SERVER_NAME}"
        if ! validate_domain "$REALITY_SERVER_NAME"; then
            print_error "Invalid REALITY serverName"
        elif [[ "$REALITY_SERVER_NAME" == "$DOMAIN" ]]; then
            print_error "REALITY serverName must differ from your own domain for nginx SNI split"
        else
            break
        fi
    done

    REALITY_DEST="${REALITY_DEST:-${REALITY_SERVER_NAME}:443}"
    while true; do
        read -r -p "REALITY dest [${REALITY_DEST}]: " REALITY_DEST_INPUT
        REALITY_DEST="${REALITY_DEST_INPUT:-$REALITY_DEST}"
        if validate_host_port "$REALITY_DEST"; then
            break
        fi
        print_error "Invalid REALITY dest, example: ${REALITY_SERVER_NAME}:443"
    done

    XRAY_IMAGE="${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}"
    NGINX_IMAGE="${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}"
    CERTBOT_IMAGE="${CERTBOT_IMAGE:-$DEFAULT_CERTBOT_IMAGE}"

    echo ""
    echo -e "${CYAN}=== Configuration ===${NC}"
    echo "  Domain: $DOMAIN"
    echo "  Admin tag: $ADMIN_USER_TAG"
    echo "  Admin UUID: $UUID"
    echo "  Normal user quota: ${TRAFFIC_DEFAULT_LIMIT:-20G}/month"
    echo "  Email:  $EMAIL"
    echo "  Xray:   $XRAY_IMAGE"
    echo "  Nginx:  $NGINX_IMAGE"
    echo "  REALITY SNI:  $REALITY_SERVER_NAME"
    echo "  REALITY dest: $REALITY_DEST"
    echo ""

    read -p "Confirm? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        print_warning "Cancelled"
        exit 0
    fi
}

set_cert_permissions() {
    local cert_dir="$1"
    [[ -f "$cert_dir/fullchain.pem" ]] && chmod 644 "$cert_dir/fullchain.pem"
    [[ -f "$cert_dir/privkey.pem" ]] && chmod 600 "$cert_dir/privkey.pem"
}

obtain_certificate() {
    print_info "Obtaining Let's Encrypt certificate..."

    systemctl stop nginx 2>/dev/null || true
    docker stop xray nginx-edge nginx-fallback 2>/dev/null || true

    mkdir -p "$SCRIPT_DIR/certs"
    chmod 700 "$SCRIPT_DIR/certs"
    CERTBOT_IMAGE="${CERTBOT_IMAGE:-$DEFAULT_CERTBOT_IMAGE}"

    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        print_info "Found existing system certificate"
        cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SCRIPT_DIR/certs/fullchain.pem"
        cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SCRIPT_DIR/certs/privkey.pem"
        set_cert_permissions "$SCRIPT_DIR/certs"
        CERT_SOURCE="system"
        print_success "Certificate copied"
        return
    fi

    if [[ -f "$SCRIPT_DIR/certs/live/$DOMAIN/fullchain.pem" ]]; then
        print_info "Found existing certificate"
        cp "$SCRIPT_DIR/certs/live/$DOMAIN/fullchain.pem" "$SCRIPT_DIR/certs/fullchain.pem"
        cp "$SCRIPT_DIR/certs/live/$DOMAIN/privkey.pem" "$SCRIPT_DIR/certs/privkey.pem"
        set_cert_permissions "$SCRIPT_DIR/certs"
        CERT_SOURCE="project"
        print_success "Certificate configured"
        return
    fi

    docker run --rm \
        -v "$SCRIPT_DIR/certs:/etc/letsencrypt" \
        -p 80:80 \
        "$CERTBOT_IMAGE" certonly \
        --standalone \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --keep-until-expiring \
        --email "$EMAIL" \
        -d "$DOMAIN"

    if [[ -f "$SCRIPT_DIR/certs/live/$DOMAIN/fullchain.pem" ]]; then
        cp "$SCRIPT_DIR/certs/live/$DOMAIN/fullchain.pem" "$SCRIPT_DIR/certs/fullchain.pem"
        cp "$SCRIPT_DIR/certs/live/$DOMAIN/privkey.pem" "$SCRIPT_DIR/certs/privkey.pem"
        set_cert_permissions "$SCRIPT_DIR/certs"
        CERT_SOURCE="project"
        print_success "Certificate obtained"
    else
        print_error "Failed to obtain certificate"
        exit 1
    fi
}

generate_configs() {
    print_info "Generating configs..."

    if declare -F vxd_ensure_user_db >/dev/null; then
        vxd_ensure_reality_config
        vxd_ensure_user_db
        vxd_render_xray_config
    else
        sed -e "s/{{UUID}}/$UUID/g" -e "s/{{DOMAIN}}/$DOMAIN/g" \
            -e "s/{{REALITY_SERVER_NAME}}/${REALITY_SERVER_NAME:-www.microsoft.com}/g" \
            -e "s/{{REALITY_DEST}}/${REALITY_DEST:-${REALITY_SERVER_NAME:-www.microsoft.com}:443}/g" \
            -e "s/{{REALITY_PRIVATE_KEY}}/${REALITY_PRIVATE_KEY:-}/g" \
            -e "s/{{REALITY_SHORT_ID}}/${REALITY_SHORT_ID:-}/g" \
            "$SCRIPT_DIR/xray/config.json.template" > "$SCRIPT_DIR/xray/config.json"
    fi

    sed -e "s/{{DOMAIN}}/$DOMAIN/g" \
        -e "s/{{REALITY_SERVER_NAME}}/${REALITY_SERVER_NAME:-www.microsoft.com}/g" \
        "$SCRIPT_DIR/nginx/nginx.conf.template" > "$SCRIPT_DIR/nginx/nginx.conf"
    print_success "Configs generated"
}

optimize_system() {
    print_info "Optimizing system..."
    if [[ -x "$SCRIPT_DIR/scripts/optimize.sh" ]]; then
        "$SCRIPT_DIR/scripts/optimize.sh"
    fi
}

maybe_optimize_system() {
    echo ""
    print_warning "System optimization changes global sysctl and file-limit settings."
    read -p "Apply optional network optimization now? [y/N]: " APPLY_OPTIMIZE
    if [[ "$APPLY_OPTIMIZE" =~ ^[Yy]$ ]]; then
        optimize_system
    else
        print_info "Skipped system optimization. You can run '$0 optimize' later."
    fi
}

start_services() {
    print_info "Starting services..."
    cd "$SCRIPT_DIR"

    mkdir -p "$SCRIPT_DIR/logs/xray"
    chmod 755 "$SCRIPT_DIR/logs/xray"

    docker_compose down 2>/dev/null || true
    docker_compose up -d
    sleep 3
    if docker_compose ps | grep -q "Up\|running"; then
        print_success "Services started"
        health_check
    else
        print_error "Failed to start services"
        docker_compose logs
        exit 1
    fi
}

health_check() {
    print_info "Running health check..."
    local retries=3
    local wait_time=5

    for ((i=1; i<=retries; i++)); do
        if ! docker_compose ps | grep -q "Up\|running"; then
            print_warning "Containers not running, retrying ($i/$retries)..."
            sleep $wait_time
            continue
        fi

        if ss -tlnp 2>/dev/null | grep -q ":443 " || netstat -tlnp 2>/dev/null | grep -q ":443 "; then
            print_success "Port 443 listening"
        else
            print_warning "Port 443 not listening, retrying ($i/$retries)..."
            sleep $wait_time
            continue
        fi

        if load_config; then
            if timeout 5 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
                print_success "TLS verified"
            else
                print_warning "TLS verification failed (DNS may not be propagated)"
            fi
        fi

        print_success "Health check passed"
        return 0
    done

    print_warning "Health check incomplete"
    return 1
}

configure_firewall() {
    print_info "Configuring firewall..."
    if command -v ufw &> /dev/null; then
        ufw allow 443/tcp 2>/dev/null || true
        ufw allow 80/tcp 2>/dev/null || true
    fi
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=80/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
    print_success "Firewall configured"
}

setup_cert_renewal() {
    print_info "Setting up auto-renewal..."
    chmod +x "$SCRIPT_DIR/scripts/renew-cert.sh"
    cat > /etc/cron.d/vless-renew-cert << EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root $SCRIPT_DIR/scripts/renew-cert.sh >/var/log/vless-cert-renew.cron.log 2>&1
EOF
    chmod 644 /etc/cron.d/vless-renew-cert
    print_success "Auto-renewal configured"
}

ensure_bot_dependencies() {
    local missing=()
    local tool
    for tool in curl jq openssl tar gzip; do
        if ! command -v "$tool" &> /dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        print_success "Telegram bot dependencies ready"
        return
    fi

    print_info "Installing Telegram bot dependencies: ${missing[*]}"
    if [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
        yum install -y curl jq openssl tar gzip
    else
        apt-get update -qq
        apt-get install -y curl jq openssl tar gzip
    fi

    missing=()
    for tool in curl jq openssl tar gzip; do
        if ! command -v "$tool" &> /dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies after install: ${missing[*]}"
        exit 1
    fi

    print_success "Telegram bot dependencies ready"
}

cmd_bot_install() {
    if ! load_config; then
        print_error "Config not found. Please run './deploy.sh install' first."
        exit 1
    fi
    if declare -F vxd_load_telegram_config >/dev/null; then
        vxd_load_telegram_config || true
    fi

    check_system
    ensure_bot_dependencies

    echo ""
    echo -e "${CYAN}=== Telegram Bot Setup ===${NC}"
    echo ""
    echo "Create a bot with @BotFather and paste the bot token below."
    echo "Send /id to the bot first if you need to discover your Telegram user ID."
    echo ""

    while true; do
        read -r -p "Telegram bot token${TELEGRAM_BOT_TOKEN:+ [keep existing]}: " BOT_TOKEN_INPUT
        if [[ -z "$BOT_TOKEN_INPUT" && -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
            break
        fi
        if validate_telegram_token "$BOT_TOKEN_INPUT"; then
            TELEGRAM_BOT_TOKEN="$BOT_TOKEN_INPUT"
            break
        fi
        print_error "Invalid Telegram bot token format"
    done

    while true; do
        read -r -p "Admin Telegram user IDs, comma separated${TELEGRAM_ADMIN_IDS:+ [keep existing]}: " ADMIN_IDS_INPUT
        if [[ -z "$ADMIN_IDS_INPUT" && -n "${TELEGRAM_ADMIN_IDS:-}" ]]; then
            break
        fi
        if [[ -z "$ADMIN_IDS_INPUT" ]]; then
            TELEGRAM_ADMIN_IDS=""
            print_warning "No admin ID configured. The bot will only answer /id until you rerun bot-install."
            break
        fi
        if validate_telegram_admin_ids "$ADMIN_IDS_INPUT"; then
            TELEGRAM_ADMIN_IDS="$ADMIN_IDS_INPUT"
            break
        fi
        print_error "Invalid admin IDs format, example: 123456789,987654321"
    done

    while true; do
        read -r -p "Default config mode [plain/tgz/enc, default: ${TELEGRAM_CONFIG_MODE:-plain}]: " CONFIG_MODE_INPUT
        CONFIG_MODE_INPUT="${CONFIG_MODE_INPUT:-${TELEGRAM_CONFIG_MODE:-plain}}"
        if validate_telegram_config_mode "$CONFIG_MODE_INPUT"; then
            TELEGRAM_CONFIG_MODE="$CONFIG_MODE_INPUT"
            break
        fi
        print_error "Invalid mode. Use plain, tgz or enc."
    done

    if declare -F vxd_save_telegram_config >/dev/null; then
        vxd_save_telegram_config
    else
        cat > "$TELEGRAM_CONFIG_FILE" << EOF
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_ADMIN_IDS="$TELEGRAM_ADMIN_IDS"
TELEGRAM_CONFIG_MODE="$TELEGRAM_CONFIG_MODE"
EOF
        chmod 600 "$TELEGRAM_CONFIG_FILE"
    fi
    chmod +x "$SCRIPT_DIR/scripts/telegram-bot.sh"

    cat > "/etc/systemd/system/${TELEGRAM_SERVICE_NAME}.service" << EOF
[Unit]
Description=VLESS Telegram Management Bot
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/scripts/telegram-bot.sh
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$SCRIPT_DIR /tmp /run /var/run
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$TELEGRAM_SERVICE_NAME"
    systemctl restart "$TELEGRAM_SERVICE_NAME"

    echo ""
    print_success "Telegram bot installed and started"
    echo ""
    echo "  Check:   $0 status"
    echo "  Remove:  $0 bot-uninstall"
    echo ""
}

cmd_bot_uninstall() {
    print_warning "Uninstalling Telegram bot service"
    read -r -p "Confirm? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        exit 0
    fi

    systemctl disable --now "$TELEGRAM_SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${TELEGRAM_SERVICE_NAME}.service"
    systemctl daemon-reload
    print_success "Telegram bot service removed"
}

install_user_log_splitter_service() {
    load_config || true
    chmod +x "$SCRIPT_DIR/scripts/user-log-splitter.sh"
    mkdir -p "$SCRIPT_DIR/logs/xray" "$SCRIPT_DIR/logs/users"
    chmod 755 "$SCRIPT_DIR/logs/xray"
    chmod 700 "$SCRIPT_DIR/logs/users"

    cat > "/etc/systemd/system/${LOGSPLIT_SERVICE_NAME}.service" << EOF
[Unit]
Description=VLESS per-user access log splitter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/scripts/user-log-splitter.sh
Restart=always
RestartSec=3
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$SCRIPT_DIR /tmp /run /var/run
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$LOGSPLIT_SERVICE_NAME"
    print_success "Per-user log splitter installed"
}

install_traffic_manager_service() {
    load_config || true
    TRAFFIC_SYNC_INTERVAL="${TRAFFIC_SYNC_INTERVAL:-2min}"
    chmod +x "$SCRIPT_DIR/scripts/traffic-manager.sh"

    cat > "/etc/systemd/system/${TRAFFIC_SERVICE_NAME}.service" << EOF
[Unit]
Description=VLESS traffic statistics and quota sync
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=/bin/bash $SCRIPT_DIR/scripts/traffic-manager.sh sync
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$SCRIPT_DIR /tmp /run /var/run
RestrictSUIDSGID=true
LockPersonality=true
EOF

    cat > "/etc/systemd/system/${TRAFFIC_TIMER_NAME}" << EOF
[Unit]
Description=Run VLESS traffic statistics and quota sync periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=$TRAFFIC_SYNC_INTERVAL
AccuracySec=30s
Persistent=true
Unit=${TRAFFIC_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

    cat > "/etc/systemd/system/${TRAFFIC_MONTHLY_SERVICE_NAME}.service" << EOF
[Unit]
Description=VLESS monthly traffic quota reset
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=/bin/bash $SCRIPT_DIR/scripts/traffic-manager.sh monthly-reset
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$SCRIPT_DIR /tmp /run /var/run
RestrictSUIDSGID=true
LockPersonality=true
EOF

    cat > "/etc/systemd/system/${TRAFFIC_MONTHLY_TIMER_NAME}" << EOF
[Unit]
Description=Reset VLESS user traffic quota monthly

[Timer]
OnCalendar=*-*-01 00:10:00
AccuracySec=5min
Persistent=true
Unit=${TRAFFIC_MONTHLY_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$TRAFFIC_TIMER_NAME"
    systemctl enable --now "$TRAFFIC_MONTHLY_TIMER_NAME"
    systemctl start "$TRAFFIC_SERVICE_NAME" || print_warning "Initial traffic sync failed; the timer will retry automatically"
    print_success "Traffic statistics timer installed (interval: $TRAFFIC_SYNC_INTERVAL)"
    print_success "Monthly traffic reset timer installed"
}

setup_auxiliary_services() {
    print_info "Setting up per-user logs and traffic quota services..."
    install_user_log_splitter_service
    install_traffic_manager_service
}

remove_auxiliary_services() {
    systemctl disable --now "$LOGSPLIT_SERVICE_NAME" 2>/dev/null || true
    systemctl disable --now "$TRAFFIC_TIMER_NAME" 2>/dev/null || true
    systemctl disable --now "$TRAFFIC_MONTHLY_TIMER_NAME" 2>/dev/null || true
    systemctl stop "$TRAFFIC_SERVICE_NAME" 2>/dev/null || true
    systemctl stop "$TRAFFIC_MONTHLY_SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${LOGSPLIT_SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/${TRAFFIC_SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/${TRAFFIC_TIMER_NAME}"
    rm -f "/etc/systemd/system/${TRAFFIC_MONTHLY_SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/${TRAFFIC_MONTHLY_TIMER_NAME}"
    rm -f /etc/cron.d/vless-renew-cert
    systemctl daemon-reload 2>/dev/null || true
}

show_client_config() {
    load_config
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   Installation Complete                   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}=== Client Configuration ===${NC}"
    echo ""
    echo "  Protocol:    VLESS"
    echo "  Address:     $DOMAIN"
    echo "  Port:        443"
    echo "  Admin tag:   ${ADMIN_USER_TAG:-admin}"
    echo "  Admin UUID:  $UUID"
    echo "  User quota:  ${TRAFFIC_DEFAULT_LIMIT:-20G}/month"
    echo "  Flow:        xtls-rprx-vision"
    echo "  Encryption:  none"
    echo "  Network:     tcp"
    echo "  Security:    tls / reality"
    echo "  TLS SNI:     $DOMAIN"
    echo "  REALITY SNI: ${REALITY_SERVER_NAME:-www.microsoft.com}"
    echo "  REALITY PublicKey: ${REALITY_PUBLIC_KEY:-not generated}"
    echo "  REALITY ShortId:   ${REALITY_SHORT_ID:-not generated}"
    echo "  Fingerprint: chrome"
    echo ""
    echo -e "${CYAN}=== Share Link ===${NC}"
    echo ""
    if declare -F vxd_vless_link >/dev/null; then
        echo "TLS:"
        echo "$(vxd_vless_link "$UUID" "VLESS-${DOMAIN}-TLS" tls)"
        echo ""
        echo "REALITY:"
        echo "$(vxd_vless_link "$UUID" "VLESS-${DOMAIN}-REALITY" reality)"
    else
        echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision#VLESS-${DOMAIN}"
    fi
    echo ""
    echo -e "${CYAN}=== Commands ===${NC}"
    echo ""
    echo "  Status:    $0 status"
    echo "  Config:    $0 config"
    echo "  Logs:      $0 logs"
    echo "  Restart:   $0 restart"
    echo "  Add user:  $0 adduser"
    echo "  Traffic:   $0 traffic"
    echo "  Uninstall: $0 uninstall"
    echo ""
}

cmd_config() {
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi
    echo ""
    echo -e "${CYAN}=== Current Configuration ===${NC}"
    echo ""
    echo "  Domain:       $DOMAIN"
    echo "  UUID:         $UUID"
    echo "  Email:        $EMAIL"
    echo "  Cert source:  ${CERT_SOURCE:-project}"
    echo "  Xray image:   ${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}"
    echo "  Nginx image:  ${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}"
    echo "  Admin tag:    ${ADMIN_USER_TAG:-admin}"
    echo "  REALITY SNI:  ${REALITY_SERVER_NAME:-www.microsoft.com}"
    echo "  REALITY dest: ${REALITY_DEST:-${REALITY_SERVER_NAME:-www.microsoft.com}:443}"
    echo "  REALITY public key: ${REALITY_PUBLIC_KEY:-not generated}"
    echo "  Traffic default limit: ${TRAFFIC_DEFAULT_LIMIT:-20G}"
    echo "  Traffic sync interval: ${TRAFFIC_SYNC_INTERVAL:-2min}"
    echo "  Telegram bot: $([[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && echo configured || echo not configured)"
    echo "  Installed:    $INSTALL_DATE"
    echo ""
    echo -e "${CYAN}=== Share Link ===${NC}"
    echo ""
    if declare -F vxd_vless_link >/dev/null; then
        echo "TLS:"
        echo "$(vxd_vless_link "$UUID" "VLESS-${DOMAIN}-TLS" tls)"
        echo ""
        echo "REALITY:"
        echo "$(vxd_vless_link "$UUID" "VLESS-${DOMAIN}-REALITY" reality)"
    else
        echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision#VLESS-${DOMAIN}"
    fi
    echo ""
}

cmd_adduser() {
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "Please install jq: apt install jq -y"
        exit 1
    fi

    NEW_UUID=$(generate_uuid)
    while true; do
        read -p "Enter user tag [user2]: " USER_TAG
        USER_TAG=${USER_TAG:-"user2"}
        if validate_user_tag "$USER_TAG"; then
            break
        fi
        print_error "Invalid tag. Use 1-64 characters: letters, numbers, dot, underscore or hyphen."
        USER_TAG=""
    done

    read -r -p "Expire date YYYY-MM-DD [never]: " EXPIRE_AT
    if [[ -n "$EXPIRE_AT" ]] && ! [[ "$EXPIRE_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        print_error "Invalid expire date"
        exit 1
    fi
    read -r -p "Remark [optional]: " REMARK

    cd "$SCRIPT_DIR"

    local backup_dir
    backup_dir="$(vxd_backup_state "adduser-$USER_TAG")"
    if ! vxd_user_add "$USER_TAG" "$NEW_UUID" "$EXPIRE_AT" "$REMARK"; then
        print_error "Failed to add user (maybe duplicate tag)"
        exit 1
    fi
    if ! vxd_render_xray_config; then
        vxd_restore_state "$backup_dir" || true
        print_error "Failed to render xray config; configuration was rolled back"
        exit 1
    fi
    if ! vxd_restart_xray_with_rollback "$backup_dir"; then
        print_error "xray restart failed; configuration was rolled back"
        exit 1
    fi
    vxd_audit "cli" "adduser" "$USER_TAG" "ok"

    echo ""
    print_success "User added"
    echo ""
    echo "  UUID: $NEW_UUID"
    echo "  Tag:  $USER_TAG"
    echo ""
    echo "  Share Link:"
    echo "  TLS:"
    echo "  $(vxd_vless_link "$NEW_UUID" "${USER_TAG}-TLS" tls)"
    echo "  REALITY:"
    echo "  $(vxd_vless_link "$NEW_UUID" "${USER_TAG}-REALITY" reality)"
    echo ""
}

cmd_uninstall() {
    echo ""
    print_warning "Uninstalling VLESS service"
    read -p "Confirm? [y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        exit 0
    fi

    print_info "Uninstalling..."

    remove_auxiliary_services

    cd "$SCRIPT_DIR"
    docker_compose down 2>/dev/null || true

    read -p "Remove Docker images? [y/N]: " DEL_IMAGES
    if [[ "$DEL_IMAGES" =~ ^[Yy]$ ]]; then
        load_config || true
        docker rmi "${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}" "${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}" 2>/dev/null || true
    fi

    read -p "Backup config? [Y/n]: " BACKUP
    if [[ ! "$BACKUP" =~ ^[Nn]$ ]]; then
        BACKUP_FILE="/root/vless-backup-$(date +%Y%m%d%H%M%S).tar.gz"
        tar -czf "$BACKUP_FILE" -C "$(dirname "$SCRIPT_DIR")" "$(basename "$SCRIPT_DIR")" 2>/dev/null || true
        print_success "Backed up to $BACKUP_FILE"
    fi

    rm -f "$SCRIPT_DIR/.env"
    rm -f "$SCRIPT_DIR/.env.telegram"
    rm -f "$SCRIPT_DIR/xray/config.json"
    rm -f "$SCRIPT_DIR/nginx/nginx.conf"
    rm -rf "$SCRIPT_DIR/data"
    rm -rf "$SCRIPT_DIR/tmp"
    rm -rf "$SCRIPT_DIR/.telegram-bot.lock"
    rm -rf "$SCRIPT_DIR/certs"

    echo ""
    print_success "Uninstall complete"
    echo ""
}

cmd_backup() {
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi

    BACKUP_DIR="/root/vless-backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/vless-backup-$(date +%Y%m%d%H%M%S).tar.gz"

    print_info "Creating backup..."

    local backup_items=(.env)
    [[ -f "$SCRIPT_DIR/.env.telegram" ]] && backup_items+=(.env.telegram)
    [[ -d "$SCRIPT_DIR/data" ]] && backup_items+=(data/)
    [[ -f "$SCRIPT_DIR/xray/config.json" ]] && backup_items+=(xray/config.json)
    [[ -f "$SCRIPT_DIR/nginx/nginx.conf" ]] && backup_items+=(nginx/nginx.conf)
    [[ -d "$SCRIPT_DIR/certs" ]] && backup_items+=(certs/)

    tar -czf "$BACKUP_FILE" -C "$SCRIPT_DIR" "${backup_items[@]}" 2>/dev/null || true

    if [[ -f "$BACKUP_FILE" ]]; then
        print_success "Backup: $BACKUP_FILE"
        echo ""
        echo "Restore: tar -xzf $BACKUP_FILE -C $SCRIPT_DIR"
        echo ""
    else
        print_error "Backup failed"
        exit 1
    fi
}

cmd_update() {
    load_config || true
    XRAY_IMAGE="${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}"
    NGINX_IMAGE="${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}"

    print_info "Updating Docker images..."
    cd "$SCRIPT_DIR"
    docker pull "$XRAY_IMAGE"
    docker pull "$NGINX_IMAGE"
    print_info "Restarting services..."
    docker_compose down
    docker_compose up -d
    print_info "Cleaning old images..."
    docker image prune -f
    print_success "Update complete"
    echo ""
    docker_compose ps
}

cmd_users() {
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}=== User List ===${NC}"
    echo ""

    if command -v jq &> /dev/null; then
        local count=1
        vxd_ensure_user_db
        while IFS=$'\t' read -r tag id status expire state used limit remark; do
            [[ -n "$tag" ]] || continue
            echo "  [$count] $tag"
            echo "      UUID:   $id"
            echo "      Status: $status / $state"
            echo "      Expire: $expire"
            if [[ "$limit" == "0" ]]; then
                echo "      Traffic: $(vxd_format_bytes "$used") / unlimited"
            else
                echo "      Traffic: $(vxd_format_bytes "$used") / $(vxd_format_bytes "$limit")"
            fi
            [[ -n "$remark" ]] && echo "      Remark: $remark"
            local full_uuid
            full_uuid="$(jq -r --arg tag "$tag" '.users[] | select(.tag == $tag).uuid' "$SCRIPT_DIR/data/users.json")"
            echo "      TLS:    $(vxd_vless_link "$full_uuid" "${tag}-TLS" tls)"
            echo "      REALITY: $(vxd_vless_link "$full_uuid" "${tag}-REALITY" reality)"
            echo ""
            ((count++))
        done < <(vxd_users_table)
        echo -e "${CYAN}Total: $((count-1)) users${NC}"
    else
        print_warning "Please install jq: apt install jq -y"
    fi
    echo ""
}

cmd_deluser() {
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "Please install jq: apt install jq -y"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}=== Current Users ===${NC}"
    echo ""

    local users=()
    local count=1
    vxd_ensure_user_db
    while IFS=$'\t' read -r tag id status expire state used limit remark; do
        [[ -n "$tag" ]] || continue
        users+=("$tag")
        echo "  [$count] $tag ($id, $status/$state, expire: $expire, traffic: $(vxd_format_bytes "$used"))"
        ((count++))
    done < <(vxd_users_table)

    if [[ ${#users[@]} -le 1 ]]; then
        print_error "Must keep at least one user"
        exit 1
    fi

    echo ""
    read -p "Enter user number to delete: " USER_NUM

    if ! [[ "$USER_NUM" =~ ^[0-9]+$ ]] || [[ $USER_NUM -lt 1 ]] || [[ $USER_NUM -gt ${#users[@]} ]]; then
        print_error "Invalid user number"
        exit 1
    fi

    local DEL_TAG="${users[$((USER_NUM-1))]}"

    read -p "Confirm delete user '$DEL_TAG'? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        exit 0
    fi

    cd "$SCRIPT_DIR"
    local backup_dir
    backup_dir="$(vxd_backup_state "deluser-$DEL_TAG")"
    vxd_user_delete "$DEL_TAG"
    if ! vxd_render_xray_config; then
        vxd_restore_state "$backup_dir" || true
        print_error "Failed to render xray config; configuration was rolled back"
        exit 1
    fi
    if ! vxd_restart_xray_with_rollback "$backup_dir"; then
        print_error "xray restart failed; configuration was rolled back"
        exit 1
    fi
    vxd_audit "cli" "deluser" "$DEL_TAG" "ok"

    print_success "User deleted"
}

cmd_set_user_enabled() {
    local ident="${1:-}"
    local enabled="$2"
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi
    if [[ -z "$ident" ]]; then
        print_error "Usage: $0 enableuser|disableuser <tag|uuid>"
        exit 1
    fi
    local user tag backup_dir action
    user="$(vxd_user_find "$ident")"
    if [[ -z "$user" ]]; then
        print_error "User not found: $ident"
        exit 1
    fi
    tag="$(jq -r '.tag' <<< "$user")"
    [[ "$enabled" == "true" ]] && action="enableuser" || action="disableuser"
    backup_dir="$(vxd_backup_state "$action-$tag")"
    vxd_user_set_enabled "$tag" "$enabled"
    if ! vxd_render_xray_config; then
        vxd_restore_state "$backup_dir" || true
        print_error "Failed to render xray config; configuration was rolled back"
        exit 1
    fi
    if ! vxd_restart_xray_with_rollback "$backup_dir"; then
        print_error "xray restart failed; configuration was rolled back"
        exit 1
    fi
    vxd_audit "cli" "$action" "$tag" "ok"
    print_success "User $tag updated"
}

cmd_expire_user() {
    local ident="${1:-}"
    local expire_at="${2:-}"
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi
    if [[ -z "$ident" || -z "$expire_at" ]]; then
        print_error "Usage: $0 expireuser <tag|uuid> <YYYY-MM-DD|never>"
        exit 1
    fi
    [[ "$expire_at" == "never" ]] && expire_at=""
    if [[ -n "$expire_at" ]] && ! [[ "$expire_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        print_error "Invalid date format"
        exit 1
    fi
    local user tag backup_dir
    user="$(vxd_user_find "$ident")"
    if [[ -z "$user" ]]; then
        print_error "User not found: $ident"
        exit 1
    fi
    tag="$(jq -r '.tag' <<< "$user")"
    backup_dir="$(vxd_backup_state "expireuser-$tag")"
    vxd_user_set_expire "$tag" "$expire_at"
    if ! vxd_render_xray_config; then
        vxd_restore_state "$backup_dir" || true
        print_error "Failed to render xray config; configuration was rolled back"
        exit 1
    fi
    if ! vxd_restart_xray_with_rollback "$backup_dir"; then
        print_error "xray restart failed; configuration was rolled back"
        exit 1
    fi
    vxd_audit "cli" "expireuser" "$tag" "ok"
    print_success "User $tag expiry updated"
}

cmd_traffic() {
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi
    bash "$SCRIPT_DIR/scripts/traffic-manager.sh" sync >/dev/null 2>&1 || print_warning "Traffic sync failed; showing last saved data"
    bash "$SCRIPT_DIR/scripts/traffic-manager.sh" status "${1:-}"
}

cmd_userlog() {
    local tag="${1:-}"
    local lines="${2:-80}"
    if [[ -z "$tag" ]]; then
        print_error "Usage: $0 userlog <tag> [lines]"
        exit 1
    fi
    if ! validate_user_tag "$tag"; then
        print_error "Invalid tag"
        exit 1
    fi
    if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        print_error "lines must be a number"
        exit 1
    fi
    (( lines > 500 )) && lines=500
    local file="$SCRIPT_DIR/logs/users/${tag}.log"
    if [[ ! -f "$file" ]]; then
        print_warning "No per-user log file yet: $file"
        exit 1
    fi
    echo ""
    echo -e "${CYAN}=== Last $lines lines for $tag ===${NC}"
    tail -n "$lines" "$file"
}

cmd_status_summary() {
    load_config || true
    echo ""
    echo -e "${CYAN}=== Service Summary ===${NC}"
    echo ""
    echo "  Domain:        ${DOMAIN:-not configured}"
    echo "  Xray image:    ${XRAY_IMAGE:-$DEFAULT_XRAY_IMAGE}"
    echo "  Nginx image:   ${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}"
    echo "  Cert source:   ${CERT_SOURCE:-unknown}"
    echo "  Admin tag:     ${ADMIN_USER_TAG:-admin} (unlimited)"
    echo "  User quota:    ${TRAFFIC_DEFAULT_LIMIT:-20G}/month"
    if declare -F vxd_cert_days_left >/dev/null; then
        echo "  Cert days:     $(vxd_cert_days_left 2>/dev/null || echo missing)"
    fi
    if [[ -f "$SCRIPT_DIR/data/users.json" ]] && command -v jq &> /dev/null; then
        echo "  Users total:   $(jq -r '.users | length' "$SCRIPT_DIR/data/users.json" 2>/dev/null || echo unknown)"
        echo "  Users active:  $(vxd_active_clients_json 2>/dev/null | jq -r 'length' 2>/dev/null || echo unknown)"
        echo "  Traffic updated: $(jq -r '[.users[]?.traffic_updated_at // empty] | map(select(. != \"\")) | max // \"never\"' "$SCRIPT_DIR/data/users.json" 2>/dev/null || echo unknown)"
    fi
    if systemctl list-unit-files "$TELEGRAM_SERVICE_NAME.service" >/dev/null 2>&1; then
        echo "  Telegram bot:  $(systemctl is-active "$TELEGRAM_SERVICE_NAME" 2>/dev/null || echo inactive)"
    else
        echo "  Telegram bot:  not installed"
    fi
    if systemctl list-unit-files "$LOGSPLIT_SERVICE_NAME.service" >/dev/null 2>&1; then
        echo "  User logs:     $(systemctl is-active "$LOGSPLIT_SERVICE_NAME" 2>/dev/null || echo inactive)"
    else
        echo "  User logs:     not installed"
    fi
    if systemctl list-unit-files "$TRAFFIC_TIMER_NAME" >/dev/null 2>&1; then
        echo "  Traffic timer: $(systemctl is-active "$TRAFFIC_TIMER_NAME" 2>/dev/null || echo inactive)"
    else
        echo "  Traffic timer: not installed"
    fi
    if systemctl list-unit-files "$TRAFFIC_MONTHLY_TIMER_NAME" >/dev/null 2>&1; then
        echo "  Monthly reset: $(systemctl is-active "$TRAFFIC_MONTHLY_TIMER_NAME" 2>/dev/null || echo inactive)"
    else
        echo "  Monthly reset: not installed"
    fi
    echo ""
    echo -e "${CYAN}=== Containers ===${NC}"
    cd "$SCRIPT_DIR"
    docker_compose ps
    echo ""
    echo -e "${CYAN}=== Port 443 ===${NC}"
    ss -tlnp 2>/dev/null | grep -E ':443' || netstat -tlnp 2>/dev/null | grep -E ':443' || echo "Cannot get port info"
    echo ""
}

doctor_check() {
    local name="$1"
    shift
    if "$@" >/tmp/vless-doctor.out 2>&1; then
        print_success "$name"
        return 0
    fi
    print_error "$name"
    sed 's/^/    /' /tmp/vless-doctor.out | head -n 5
    return 1
}

cmd_doctor() {
    load_config || true
    if declare -F vxd_ensure_user_db >/dev/null && command -v jq &> /dev/null; then
        vxd_ensure_user_db 2>/dev/null || true
    fi
    echo ""
    echo -e "${CYAN}=== VLESS Doctor ===${NC}"
    echo ""
    local failed=0
    doctor_check "Docker command available" command -v docker || failed=$((failed+1))
    doctor_check "Docker daemon reachable" docker info || failed=$((failed+1))
    doctor_check "Docker Compose config valid" docker_compose config --quiet || failed=$((failed+1))
    doctor_check "Main .env present" test -f "$SCRIPT_DIR/.env" || failed=$((failed+1))
    doctor_check "Xray config present" test -f "$SCRIPT_DIR/xray/config.json" || failed=$((failed+1))
    doctor_check "Xray config JSON valid" jq empty "$SCRIPT_DIR/xray/config.json" || failed=$((failed+1))
    doctor_check "User database valid" jq -e '.users | type == "array"' "$SCRIPT_DIR/data/users.json" || failed=$((failed+1))
    doctor_check "Traffic database path writable" bash -c "mkdir -p '$SCRIPT_DIR/data' && touch '$SCRIPT_DIR/data/.doctor-write' && rm -f '$SCRIPT_DIR/data/.doctor-write'" || failed=$((failed+1))
    doctor_check "Per-user log directory writable" bash -c "mkdir -p '$SCRIPT_DIR/logs/users' && touch '$SCRIPT_DIR/logs/users/.doctor-write' && rm -f '$SCRIPT_DIR/logs/users/.doctor-write'" || failed=$((failed+1))
    doctor_check "Certificate readable on host" test -r "$SCRIPT_DIR/certs/fullchain.pem" || failed=$((failed+1))
    doctor_check "Private key readable on host" test -r "$SCRIPT_DIR/certs/privkey.pem" || failed=$((failed+1))
    doctor_check "Port 443 listening" bash -c "ss -tln 2>/dev/null | grep -q ':443' || netstat -tln 2>/dev/null | grep -q ':443'" || failed=$((failed+1))
    doctor_check "xray container running" bash -c "cd '$SCRIPT_DIR' && docker compose ps xray | grep -E 'Up|running'" || failed=$((failed+1))
    doctor_check "Xray stats API reachable" bash -c "cd '$SCRIPT_DIR' && docker exec xray xray api statsquery --server=127.0.0.1:10085 -pattern user >/dev/null" || failed=$((failed+1))
    doctor_check "Traffic timer active" systemctl is-active --quiet "$TRAFFIC_TIMER_NAME" || failed=$((failed+1))
    doctor_check "Monthly traffic reset timer active" systemctl is-active --quiet "$TRAFFIC_MONTHLY_TIMER_NAME" || failed=$((failed+1))

    if [[ -n "${DOMAIN:-}" ]]; then
        doctor_check "DNS resolves for $DOMAIN" bash -c "dig +short '$DOMAIN' | head -1 | grep -q ." || failed=$((failed+1))
    fi

    echo ""
    if [[ $failed -eq 0 ]]; then
        print_success "Doctor passed"
    else
        print_warning "Doctor found $failed issue(s)"
        exit 1
    fi
}

show_help() {
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Basic:"
    echo "  install     Install service"
    echo "  uninstall   Uninstall service"
    echo "  start       Start service"
    echo "  stop        Stop service"
    echo "  restart     Restart service"
    echo "  status      Show status"
    echo "  doctor      Run diagnostics"
    echo "  logs        Show logs"
    echo ""
    echo "Config:"
    echo "  config      Show configuration"
    echo "  backup      Backup configuration"
    echo ""
    echo "Users:"
    echo "  users       List users"
    echo "  adduser     Add user"
    echo "  deluser     Delete user"
    echo "  enableuser  Enable user"
    echo "  disableuser Disable user"
    echo "  expireuser  Set user expiry"
    echo "  userlog     Show separated access log for one user"
    echo ""
    echo "Traffic:"
    echo "  traffic     Show traffic usage"
    echo ""
    echo "Maintenance:"
    echo "  update      Update Docker images"
    echo "  optimize    Optimize system (BBR)"
    echo ""
    echo "Telegram bot:"
    echo "  bot-install    Install/start Telegram management bot"
    echo "  bot-uninstall  Remove Telegram bot service"
    echo ""
}

main() {
    case "${1:-}" in
        install)
            show_banner
            check_root
            check_system
            check_dependencies
            get_user_input
            obtain_certificate
            save_config
            generate_configs
            save_config
            configure_firewall
            maybe_optimize_system
            start_services
            setup_cert_renewal
            setup_auxiliary_services
            show_client_config
            ;;
        uninstall)
            check_root
            cmd_uninstall
            ;;
        config)
            cmd_config
            ;;
        adduser)
            check_root
            cmd_adduser
            ;;
        optimize)
            check_root
            optimize_system
            ;;
        restart)
            cd "$SCRIPT_DIR"
            docker_compose restart
            print_success "Service restarted"
            ;;
        stop)
            cd "$SCRIPT_DIR"
            docker_compose down
            print_success "Service stopped"
            ;;
        start)
            cd "$SCRIPT_DIR"
            docker_compose up -d
            print_success "Service started"
            ;;
        logs)
            cd "$SCRIPT_DIR"
            docker_compose logs -f
            ;;
        status)
            cmd_status_summary
            ;;
        doctor)
            cmd_doctor
            ;;
        backup)
            check_root
            cmd_backup
            ;;
        update)
            check_root
            cmd_update
            ;;
        users)
            cmd_users
            ;;
        deluser)
            check_root
            cmd_deluser
            ;;
        enableuser)
            check_root
            cmd_set_user_enabled "${2:-}" true
            ;;
        disableuser)
            check_root
            cmd_set_user_enabled "${2:-}" false
            ;;
        expireuser)
            check_root
            cmd_expire_user "${2:-}" "${3:-}"
            ;;
        traffic)
            cmd_traffic "${2:-}"
            ;;
        userlog)
            check_root
            cmd_userlog "${2:-}" "${3:-80}"
            ;;
        bot-install)
            check_root
            cmd_bot_install
            ;;
        bot-uninstall)
            check_root
            cmd_bot_uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            show_help
            ;;
        *)
            print_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
