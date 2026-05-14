#!/bin/bash
# =============================================================================
# wp-automaint
# https://github.com/thewebdexter/VM-auto-security
#
# Hands-off maintenance for headless WordPress servers.
# Handles OS updates, service restarts, kernel reboots, and WP updates.
#
# Usage (One-liner):
#   curl -fsSL https://raw.githubusercontent.com/thewebdexter/VM-auto-security/main/install.sh | sudo bash
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
error()   { echo -e "${RED}[fail]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}▸ $*${NC}"; }

# ── Branding ──────────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}"
echo "  ================================================================="
echo "                  VM-Auto-Security Installer                       "
echo "                                                                   "
echo "               Developed by: TheWebDexter.com                      "
echo "  ================================================================="
echo -e "${NC}"

# ── Default Configuration ─────────────────────────────────────────────────────
WP_PATH="${WP_PATH:-/var/www/html}"
WP_USER="${WP_USER:-www-data}"
REBOOT_TIME="${REBOOT_TIME:-03:30:00}"
LOG_FILE="${LOG_FILE:-/var/log/wp-auto-update.log}"
REPO_URL="https://raw.githubusercontent.com/thewebdexter/VM-auto-security/main"

# ── Interactive Terminal UI ───────────────────────────────────────────────────
step "Configuration Menu"

if [ -c /dev/tty ]; then
    if [ -z "${ENABLE_CLEANUP:-}" ]; then
        echo -e "${BLUE}? Would you like to enable automated system cleanup? (Removes old packages and trims logs)${NC}"
        echo -e "  [y/N]: \c"
        read -r cleanup_ans < /dev/tty
        if [[ "$cleanup_ans" =~ ^[Yy]$ ]]; then
            ENABLE_CLEANUP="true"
        else
            ENABLE_CLEANUP="false"
        fi
    fi

    if [ -z "${CRON_SCHEDULE:-}" ]; then
        echo ""
        echo -e "${BLUE}? How often should WordPress updates (and cleanup) run?${NC}"
        echo "  1) Hourly"
        echo "  2) Daily"
        echo "  3) Weekly (Recommended)"
        echo -e "  Select [1-3, default 3]: \c"
        read -r freq_ans < /dev/tty
        freq_ans=${freq_ans:-3}

        case "$freq_ans" in
            1)
                CRON_SCHEDULE="0 * * * *"
                info "Schedule set to: Hourly"
                ;;
            2)
                echo -e "  ${BLUE}? Hour of the day (0-23, server time) [default 3]: \c${NC}"
                read -r hour_ans < /dev/tty
                hour_ans=${hour_ans:-3}
                CRON_SCHEDULE="0 $hour_ans * * *"
                info "Schedule set to: Daily at ${hour_ans}:00"
                ;;
            3|*)
                echo -e "  ${BLUE}? Day of the week (0=Sun, 1=Mon... 6=Sat) [default 0]: \c${NC}"
                read -r dow_ans < /dev/tty
                dow_ans=${dow_ans:-0}
                echo -e "  ${BLUE}? Hour of the day (0-23, server time) [default 3]: \c${NC}"
                read -r hour_ans < /dev/tty
                hour_ans=${hour_ans:-3}
                CRON_SCHEDULE="0 $hour_ans * * $dow_ans"
                info "Schedule set to: Weekly on day $dow_ans at ${hour_ans}:00"
                ;;
        esac
    fi
fi

ENABLE_CLEANUP="${ENABLE_CLEANUP:-true}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * 0}"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight Checks"

[[ $EUID -ne 0 ]] && error "Please run as root (or use sudo)."

command -v curl &>/dev/null || apt-get install -y -q curl
command -v lsb_release &>/dev/null || apt-get install -y -q lsb-release

OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
VER=$(lsb_release -sr 2>/dev/null || echo "0")

[[ "$OS" != "Ubuntu" ]] && warn "Tested on Ubuntu — proceeding anyway on $OS $VER"
info "WP path: $WP_PATH (owner: $WP_USER)"

if [[ ! -f "$WP_PATH/wp-includes/version.php" ]]; then
    warn "Could not find WordPress at $WP_PATH. Cron job will be installed but may fail."
fi

# ── 1. OS Auto-Updates & Intrusion Prevention ─────────────────────────────────
step "OS security (unattended-upgrades & fail2ban)"
apt-get install -y -q unattended-upgrades update-notifier-common powermgmt-base fail2ban
curl -fsSL "$REPO_URL/configs/50unattended-upgrades" -o /etc/apt/apt.conf.d/50unattended-upgrades
curl -fsSL "$REPO_URL/configs/20auto-upgrades" -o /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades
systemctl enable --now fail2ban
success "unattended-upgrades & fail2ban active"

