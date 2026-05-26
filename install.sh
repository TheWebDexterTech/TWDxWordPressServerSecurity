#!/bin/bash
# =============================================================================
# TWDxWordPressServerSecurity
# https://github.com/thewebdexter/TWDxWordPressServerSecurity
#
# Hands-off maintenance for headless WordPress servers.
# Handles OS updates, service restarts, kernel reboots, and WP updates.
#
# Usage (One-liner):
#   curl -fsSL https://raw.githubusercontent.com/thewebdexter/TWDxWordPressServerSecurity/main/install.sh | sudo bash
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
echo "           TWDxWordPressServerSecurity Installer                   "
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
WP_PATH="${WP_PATH:-/var/www/html}"
WP_USER="${WP_USER:-www-data}"
REBOOT_TIME="${REBOOT_TIME:-03:30:00}"
LOG_FILE="${LOG_FILE:-/var/log/wp-auto-update.log}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
REPO_URL="https://raw.githubusercontent.com/thewebdexter/TWDxWordPressServerSecurity/main"

# ── SHA256 digests of every remote file this installer fetches ────────────────
# Update these whenever the corresponding file changes.
declare -A FILE_CHECKSUMS=(
    ["configs/50unattended-upgrades"]="424fee45b14be50847c6ea4655c53846840dd81269b96f1b0520ee7c9903cc0d"
    ["configs/20auto-upgrades"]="d742d9edfb7f0e166ee6b847294f4933db30a1cbacbc45adaca051f1b0ed69bb"
    ["configs/needrestart.conf"]="5dce88e62c9e1bccaca185a56d1a4d7f252b6b3f5feb280e1ea128a48fe6255b"
    ["configs/auto-reboot.service"]="246bd5f5ea830841e865ad0ab057fb2dcc1e270bfe364055a68e40111480fea0"
    ["configs/auto-reboot.timer.tpl"]="e3e8e67961657bc970a9c384c53c586c73974389c374c229a5f0e33f8385625a"
    ["scripts/wp-auto-update.sh.tpl"]="30ee9a77a68a581c95b8b8a82b7e51441624b8e6e06bf07f1298c51f5d1c82b2"
)

# ── Input validation ──────────────────────────────────────────────────────────

validate_cron_schedule() {
    local sched="$1"
    # Exactly 5 cron fields; only digits, *, /, , and - are allowed — no shell metacharacters.
    if ! [[ "$sched" =~ ^([0-9*/,\-]+[[:space:]]+){4}[0-9*/,\-]+$ ]]; then
        error "Invalid CRON_SCHEDULE: '$sched'. Must be 5 standard cron fields (e.g. '0 3 * * 0')."
    fi
}

validate_integer_range() {
    local val="$1" min="$2" max="$3" name="$4"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < min || val > max )); then
        error "$name must be an integer between $min and $max (got: '$val')"
    fi
}

validate_wp_path() {
    local val="$1"
    [[ -z "$val" ]] && error "WP_PATH must not be empty."
    # Absolute path with safe characters only — rejects shell/sed metacharacters.
    if ! [[ "$val" =~ ^/[a-zA-Z0-9/_.\-]*$ ]]; then
        error "WP_PATH '$val' contains unsafe characters. Use only: letters, digits, /, _, ., -"
    fi
}

validate_wp_user() {
    local val="$1"
    [[ -z "$val" ]] && error "WP_USER must not be empty."
    # POSIX username: letters, digits, underscore, hyphen; max 32 chars.
    if ! [[ "$val" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]]; then
        error "WP_USER '$val' is not a valid Unix username."
    fi
}

validate_reboot_time() {
    local val="$1"
    if ! [[ "$val" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]]; then
        error "REBOOT_TIME '$val' must be in HH:MM:SS format (e.g. 03:30:00)."
    fi
}

