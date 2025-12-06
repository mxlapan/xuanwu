#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "[INFO] $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}=== Network Optimization ===${NC}"
echo ""

KERNEL_VERSION=$(uname -r | cut -d. -f1)
if [[ $KERNEL_VERSION -lt 4 ]]; then
    print_warning "Kernel too old, BBR requires 4.9+"
    exit 1
fi

if [[ ! -f /etc/sysctl.conf.backup ]]; then
    cp /etc/sysctl.conf /etc/sysctl.conf.backup
    print_info "Backed up /etc/sysctl.conf"
fi

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    print_success "BBR enabled"
else
    print_info "Enabling BBR..."
    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
    fi
fi

print_info "Applying optimization..."

cat > /etc/sysctl.d/99-vless-optimize.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
net.ipv4.tcp_mem = 262144 524288 1048576
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
fs.file-max = 1048576
fs.nr_open = 1048576
EOF

sysctl --system 2>/dev/null || sysctl -p /etc/sysctl.d/99-vless-optimize.conf

if ! grep -q "* soft nofile" /etc/security/limits.conf; then
    cat >> /etc/security/limits.conf << 'EOF'

* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
EOF
    print_success "File limits optimized"
fi

echo ""
echo -e "${CYAN}=== Current Status ===${NC}"
echo ""
echo "BBR:          $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')"
echo "Queue:        $(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')"
echo "TCP FastOpen: $(sysctl net.ipv4.tcp_fastopen 2>/dev/null | awk '{print $3}')"
echo "Max Files:    $(sysctl fs.file-max 2>/dev/null | awk '{print $3}')"
echo ""

if lsmod | grep -q tcp_bbr; then
    print_success "BBR module loaded"
else
    print_warning "BBR module not loaded, may need reboot"
fi

echo ""
print_success "Optimization complete"
echo ""