# ── 2. needrestart ────────────────────────────────────────────────────────────
step "Service auto-restart (needrestart)"
apt-get install -y -q needrestart
curl -fsSL "$REPO_URL/configs/needrestart.conf" -o /etc/needrestart/needrestart.conf
success "needrestart configured"

# ── 3. Kernel-reboot timer ────────────────────────────────────────────────────
step "Auto-reboot timer"
curl -fsSL "$REPO_URL/configs/auto-reboot.service" -o /etc/systemd/system/auto-reboot.service
curl -fsSL "$REPO_URL/configs/auto-reboot.timer.tpl" | \
    sed "s|__REBOOT_TIME__|${REBOOT_TIME}|g" > /etc/systemd/system/auto-reboot.timer
systemctl daemon-reload
systemctl enable --now auto-reboot.timer
success "auto-reboot.timer scheduled nightly at $REBOOT_TIME UTC"

# ── 4. System Cleanup ─────────────────────────────────────────────────────────
if [ "$ENABLE_CLEANUP" = "true" ]; then
    step "System Cleanup Script"
    cat << 'EOF' > /usr/local/bin/vm-system-cleanup.sh
#!/bin/bash
LOG="/var/log/vm-system-cleanup.log"
{
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') System Cleanup ==="
    apt-get autoremove --purge -y
    apt-get autoclean -y
    journalctl --vacuum-time=7d --vacuum-size=200M
    echo "=== Cleanup Complete ==="
} >> "$LOG" 2>&1
EOF
    chmod +x /usr/local/bin/vm-system-cleanup.sh
    success "Generated /usr/local/bin/vm-system-cleanup.sh"
fi

# ── 5. Log Rotation ───────────────────────────────────────────────────────────
step "Log Rotation Configuration"
cat << 'EOF' > /etc/logrotate.d/vm-auto-security
/var/log/wp-auto-update.log
/var/log/vm-system-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
}
EOF
success "Log rotation configured"

# ── 6. WP-CLI ─────────────────────────────────────────────────────────────────
step "WP-CLI"
if command -v wp &>/dev/null; then
    info "WP-CLI already installed — skipping download"
else
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
    success "WP-CLI installed"
fi

# ── 7. WordPress update script + cron ─────────────────────────────────────────
step "Applying Schedules"

curl -fsSL "$REPO_URL/scripts/wp-auto-update.sh.tpl" | \
    sed -e "s|__WP_PATH__|${WP_PATH}|g" \
    -e "s|__WP_USER__|${WP_USER}|g" \
    -e "s|__LOG_FILE__|${LOG_FILE}|g" \
    > /usr/local/bin/wp-auto-update.sh

chmod +x /usr/local/bin/wp-auto-update.sh
touch "$LOG_FILE"

# Safely update crontab without triggering pipefail errors on fresh servers
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null > "$TMP_CRON" || true
sed -i '/wp-auto-update/d' "$TMP_CRON"
sed -i '/vm-system-cleanup/d' "$TMP_CRON"

echo "$CRON_SCHEDULE /usr/local/bin/wp-auto-update.sh" >> "$TMP_CRON"

if [ "$ENABLE_CLEANUP" = "true" ]; then
    CLEANUP_SCHEDULE=$(echo "$CRON_SCHEDULE" | sed 's/^[^ ]*/30/')
    echo "$CLEANUP_SCHEDULE /usr/local/bin/vm-system-cleanup.sh" >> "$TMP_CRON"
fi

crontab "$TMP_CRON"
rm -f "$TMP_CRON"

success "Cron jobs scheduled via CRON_SCHEDULE: $CRON_SCHEDULE"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  wp-automaint installed successfully on $(hostname)${NC}"
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
echo
printf "  %-28s %-14s\n" "Component" "Status"
echo  "  ──────────────────────────────────────────"
printf "  %-28s ${GREEN}%-14s${NC}\n" "OS security updates"  "✓ active"
printf "  %-28s ${GREEN}%-14s${NC}\n" "Intrusion prevention" "✓ active"
printf "  %-28s ${GREEN}%-14s${NC}\n" "Service restarts"     "✓ active"
printf "  %-28s ${GREEN}%-14s${NC}\n" "Kernel reboot"        "✓ active"
printf "  %-28s ${GREEN}%-14s${NC}\n" "Log rotation"         "✓ active"
printf "  %-28s ${GREEN}%-14s${NC}\n" "WP auto-updates"      "✓ active ($CRON_SCHEDULE)"
if [ "$ENABLE_CLEANUP" = "true" ]; then
printf "  %-28s ${GREEN}%-14s${NC}\n" "System cleanup"       "✓ active"
fi
echo
echo -e "${CYAN}  Thank you for using automation by TheWebDexter.com${NC}"
echo
