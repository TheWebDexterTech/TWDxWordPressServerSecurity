#!/bin/bash
# =============================================================================
# TWDxWordPressServerSecurity — Server Hardening
# https://github.com/thewebdexter/TWDxWordPressServerSecurity
#
# Hardens the host OS: SSH daemon, kernel network stack, and UFW firewall.
# Run after install.sh — safe to re-run (idempotent).
#
# Usage:
#   sudo bash scripts/harden.sh [--dry-run]
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

# ── Branding ──────────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}"
echo "  ================================================================="
echo "        TWDxWordPressServerSecurity — Server Hardening             "
echo "                                                                   "
echo "               Developed by: TheWebDexter.com                      "
echo "  ================================================================="
echo -e "${NC}"

# ── Dry-run mode ──────────────────────────────────────────────────────────────
# Pass --dry-run or set DRY_RUN=true to preview changes without applying them.
DRY_RUN="${DRY_RUN:-false}"
for arg in "$@"; do
    [[ "$arg" == "--dry-run" || "$arg" == "--check" ]] && DRY_RUN="true"
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
    command -v lsb_release &>/dev/null || apt-get install -y -q lsb-release
fi

OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
VER=$(lsb_release -sr 2>/dev/null || echo "0")
[[ "$OS" != "Ubuntu" ]] && warn "Tested on Ubuntu — proceeding anyway on ${OS} ${VER}"

# ── Helper: apply or update a directive in sshd_config ───────────────────────
# Replaces any existing line (active or commented) matching the key, or appends.
set_sshd_option() {
    local key="$1" val="$2" file="/etc/ssh/sshd_config"
    if grep -qE "^#?[[:space:]]*${key}" "$file"; then
        sed -i -E "s|^#?[[:space:]]*${key}.*|${key} ${val}|" "$file"
    else
        printf '\n%s %s\n' "$key" "$val" >> "$file"
    fi
}

# ── 1. SSH Daemon Hardening ───────────────────────────────────────────────────
step "SSH Daemon Hardening"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "backup /etc/ssh/sshd_config → /etc/ssh/sshd_config.bak"
    dry_run "set PermitRootLogin no"
    dry_run "set PasswordAuthentication no"
    dry_run "set X11Forwarding no"
    dry_run "validate config with: sshd -t"
    dry_run "systemctl restart ssh"
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

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    info "Backed up /etc/ssh/sshd_config → /etc/ssh/sshd_config.bak"

    set_sshd_option "PermitRootLogin"        "no"
    set_sshd_option "PasswordAuthentication" "no"
    set_sshd_option "X11Forwarding"          "no"

    if ! sshd -t 2>/dev/null; then
        warn "sshd config validation failed — restoring backup"
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        error "SSH hardening aborted. Original config restored."
    fi

    systemctl restart ssh
    success "SSH daemon hardened and restarted"
fi

# ── 2. Kernel Network Hardening ───────────────────────────────────────────────
step "Kernel Network Hardening (sysctl)"

SYSCTL_CONF="/etc/sysctl.d/99-twdxwpss-hardening.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write ${SYSCTL_CONF}"
    dry_run "apply with: sysctl --system"
else
    cat > "$SYSCTL_CONF" << 'EOF'
# TWDxWordPressServerSecurity — kernel network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
EOF
    sysctl --system > /dev/null
    success "Kernel network hardening applied (${SYSCTL_CONF})"
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
        dry_run "ufw --force enable"
    else
        apt-get install -y -q ufw

        ufw allow "${SSH_PORT}/tcp"
        [[ "$OPEN_HTTP"  == "true" ]] && ufw allow 80/tcp
        [[ "$OPEN_HTTPS" == "true" ]] && ufw allow 443/tcp

        ufw default deny incoming
        ufw default allow outgoing
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
