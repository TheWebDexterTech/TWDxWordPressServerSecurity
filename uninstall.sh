#!/bin/bash
# =============================================================================
# TWDxWordPressServerSecurity — Uninstaller
# https://github.com/thewebdexter/TWDxWordPressServerSecurity
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "\033[0;34m[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ ok ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[fail]${NC}  $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Please run as root (or use sudo)."

echo -e "${CYAN}${BOLD}"
echo "  ================================================================="
echo "       TWDxWordPressServerSecurity — Uninstaller                   "
echo "  ================================================================="
echo -e "${NC}"

warn "This will remove all TWDxWordPressServerSecurity components."
echo -e "  Continue? [y/N]: \c"
read -r confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# Cron jobs
if [[ -f /etc/cron.d/twdxwpss ]]; then
    rm -f /etc/cron.d/twdxwpss
    success "Removed /etc/cron.d/twdxwpss"
fi

# Systemd timer and service
systemctl disable --now auto-reboot.timer 2>/dev/null || true
rm -f /etc/systemd/system/auto-reboot.{service,timer}
systemctl daemon-reload
success "Removed auto-reboot timer"

# Scripts
for f in /usr/local/bin/wp-auto-update.sh /usr/local/bin/vm-system-cleanup.sh; do
    [[ -f "$f" ]] && rm -f "$f" && success "Removed $f"
done

# WP-CLI (optional — user may want to keep it)
echo -e "  Remove WP-CLI (/usr/local/bin/wp)? [y/N]: \c"
read -r rm_wp
if [[ "$rm_wp" =~ ^[Yy]$ ]]; then
    rm -f /usr/local/bin/wp
    success "Removed WP-CLI"
fi

# Log rotation config
rm -f /etc/logrotate.d/twdxwpss /etc/logrotate.d/vm-auto-security
success "Removed logrotate config"

# Disable unattended-upgrades and fail2ban (optional)
echo -e "  Disable unattended-upgrades and fail2ban? [y/N]: \c"
read -r rm_pkg
if [[ "$rm_pkg" =~ ^[Yy]$ ]]; then
    systemctl disable --now unattended-upgrades fail2ban 2>/dev/null || true
    success "Disabled unattended-upgrades and fail2ban"
fi

# Kernel network hardening (harden.sh)
if [[ -f /etc/sysctl.d/99-twdxwpss-hardening.conf ]]; then
    rm -f /etc/sysctl.d/99-twdxwpss-hardening.conf
    sysctl --system > /dev/null
    success "Removed kernel hardening config and reloaded sysctl"
fi

# UFW (harden.sh) — optional, user may have other rules
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    echo -e "  Disable UFW firewall? [y/N]: \c"
    read -r rm_ufw
    if [[ "$rm_ufw" =~ ^[Yy]$ ]]; then
        ufw --force disable 2>/dev/null || true
        success "UFW disabled"
    fi
fi

# SSH config backup (harden.sh) — optional restore
if [[ -f /etc/ssh/sshd_config.bak ]]; then
    echo -e "  Restore original SSH config from backup? [y/N]: \c"
    read -r rm_ssh
    if [[ "$rm_ssh" =~ ^[Yy]$ ]]; then
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        systemctl restart ssh
        success "SSH config restored and daemon restarted"
    fi
fi

echo
echo -e "${GREEN}${BOLD}  TWDxWordPressServerSecurity has been removed.${NC}"
echo -e "  Logs remain at /var/log/wp-auto-update.log and /var/log/vm-system-cleanup.log"
echo -e "  Remove them manually if no longer needed."
echo