validate_log_path() {
    local val="$1"
    [[ -z "$val" ]] && error "LOG_FILE must not be empty."
    if ! [[ "$val" =~ ^/[a-zA-Z0-9/_.\-]*$ ]]; then
        error "LOG_FILE '$val' contains unsafe characters."
    fi
}

# ── Verified download helper ───────────────────────────────────────────────────
# Downloads a repo-relative path, verifies its SHA256, then moves it to $dest.
fetch_verified() {
    local path="$1" dest="$2"
    local expected="${FILE_CHECKSUMS[$path]:-}"
    [[ -z "$expected" ]] && error "No checksum registered for '$path'. Cannot proceed safely."

    local tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    info "Fetching $path …"
    curl -fsSL "$REPO_URL/$path" -o "$tmp"

    local actual
    actual=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$tmp"
        error "Checksum mismatch for '$path'.\n  Expected: $expected\n  Got:      $actual\nAborting — the file may have been tampered with."
    fi

    mv "$tmp" "$dest"
    success "Verified and installed $(basename "$dest")"
}

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
                validate_integer_range "$hour_ans" 0 23 "Hour"
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
                validate_integer_range "$dow_ans" 0 6 "Day of week"
                validate_integer_range "$hour_ans" 0 23 "Hour"
                CRON_SCHEDULE="0 $hour_ans * * $dow_ans"
                info "Schedule set to: Weekly on day $dow_ans at ${hour_ans}:00"
                ;;
        esac
    fi

    if [ -z "${ADMIN_EMAIL:-}" ]; then
        echo ""
        echo -e "${BLUE}? Admin email for cron failure alerts (leave blank to disable): \c${NC}"
        read -r email_ans < /dev/tty
        ADMIN_EMAIL="${email_ans:-}"
    fi
fi

ENABLE_CLEANUP="${ENABLE_CLEANUP:-true}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * 0}"

# ── Validate all inputs before touching anything on disk ──────────────────────
step "Validating configuration"
validate_cron_schedule "$CRON_SCHEDULE"
validate_wp_path       "$WP_PATH"
validate_wp_user       "$WP_USER"
validate_reboot_time   "$REBOOT_TIME"
validate_log_path      "$LOG_FILE"
success "All inputs validated"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight Checks"

[[ $EUID -ne 0 ]] && error "Please run as root (or use sudo)."

if [[ "$DRY_RUN" != "true" ]]; then
    command -v curl        &>/dev/null || apt-get install -y -q curl
    command -v lsb_release &>/dev/null || apt-get install -y -q lsb-release
    command -v sha256sum   &>/dev/null || apt-get install -y -q coreutils
fi

OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
VER=$(lsb_release -sr 2>/dev/null || echo "0")

[[ "$OS" != "Ubuntu" ]] && warn "Tested on Ubuntu — proceeding anyway on $OS $VER"
info "WP path: $WP_PATH (owner: $WP_USER)"

if [[ ! -f "$WP_PATH/wp-includes/version.php" ]]; then
    warn "Could not find WordPress at $WP_PATH. Cron job will be installed but may fail."
fi

# ── 1. OS Auto-Updates & Intrusion Prevention ─────────────────────────────────
step "OS security (unattended-upgrades & fail2ban)"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "apt-get install unattended-upgrades update-notifier-common powermgmt-base fail2ban"
    dry_run "install verified configs/50unattended-upgrades → /etc/apt/apt.conf.d/50unattended-upgrades"
    dry_run "install verified configs/20auto-upgrades → /etc/apt/apt.conf.d/20auto-upgrades"
else
    apt-get install -y -q unattended-upgrades update-notifier-common powermgmt-base fail2ban
    fetch_verified "configs/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades
    fetch_verified "configs/20auto-upgrades"       /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --now unattended-upgrades
    systemctl enable --now fail2ban
    success "unattended-upgrades & fail2ban active"
fi

# ── 2. needrestart ────────────────────────────────────────────────────────────
step "Service auto-restart (needrestart)"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "apt-get install needrestart"
    dry_run "install verified configs/needrestart.conf → /etc/needrestart/needrestart.conf"
