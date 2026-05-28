#!/bin/bash
# =============================================================================
# TWDxWordPressServerSecurity — Server Hardening
# https://github.com/TheWebDexterTech/TWDxWordPressServerSecurity
#
# Hardens the host OS: SSH daemon (drop-in config), kernel/network sysctls,
# and UFW firewall. Run after install.sh — safe to re-run (idempotent).
#
# Usage:
#   sudo bash scripts/harden.sh [--dry-run] [--help]
#
# Headless:
#   sudo SSH_PORT=22 ENABLE_UFW=true bash scripts/harden.sh
#
# Tested: Ubuntu 24.04 LTS — aarch64 + x86_64
# License: MIT
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ ok ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[fail]${NC}  $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}▸ $*${NC}"; }
dry_run() { echo -e "${YELLOW}[dry-run]${NC}  Would: $*"; }

show_help() {
    cat <<'EOF'
TWDxWordPressServerSecurity — Server Hardening

Usage:
  sudo bash scripts/harden.sh [--dry-run|--check] [--help|-h]

Environment variables:
  SSH_PORT    SSH port to allow through UFW         [22]
  ENABLE_UFW  Install and enable UFW firewall       [true]
  OPEN_HTTP   Allow inbound port 80                 [true]
  OPEN_HTTPS  Allow inbound port 443                [true]
  DRY_RUN     Preview without applying              [false]

Examples:
  sudo bash scripts/harden.sh
  sudo bash scripts/harden.sh --dry-run
  sudo SSH_PORT=2222 OPEN_HTTP=false bash scripts/harden.sh
EOF
}

# ── Branding ──────────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}"
echo "  ================================================================="
echo "        TWDxWordPressServerSecurity — Server Hardening             "
echo "                                                                   "
echo "               Developed by: TheWebDexter.com                      "
echo "  ================================================================="
echo -e "${NC}"

# ── Arg parsing ───────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
for arg in "$@"; do
    case "$arg" in
        --help|-h)         show_help; exit 0 ;;
        --dry-run|--check) DRY_RUN="true" ;;
        *)                 warn "Unknown argument: $arg (use --help)" ;;
    esac
done
[[ "$DRY_RUN" == "true" ]] && warn "Dry-run mode: no changes will be made."

# ── Default Configuration ─────────────────────────────────────────────────────
SSH_PORT="${SSH_PORT:-22}"
ENABLE_UFW="${ENABLE_UFW:-true}"
OPEN_HTTP="${OPEN_HTTP:-true}"
OPEN_HTTPS="${OPEN_HTTPS:-true}"

# ── Input Validation ──────────────────────────────────────────────────────────
validate_port() {
    local val="$1" name="$2"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < 1 || val > 65535 )); then
        error "${name} must be a port number between 1 and 65535 (got: '${val}')"
    fi
}

validate_bool() {
    local val="$1" name="$2"
    if [[ "$val" != "true" && "$val" != "false" ]]; then
        error "${name} must be 'true' or 'false' (got: '${val}')"
    fi
}

step "Validating configuration"
validate_port "$SSH_PORT"   "SSH_PORT"
validate_bool "$ENABLE_UFW" "ENABLE_UFW"
validate_bool "$OPEN_HTTP"  "OPEN_HTTP"
validate_bool "$OPEN_HTTPS" "OPEN_HTTPS"
success "All inputs validated"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight Checks"
[[ $EUID -ne 0 ]] && error "Please run as root (or use sudo)."

