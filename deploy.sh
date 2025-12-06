#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.env"

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
    curl -fsSL https://get.docker.com | bash -s docker
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
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose installed"
}

check_dependencies() {
    print_info "Checking dependencies..."
    if [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        yum install -y curl openssl dnsutils 2>/dev/null || true
    else
        apt-get update -qq
        apt-get install -y curl openssl dnsutils 2>/dev/null || true
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

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
DOMAIN="$DOMAIN"
UUID="$UUID"
EMAIL="$EMAIL"
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$CONFIG_FILE"
}

get_user_input() {
    echo ""
    PUBLIC_IP=$(get_public_ip)
    print_info "Server IP: $PUBLIC_IP"
    echo ""

    while true; do
        read -p "Enter your domain (must point to this server): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            print_error "Domain cannot be empty"
        elif ! validate_domain "$DOMAIN"; then
            print_error "Invalid domain format"
        else
            break
        fi
    done

    print_info "Checking DNS..."
    DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | head -1)
    if [[ "$DOMAIN_IP" != "$PUBLIC_IP" ]]; then
        print_warning "Domain $DOMAIN resolves to $DOMAIN_IP"
        print_warning "Server IP is $PUBLIC_IP"
        read -p "DNS may be incorrect. Continue? [y/N]: " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "DNS verified"
    fi

    DEFAULT_UUID=$(generate_uuid)
    echo ""
    while true; do
        read -p "Enter UUID [press Enter to generate]: " UUID
        UUID=${UUID:-$DEFAULT_UUID}
        if validate_uuid "$UUID"; then
            break
        else
            print_error "Invalid UUID format"
            UUID=""
        fi
    done

    echo ""
    read -p "Enter email (for certificate) [optional]: " EMAIL
    EMAIL=${EMAIL:-"admin@$DOMAIN"}

    echo ""
    echo -e "${CYAN}=== Configuration ===${NC}"
    echo "  Domain: $DOMAIN"
    echo "  UUID:   $UUID"
    echo "  Email:  $EMAIL"
    echo ""

    read -p "Confirm? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        print_warning "Cancelled"
        exit 0
    fi
}

obtain_certificate() {
    print_info "Obtaining Let's Encrypt certificate..."

    systemctl stop nginx 2>/dev/null || true
    docker stop xray nginx-fallback 2>/dev/null || true

    mkdir -p "$SCRIPT_DIR/certs"

    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        print_info "Found existing system certificate"
        cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SCRIPT_DIR/certs/fullchain.pem"
        cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SCRIPT_DIR/certs/privkey.pem"
        chmod 644 "$SCRIPT_DIR/certs/"*.pem
        print_success "Certificate copied"
        return
    fi

    if [[ -f "$SCRIPT_DIR/certs/live/$DOMAIN/fullchain.pem" ]]; then
        print_info "Found existing certificate"
        cp "$SCRIPT_DIR/certs/live/$DOMAIN/fullchain.pem" "$SCRIPT_DIR/certs/fullchain.pem"
        cp "$SCRIPT_DIR/certs/live/$DOMAIN/privkey.pem" "$SCRIPT_DIR/certs/privkey.pem"
        chmod 644 "$SCRIPT_DIR/certs/"*.pem
        print_success "Certificate configured"
        return
    fi

    docker run --rm \
        -v "$SCRIPT_DIR/certs:/etc/letsencrypt" \
        -p 80:80 \
        certbot/certbot certonly \
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
        chmod 644 "$SCRIPT_DIR/certs/"*.pem
        print_success "Certificate obtained"
    else
        print_error "Failed to obtain certificate"
        exit 1
    fi
}

generate_configs() {
    print_info "Generating configs..."
    sed -e "s/{{UUID}}/$UUID/g" -e "s/{{DOMAIN}}/$DOMAIN/g" \
        "$SCRIPT_DIR/xray/config.json.template" > "$SCRIPT_DIR/xray/config.json"
    sed -e "s/{{DOMAIN}}/$DOMAIN/g" \
        "$SCRIPT_DIR/nginx/nginx.conf.template" > "$SCRIPT_DIR/nginx/nginx.conf"
    print_success "Configs generated"
}

optimize_system() {
    print_info "Optimizing system..."
    if [[ -x "$SCRIPT_DIR/scripts/optimize.sh" ]]; then
        "$SCRIPT_DIR/scripts/optimize.sh"
    fi
}

start_services() {
    print_info "Starting services..."
    cd "$SCRIPT_DIR"

    mkdir -p "$SCRIPT_DIR/logs/xray"
    chmod 777 "$SCRIPT_DIR/logs/xray"

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
    (crontab -l 2>/dev/null | grep -v "renew-cert.sh"; echo "0 3 * * * $SCRIPT_DIR/scripts/renew-cert.sh") | crontab -
    print_success "Auto-renewal configured"
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
    echo "  UUID:        $UUID"
    echo "  Flow:        xtls-rprx-vision"
    echo "  Encryption:  none"
    echo "  Network:     tcp"
    echo "  Security:    tls"
    echo "  SNI:         $DOMAIN"
    echo "  Fingerprint: chrome"
    echo ""
    echo -e "${CYAN}=== Share Link ===${NC}"
    echo ""
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision#VLESS-${DOMAIN}"
    echo ""
    echo -e "${CYAN}=== Commands ===${NC}"
    echo ""
    echo "  Status:    $0 status"
    echo "  Config:    $0 config"
    echo "  Logs:      $0 logs"
    echo "  Restart:   $0 restart"
    echo "  Add user:  $0 adduser"
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
    echo "  Installed:    $INSTALL_DATE"
    echo ""
    echo -e "${CYAN}=== Share Link ===${NC}"
    echo ""
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision#VLESS-${DOMAIN}"
    echo ""
}