else
    apt-get install -y -q needrestart
    fetch_verified "configs/needrestart.conf" /etc/needrestart/needrestart.conf
    success "needrestart configured"
fi

# ── 3. Kernel-reboot timer ────────────────────────────────────────────────────
step "Auto-reboot timer"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "install verified auto-reboot.service → /etc/systemd/system/auto-reboot.service"
    dry_run "install verified auto-reboot.timer (REBOOT_TIME=$REBOOT_TIME) → /etc/systemd/system/auto-reboot.timer"
else
    local_svc=$(mktemp)
    local_tmr=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$local_svc' '$local_tmr'" EXIT

    fetch_verified "configs/auto-reboot.service"   "$local_svc"
    fetch_verified "configs/auto-reboot.timer.tpl" "$local_tmr"

    cp "$local_svc" /etc/systemd/system/auto-reboot.service

    # REBOOT_TIME is already validated as HH:MM:SS — safe for sed substitution.
    sed "s|__REBOOT_TIME__|${REBOOT_TIME}|g" "$local_tmr" \
        > /etc/systemd/system/auto-reboot.timer

    systemctl daemon-reload
    systemctl enable --now auto-reboot.timer
    success "auto-reboot.timer scheduled nightly at $REBOOT_TIME UTC"
fi

# ── 4. System Cleanup ─────────────────────────────────────────────────────────
if [ "$ENABLE_CLEANUP" = "true" ]; then
    step "System Cleanup Script"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "write /usr/local/bin/vm-system-cleanup.sh"
    else
        cat << 'EOF' > /usr/local/bin/vm-system-cleanup.sh
#!/bin/bash
set -euo pipefail
LOG="/var/log/vm-system-cleanup.log"
{
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') System Cleanup ==="
    apt-get autoremove --purge -y
    apt-get autoclean -y
    journalctl --vacuum-time=7d --vacuum-size=200M
    echo "=== Cleanup Complete ==="
} >> "$LOG" 2>&1
EOF
        chmod 750 /usr/local/bin/vm-system-cleanup.sh
        # Secure the cleanup log
        [[ ! -f /var/log/vm-system-cleanup.log ]] && \
            install -m 640 -o root -g adm /dev/null /var/log/vm-system-cleanup.log
        success "Generated /usr/local/bin/vm-system-cleanup.sh"
    fi
fi

# ── 5. Log Rotation ───────────────────────────────────────────────────────────
step "Log Rotation Configuration"
if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write /etc/logrotate.d/twdxwpss"
else
    cat << 'EOF' > /etc/logrotate.d/twdxwpss
/var/log/wp-auto-update.log
/var/log/vm-system-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF
    success "Log rotation configured"
fi

# ── 6. WP-CLI ─────────────────────────────────────────────────────────────────
step "WP-CLI"
if command -v wp &>/dev/null; then
    info "WP-CLI already installed — skipping download"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "download wp-cli.phar and verify SHA512 against official hash"
else
    WP_CLI_TMP=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$WP_CLI_TMP'" EXIT

    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o "$WP_CLI_TMP"

    EXPECTED_WP_HASH=$(curl -fsSL \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512 \
        | awk '{print $1}')
    ACTUAL_WP_HASH=$(sha512sum "$WP_CLI_TMP" | awk '{print $1}')

    if [[ "$EXPECTED_WP_HASH" != "$ACTUAL_WP_HASH" ]]; then
        rm -f "$WP_CLI_TMP"
        error "WP-CLI SHA512 verification failed. Aborting."
    fi

    mv "$WP_CLI_TMP" /usr/local/bin/wp
    chmod 755 /usr/local/bin/wp
    success "WP-CLI installed and verified"
fi