if [[ "$DRY_RUN" != "true" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    command -v lsb_release &>/dev/null || apt-get install -y -q lsb-release
fi

OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
VER=$(lsb_release -sr 2>/dev/null || echo "0")
[[ "$OS" != "Ubuntu" ]] && warn "Tested on Ubuntu — proceeding anyway on ${OS} ${VER}"

# ── 1. SSH Daemon Hardening (drop-in /etc/ssh/sshd_config.d) ─────────────────
step "SSH Daemon Hardening"

SSH_DROPIN="/etc/ssh/sshd_config.d/99-twdxwpss-hardening.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write ${SSH_DROPIN} (CIS-aligned)"
    dry_run "validate config with: sshd -t"
    dry_run "systemctl reload ssh"
else
    # Safety: warn if no non-root user has an authorized_keys file (lockout risk).
    KEY_FOUND=false
    while IFS= read -r homedir; do
        if [[ -f "${homedir}/.ssh/authorized_keys" ]]; then
            KEY_FOUND=true
            break
        fi
    done < <(awk -F: '($3 >= 1000) {print $6}' /etc/passwd)

    if [[ "$KEY_FOUND" != "true" ]]; then
        warn "No non-root user with an authorized_keys file was found."
        warn "Disabling password authentication without SSH keys in place will lock you out."
        if [ -c /dev/tty ]; then
            echo -e "  Continue anyway? [y/N]: \c"
            read -r lockout_ans < /dev/tty
            [[ "$lockout_ans" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
        else
            warn "No TTY — continuing. Verify key-based SSH access is working before proceeding."
        fi
    fi

    # Modern sshd_config.d drop-in: first match wins, applied before main config.
    # This avoids mutating /etc/ssh/sshd_config and survives apt upgrades.
    mkdir -p /etc/ssh/sshd_config.d
    cat > "$SSH_DROPIN" <<'EOF'
# TWDxWordPressServerSecurity — SSH hardening (CIS-aligned)
# Loaded by sshd via Include /etc/ssh/sshd_config.d/*.conf
# First match wins; this file is processed before the main sshd_config.

# Authentication
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
HostbasedAuthentication no
IgnoreRhosts yes
PubkeyAuthentication yes
PermitUserEnvironment no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30

# Session hygiene
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PrintLastLog yes
LogLevel VERBOSE

# Cryptography (Mozilla "modern" profile — OpenSSH 8.5+)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256-cert-v01@openssh.com
EOF
    chmod 644 "$SSH_DROPIN"

    if ! sshd -t 2>/tmp/sshd-test-err; then
        warn "sshd config validation failed — removing drop-in"
        cat /tmp/sshd-test-err >&2
        rm -f "$SSH_DROPIN" /tmp/sshd-test-err
        error "SSH hardening aborted. No changes left behind."
    fi
    rm -f /tmp/sshd-test-err

    systemctl reload ssh
    success "SSH daemon hardened via drop-in (${SSH_DROPIN})"
fi

# ── 2. Kernel & Network Hardening ─────────────────────────────────────────────
step "Kernel & Network Hardening (sysctl)"

SYSCTL_CONF="/etc/sysctl.d/99-twdxwpss-hardening.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write ${SYSCTL_CONF}"
    dry_run "apply with: sysctl --system"
else
    cat > "$SYSCTL_CONF" <<'EOF'
# TWDxWordPressServerSecurity — kernel & network hardening
# https://github.com/TheWebDexterTech/TWDxWordPressServerSecurity
# CIS Ubuntu 24.04 Benchmark §3 (Network) and §1.5 (Kernel) aligned.

# ── IPv4 network hardening ──────────────────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ── IPv6 network hardening (does NOT disable IPv6) ──────────────────────────
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ── Kernel hardening ────────────────────────────────────────────────────────
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
kernel.sysrq = 0
kernel.kexec_load_disabled = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# ── Filesystem hardening (block symlink/hardlink/FIFO TOCTOU attacks) ───────
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
    chmod 644 "$SYSCTL_CONF"
    sysctl --system > /dev/null
    success "Kernel & network hardening applied (${SYSCTL_CONF})"
fi

# ── 3. UFW Firewall ───────────────────────────────────────────────────────────
if [[ "$ENABLE_UFW" == "true" ]]; then
    step "UFW Firewall Setup"

    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "apt-get install ufw"
        dry_run "ufw allow ${SSH_PORT}/tcp"
        [[ "$OPEN_HTTP"  == "true" ]] && dry_run "ufw allow 80/tcp"
        [[ "$OPEN_HTTPS" == "true" ]] && dry_run "ufw allow 443/tcp"
        dry_run "ufw default deny incoming"
        dry_run "ufw default allow outgoing"
        dry_run "ufw logging low"
        dry_run "ufw --force enable"
    else
        apt-get install -y -q ufw

        # Force IPv6 on (UFW default on 24.04, but make it explicit & idempotent).
        sed -i 's|^IPV6=.*|IPV6=yes|' /etc/default/ufw

        ufw allow "${SSH_PORT}/tcp"
        [[ "$OPEN_HTTP"  == "true" ]] && ufw allow 80/tcp
        [[ "$OPEN_HTTPS" == "true" ]] && ufw allow 443/tcp

        ufw default deny incoming
        ufw default allow outgoing
        ufw logging low
        ufw --force enable

        success "UFW enabled (SSH:${SSH_PORT} HTTP:${OPEN_HTTP} HTTPS:${OPEN_HTTPS})"
        warn "──────────────────────────────────────────────────────────"
        warn "NEXT STEP (Cloudflare Tunnel users only):"
        warn "Once your tunnel is confirmed working, close the SSH port:"
        warn "  sudo ufw delete allow ${SSH_PORT}/tcp && sudo ufw reload"
        warn "Also remove the SSH ingress rule from your cloud provider"
        warn "VCN / Security Group settings (e.g. Oracle Cloud Dashboard)."
        warn "──────────────────────────────────────────────────────────"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}  Dry-run complete — no changes were made.${NC}"
else
    echo -e "${GREEN}  Server hardening complete on $(hostname)${NC}"
fi
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
echo

printf "  %-28s %-14s\n" "Component" "Status"
echo  "  ──────────────────────────────────────────"

if [[ "$DRY_RUN" == "true" ]]; then
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "SSH hardening"        "dry-run"
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "Kernel network stack" "dry-run"
    [[ "$ENABLE_UFW" == "true" ]] && \
        printf "  %-28s ${YELLOW}%-14s${NC}\n" "UFW firewall" "dry-run"
else
    printf "  %-28s ${GREEN}%-14s${NC}\n" "SSH hardening"        "✓ active"
    printf "  %-28s ${GREEN}%-14s${NC}\n" "Kernel network stack" "✓ active"
    [[ "$ENABLE_UFW" == "true" ]] && \
        printf "  %-28s ${GREEN}%-14s${NC}\n" "UFW firewall" "✓ active"
fi
echo
echo -e "${CYAN}  Thank you for using automation by TheWebDexter.com${NC}"
echo