cmd_adduser() {
    if ! load_config; then
        print_error "Config not found"
        exit 1
    fi

    NEW_UUID=$(generate_uuid)
    read -p "Enter user tag [user2]: " USER_TAG
    USER_TAG=${USER_TAG:-"user2"}

    cd "$SCRIPT_DIR"

    if command -v jq &> /dev/null; then
        jq ".inbounds[0].settings.clients += [{\"id\": \"$NEW_UUID\", \"email\": \"$USER_TAG@$DOMAIN\", \"flow\": \"xtls-rprx-vision\"}]" \
            xray/config.json > xray/config.json.tmp
        mv xray/config.json.tmp xray/config.json
        docker_compose restart xray

        echo ""
        print_success "User added"
        echo ""
        echo "  UUID: $NEW_UUID"
        echo "  Tag:  $USER_TAG"
        echo ""
        echo "  Share Link:"
        echo "  vless://${NEW_UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision#${USER_TAG}"
        echo ""
    else
        print_warning "Please install jq or edit xray/config.json manually"
        echo ""
        echo "Add to clients array:"
        echo '{'
        echo "  \"id\": \"$NEW_UUID\","
        echo "  \"email\": \"$USER_TAG@$DOMAIN\","
        echo '  "flow": "xtls-rprx-vision"'
        echo '}'
    fi
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

    cd "$SCRIPT_DIR"
    docker_compose down 2>/dev/null || true

    read -p "Remove Docker images? [y/N]: " DEL_IMAGES
    if [[ "$DEL_IMAGES" =~ ^[Yy]$ ]]; then
        docker rmi ghcr.io/xtls/xray-core nginx:alpine 2>/dev/null || true
    fi

    crontab -l 2>/dev/null | grep -v "renew-cert.sh" | crontab - 2>/dev/null || true

    read -p "Backup config? [Y/n]: " BACKUP
    if [[ ! "$BACKUP" =~ ^[Nn]$ ]]; then
        BACKUP_FILE="/root/vless-backup-$(date +%Y%m%d%H%M%S).tar.gz"
        tar -czf "$BACKUP_FILE" -C "$(dirname "$SCRIPT_DIR")" "$(basename "$SCRIPT_DIR")" 2>/dev/null || true
        print_success "Backed up to $BACKUP_FILE"
    fi

    rm -f "$SCRIPT_DIR/.env"
    rm -f "$SCRIPT_DIR/xray/config.json"
    rm -f "$SCRIPT_DIR/nginx/nginx.conf"
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

    tar -czf "$BACKUP_FILE" -C "$SCRIPT_DIR" .env xray/config.json nginx/nginx.conf certs/ 2>/dev/null || true

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
    print_info "Updating Docker images..."
    cd "$SCRIPT_DIR"
    docker pull ghcr.io/xtls/xray-core:latest
    docker pull nginx:alpine
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

    CONFIG_JSON="$SCRIPT_DIR/xray/config.json"
    if [[ ! -f "$CONFIG_JSON" ]]; then
        print_error "Xray config not found"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}=== User List ===${NC}"
    echo ""

    if command -v jq &> /dev/null; then
        local count=1
        while IFS= read -r line; do
            local id=$(echo "$line" | jq -r '.id')
            local email=$(echo "$line" | jq -r '.email')
            echo "  [$count] $email"
            echo "      UUID: $id"
            echo "      Link: vless://${id}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision#${email%%@*}"
            echo ""
            ((count++))
        done < <(jq -c '.inbounds[0].settings.clients[]' "$CONFIG_JSON")
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

    CONFIG_JSON="$SCRIPT_DIR/xray/config.json"
    if [[ ! -f "$CONFIG_JSON" ]]; then
        print_error "Xray config not found"
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
    while IFS= read -r line; do
        local id=$(echo "$line" | jq -r '.id')
        local email=$(echo "$line" | jq -r '.email')
        users+=("$id")
        echo "  [$count] $email (${id:0:8}...)"
        ((count++))
    done < <(jq -c '.inbounds[0].settings.clients[]' "$CONFIG_JSON")

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

    local DEL_UUID="${users[$((USER_NUM-1))]}"

    read -p "Confirm delete user $USER_NUM? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        exit 0
    fi

    jq "del(.inbounds[0].settings.clients[] | select(.id == \"$DEL_UUID\"))" \
        "$CONFIG_JSON" > "${CONFIG_JSON}.tmp"
    mv "${CONFIG_JSON}.tmp" "$CONFIG_JSON"

    cd "$SCRIPT_DIR"
    docker_compose restart xray

    print_success "User deleted"
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
    echo ""
    echo "Maintenance:"
    echo "  update      Update Docker images"
    echo "  optimize    Optimize system (BBR)"
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
            generate_configs
            save_config
            configure_firewall
            optimize_system
            start_services
            setup_cert_renewal
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
            cd "$SCRIPT_DIR"
            echo ""
            echo -e "${CYAN}=== Container Status ===${NC}"
            docker_compose ps
            echo ""
            echo -e "${CYAN}=== Port Status ===${NC}"
            ss -tlnp 2>/dev/null | grep -E ':443|:8080' || netstat -tlnp 2>/dev/null | grep -E ':443|:8080' || echo "Cannot get port info"
            echo ""
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