# ── 7. WordPress update script ────────────────────────────────────────────────
step "Generating WP update script"

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "fetch and install wp-auto-update.sh.tpl → /usr/local/bin/wp-auto-update.sh"
else
    WP_TPL_TMP=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$WP_TPL_TMP'" EXIT

    fetch_verified "scripts/wp-auto-update.sh.tpl" "$WP_TPL_TMP"

    # WP_PATH, WP_USER, and LOG_FILE are all validated above — safe for substitution.
    sed \
        -e "s|__WP_PATH__|${WP_PATH}|g" \
        -e "s|__WP_USER__|${WP_USER}|g" \
        -e "s|__LOG_FILE__|${LOG_FILE}|g" \
        "$WP_TPL_TMP" > /usr/local/bin/wp-auto-update.sh

    chmod 750 /usr/local/bin/wp-auto-update.sh

    # Create log file with restricted permissions (root:adm, 640 — not world-readable)
    [[ ! -f "$LOG_FILE" ]] && install -m 640 -o root -g adm /dev/null "$LOG_FILE"
    success "wp-auto-update.sh installed"
fi

# ── 8. Cron jobs (via /etc/cron.d/ for auditability) ─────────────────────────
step "Applying Schedules"

CRON_FILE="/etc/cron.d/twdxwpss"
CLEANUP_SCHEDULE=$(echo "$CRON_SCHEDULE" | sed 's/^[0-9*,\/\-]*/30/')

if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write $CRON_FILE (CRON_SCHEDULE='$CRON_SCHEDULE')"
else
    {
        echo "# TWDxWordPressServerSecurity — managed by installer"
        echo "# Re-run install.sh to update this file."
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
        [[ -n "$ADMIN_EMAIL" ]] && echo "MAILTO=$ADMIN_EMAIL" || echo "MAILTO="
        echo "$CRON_SCHEDULE root /usr/local/bin/wp-auto-update.sh"
        if [ "$ENABLE_CLEANUP" = "true" ]; then
            echo "$CLEANUP_SCHEDULE root /usr/local/bin/vm-system-cleanup.sh"
        fi
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    success "Cron jobs written to $CRON_FILE (CRON_SCHEDULE: $CRON_SCHEDULE)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}  Dry-run complete — no changes were made.${NC}"
else
    echo -e "${GREEN}  TWDxWordPressServerSecurity installed on $(hostname)${NC}"
fi
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
echo
printf "  %-28s %-14s\n" "Component" "Status"
echo  "  ──────────────────────────────────────────"

if [[ "$DRY_RUN" == "true" ]]; then
    STATUS="${YELLOW}dry-run${NC}"
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "OS security updates"  "dry-run"
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "Intrusion prevention" "dry-run"
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "Service restarts"     "dry-run"
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "Kernel reboot"        "dry-run"
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "Log rotation"         "dry-run"
    printf "  %-28s ${YELLOW}%-14s${NC}\n" "WP auto-updates"      "dry-run ($CRON_SCHEDULE)"
    [ "$ENABLE_CLEANUP" = "true" ] && \
        printf "  %-28s ${YELLOW}%-14s${NC}\n" "System cleanup" "dry-run"
else
    printf "  %-28s ${GREEN}%-14s${NC}\n" "OS security updates"  "✓ active"
    printf "  %-28s ${GREEN}%-14s${NC}\n" "Intrusion prevention" "✓ active"
    printf "  %-28s ${GREEN}%-14s${NC}\n" "Service restarts"     "✓ active"
    printf "  %-28s ${GREEN}%-14s${NC}\n" "Kernel reboot"        "✓ active"
    printf "  %-28s ${GREEN}%-14s${NC}\n" "Log rotation"         "✓ active"
    printf "  %-28s ${GREEN}%-14s${NC}\n" "WP auto-updates"      "✓ active ($CRON_SCHEDULE)"
    [ "$ENABLE_CLEANUP" = "true" ] && \
        printf "  %-28s ${GREEN}%-14s${NC}\n" "System cleanup" "✓ active"
fi
echo
echo -e "${CYAN}  Thank you for using automation by TheWebDexter.com${NC}"
echo
