#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# backup.sh — Backup & Recovery module for TWDx Linux Maintenance Toolkit
#
# Creates timestamped backups of system configuration, package lists,
# cron jobs, service state, and network config.  Rotates old backups.
#
# Default mode: DRY-RUN (shows what would be backed up).
# Pass --apply to create the backup, --cron for unattended scheduled runs.
#
# Usage (standalone):
#   sudo ./backup.sh              # dry-run — list what would be backed up
#   sudo ./backup.sh --apply      # create backup
#   sudo ./backup.sh --cron       # non-interactive, implies --apply
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve common.sh relative to this script
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../lib/common.sh"

_standalone=0
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _standalone=1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BACKUP_DIR="/var/backups/twdx"
BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP_TARBALL="${BACKUP_DIR}/system-config-${BACKUP_DATE}.tar.gz"
BACKUP_STAGING="${BACKUP_DIR}/.staging-${BACKUP_DATE}"
BACKUP_KEEP=10

# ---------------------------------------------------------------------------
# run_backup — main entry point
# ---------------------------------------------------------------------------
run_backup() {
  twdx_section "System Backup & Recovery"

  if [[ $TWDX_APPLY -eq 1 ]]; then
    _backup_apply
  else
    _backup_dry_run
  fi
}

# ---------------------------------------------------------------------------
# Dry-run: show what would be backed up + list existing backups
# ---------------------------------------------------------------------------
_backup_dry_run() {
  twdx_subsection "Dry-Run: Files that would be backed up"

  local -a config_paths=()
  _collect_config_paths config_paths

  for p in "${config_paths[@]}"; do
    if [[ -e "$p" ]]; then
      twdx_dry_run "Include: $p"
    else
      twdx_dry_run "Skip (not present): $p"
    fi
  done

  twdx_dry_run "Package list would be exported to ${BACKUP_DIR}/packages-$(date +%Y%m%d).txt"
  twdx_dry_run "Cron jobs would be exported to the backup tarball"
  twdx_dry_run "Enabled service list would be exported to the backup tarball"
  twdx_dry_run "Network configuration snapshot would be exported to the backup tarball"
  twdx_dry_run "Tarball would be created at: ${BACKUP_TARBALL}"
  twdx_dry_run "Backup rotation: keep last ${BACKUP_KEEP}, delete older"

  _list_existing_backups
  _show_restore_guide
}

# ---------------------------------------------------------------------------
# Apply: create the backup
# ---------------------------------------------------------------------------
_backup_apply() {
  mkdir -p "$BACKUP_DIR"
  mkdir -p "$BACKUP_STAGING"

  # 1. System config files
  _backup_system_configs

  # 2. Installed packages list
  _backup_packages_list

  # 3. Cron jobs export
  _backup_cron_jobs

  # 4. Service state snapshot
  _backup_service_state

  # 5. Network config snapshot
  _backup_network_config

  # 6. Create tarball
  _create_tarball

  # 7. Verify tarball
  _verify_tarball

  # 8. Rotate old backups
  _rotate_backups

  # Cleanup staging
  rm -rf "$BACKUP_STAGING"
}

# ---------------------------------------------------------------------------
# Collect config paths to back up
# ---------------------------------------------------------------------------
_collect_config_paths() {
  local -n _paths=$1
  _paths=(
    /etc/ssh/sshd_config
    /etc/ssh/sshd_config.d/
    /etc/sysctl.conf
    /etc/sysctl.d/
    /etc/fstab
    /etc/hosts
    /etc/crontab
    /etc/cron.d/
    /etc/logrotate.d/
  )

  # Conditional paths
  [[ -d /etc/ufw ]]                   && _paths+=(/etc/ufw/)
  [[ -d /etc/fail2ban ]]              && _paths+=(/etc/fail2ban/)
  [[ -f /etc/apt/sources.list ]]      && _paths+=(/etc/apt/sources.list)
  [[ -d /etc/apt/sources.list.d ]]    && _paths+=(/etc/apt/sources.list.d/)
  [[ -d /etc/systemd/system ]]        && _paths+=(/etc/systemd/system/)
}

# ---------------------------------------------------------------------------
# 1. System Config Backup
# ---------------------------------------------------------------------------
_backup_system_configs() {
  twdx_subsection "1. System Configuration Files"

  local -a config_paths=()
  _collect_config_paths config_paths

  local included=0
  local skipped=0

  for p in "${config_paths[@]}"; do
    if [[ -e "$p" ]]; then
      # Preserve directory structure in staging
      local parent
      parent="$(dirname "$p")"
      mkdir -p "${BACKUP_STAGING}${parent}"

      if [[ -d "$p" ]]; then
        cp -a "$p" "${BACKUP_STAGING}${parent}/" 2>/dev/null || true
      else
        cp -a "$p" "${BACKUP_STAGING}${p}" 2>/dev/null || true
      fi
      twdx_info "Backed up: $p"
      included=$((included + 1))
    else
      twdx_info "Skipped (not present): $p"
      skipped=$((skipped + 1))
    fi
  done

  twdx_success "Config backup: ${included} paths included, ${skipped} skipped"
}

# ---------------------------------------------------------------------------
# 2. Installed Packages List
# ---------------------------------------------------------------------------
_backup_packages_list() {
  twdx_subsection "2. Installed Packages List"

  local pkg_file
  pkg_file="${BACKUP_DIR}/packages-$(date +%Y%m%d).txt"
  local staging_pkg="${BACKUP_STAGING}/packages.txt"
  : > "$staging_pkg"

  case "${TWDX_PKG_MANAGER}" in
    apt)
      {
        echo "### dpkg --get-selections ###"
        dpkg --get-selections 2>/dev/null
        echo ""
        echo "### apt-mark showmanual ###"
        apt-mark showmanual 2>/dev/null
      } >> "$staging_pkg"
      twdx_info "Exported dpkg selections and manually installed packages"
      ;;
    dnf|yum)
      {
        echo "### rpm -qa ###"
        rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort
      } >> "$staging_pkg"
      twdx_info "Exported RPM package list"
      ;;
    *)
      echo "### Package manager: ${TWDX_PKG_MANAGER} (no export available) ###" >> "$staging_pkg"
      twdx_warn "No package export method for package manager: ${TWDX_PKG_MANAGER}"
      ;;
  esac

  # Snap packages (if available)
  if command -v snap &>/dev/null; then
    {
      echo ""
      echo "### snap list ###"
      snap list 2>/dev/null
    } >> "$staging_pkg"
    twdx_info "Exported snap package list"
  fi

  # Also save a standalone copy outside the tarball for quick reference
  cp "$staging_pkg" "$pkg_file"
  twdx_success "Package list saved to: ${pkg_file}"
}

# ---------------------------------------------------------------------------
# 3. Cron Jobs Export
# ---------------------------------------------------------------------------
_backup_cron_jobs() {
  twdx_subsection "3. Cron Jobs Export"

  local cron_file="${BACKUP_STAGING}/cron-jobs.txt"
  : > "$cron_file"

  # System crontab + cron.d (already copied as config files, but dump readable text too)
  {
    echo "### /etc/crontab ###"
    cat /etc/crontab 2>/dev/null || echo "(not found)"
    echo ""
    echo "### /etc/cron.d/ ###"
    for f in /etc/cron.d/*; do
      if [[ -f "$f" ]]; then
        echo "--- $f ---"
        cat "$f" 2>/dev/null
        echo ""
      fi
    done
  } >> "$cron_file"

  # Per-user crontabs
  {
    echo "### User crontabs ###"
    local crontab_dir="/var/spool/cron/crontabs"
    [[ -d /var/spool/cron ]] && ! [[ -d "$crontab_dir" ]] && crontab_dir="/var/spool/cron"

    if [[ -d "$crontab_dir" ]]; then
      for ct in "${crontab_dir}"/*; do
        if [[ -f "$ct" ]]; then
          local user
          user="$(basename "$ct")"
          echo "--- User: ${user} ---"
          cat "$ct" 2>/dev/null || echo "(permission denied)"
          echo ""
        fi
      done
    else
      echo "(no user crontab directory found)"
    fi
  } >> "$cron_file"

  local line_count
  line_count="$(wc -l < "$cron_file")"
  twdx_success "Cron jobs exported (${line_count} lines)"
}

# ---------------------------------------------------------------------------
# 4. Service State Snapshot
# ---------------------------------------------------------------------------
_backup_service_state() {
  twdx_subsection "4. Service State Snapshot"

  local svc_file="${BACKUP_STAGING}/enabled-services.txt"

  if command -v systemctl &>/dev/null; then
    {
      echo "### Enabled unit files ###"
      echo "# Generated: $(date -Iseconds)"
      echo ""
      systemctl list-unit-files --state=enabled --no-legend 2>/dev/null
    } > "$svc_file"

    local count
    count="$(grep -cv '^#\|^$' "$svc_file" 2>/dev/null || echo 0)"
    twdx_success "Service state snapshot: ${count} enabled units recorded"
  else
    echo "systemctl not available — service snapshot skipped" > "$svc_file"
    twdx_warn "systemctl not found, service state snapshot skipped"
  fi
}

# ---------------------------------------------------------------------------
# 5. Network Config Snapshot
# ---------------------------------------------------------------------------
_backup_network_config() {
  twdx_subsection "5. Network Configuration Snapshot"

  local net_file="${BACKUP_STAGING}/network-config.txt"
  : > "$net_file"

  # IP addresses
  {
    echo "### ip addr ###"
    ip addr 2>/dev/null || echo "(ip command not available)"
    echo ""

    echo "### ip route ###"
    ip route 2>/dev/null || echo "(ip command not available)"
    echo ""
  } >> "$net_file"

  # iptables rules
  if command -v iptables-save &>/dev/null; then
    {
      echo "### iptables-save ###"
      iptables-save 2>/dev/null || echo "(failed or no rules)"
      echo ""
    } >> "$net_file"
  fi

  if command -v ip6tables-save &>/dev/null; then
    {
      echo "### ip6tables-save ###"
      ip6tables-save 2>/dev/null || echo "(failed or no rules)"
      echo ""
    } >> "$net_file"
  fi

  # Netplan (Ubuntu)
  if [[ -d /etc/netplan ]]; then
    mkdir -p "${BACKUP_STAGING}/etc/netplan"
    cp -a /etc/netplan/* "${BACKUP_STAGING}/etc/netplan/" 2>/dev/null || true
    twdx_info "Backed up /etc/netplan/ configuration"
  fi

  twdx_success "Network configuration snapshot captured"
}

# ---------------------------------------------------------------------------
# 6. Create Tarball
# ---------------------------------------------------------------------------
_create_tarball() {
  twdx_subsection "6. Creating Backup Tarball"

  if tar czf "$BACKUP_TARBALL" -C "$BACKUP_STAGING" . 2>/dev/null; then
    local size
    size="$(du -h "$BACKUP_TARBALL" | awk '{print $1}')"
    twdx_action "Backup tarball created: ${BACKUP_TARBALL} (${size})"
  else
    twdx_warn "Failed to create backup tarball at ${BACKUP_TARBALL}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 7. Verify Tarball
# ---------------------------------------------------------------------------
_verify_tarball() {
  twdx_subsection "7. Backup Verification"

  if [[ ! -f "$BACKUP_TARBALL" ]]; then
    twdx_warn "Tarball not found, cannot verify: ${BACKUP_TARBALL}"
    return 1
  fi

  if tar tzf "$BACKUP_TARBALL" &>/dev/null; then
    local file_count
    file_count="$(tar tzf "$BACKUP_TARBALL" | wc -l)"
    twdx_success "Tarball integrity verified: ${file_count} entries"
  else
    twdx_warn "Tarball integrity check FAILED: ${BACKUP_TARBALL}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 8. Backup Rotation
# ---------------------------------------------------------------------------
_rotate_backups() {
  twdx_subsection "8. Backup Rotation"

  local backup_count
  backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'system-config-*.tar.gz' -type f | wc -l)"

  if [[ "$backup_count" -le "$BACKUP_KEEP" ]]; then
    twdx_info "Backup count (${backup_count}) within limit (${BACKUP_KEEP}), no rotation needed"
    return
  fi

  local to_delete
  to_delete=$((backup_count - BACKUP_KEEP))

  # Delete oldest backups beyond the retention limit
  # shellcheck disable=SC2012
  find "$BACKUP_DIR" -maxdepth 1 -name 'system-config-*.tar.gz' -type f -printf '%T@ %p\n' \
    | sort -n \
    | head -n "$to_delete" \
    | awk '{print $2}' \
    | while read -r old_backup; do
        rm -f "$old_backup"
        twdx_info "Rotated out: $(basename "$old_backup")"
      done

  # Also rotate old package list files (keep same count)
  local pkg_count
  pkg_count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'packages-*.txt' -type f | wc -l)"

  if [[ "$pkg_count" -gt "$BACKUP_KEEP" ]]; then
    local pkg_delete
    pkg_delete=$((pkg_count - BACKUP_KEEP))
    find "$BACKUP_DIR" -maxdepth 1 -name 'packages-*.txt' -type f -printf '%T@ %p\n' \
      | sort -n \
      | head -n "$pkg_delete" \
      | awk '{print $2}' \
      | while read -r old_pkg; do
          rm -f "$old_pkg"
          twdx_info "Rotated out: $(basename "$old_pkg")"
        done
  fi

  twdx_action "Backup rotation complete: kept last ${BACKUP_KEEP} backups, removed ${to_delete}"
}

# ---------------------------------------------------------------------------
# List existing backups (used in dry-run mode)
# ---------------------------------------------------------------------------
_list_existing_backups() {
  twdx_subsection "Existing Backups"

  if [[ ! -d "$BACKUP_DIR" ]]; then
    twdx_info "No backup directory found at ${BACKUP_DIR}"
    return
  fi

  local count
  count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'system-config-*.tar.gz' -type f 2>/dev/null | wc -l)"

  if [[ "$count" -eq 0 ]]; then
    twdx_info "No existing backups found in ${BACKUP_DIR}"
    return
  fi

  twdx_info "Found ${count} backup(s) in ${BACKUP_DIR}:"
  # shellcheck disable=SC2012
  find "$BACKUP_DIR" -maxdepth 1 -name 'system-config-*.tar.gz' -type f -printf '%T@ %p\n' \
    | sort -rn \
    | while read -r _ts path; do
        local name size date_str
        name="$(basename "$path")"
        size="$(du -h "$path" | awk '{print $1}')"
        date_str="$(date -r "$path" '+%Y-%m-%d %H:%M:%S')"
        twdx_info "  ${name}  ${size}  ${date_str}"
      done

  # Package list files
  local pkg_count
  pkg_count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'packages-*.txt' -type f 2>/dev/null | wc -l)"
  if [[ "$pkg_count" -gt 0 ]]; then
    twdx_info "Package list snapshots: ${pkg_count}"
  fi
}

# ---------------------------------------------------------------------------
# Restore guide (shown in dry-run mode)
# ---------------------------------------------------------------------------
_show_restore_guide() {
  twdx_subsection "Restore Guide"

  twdx_info "To restore from a backup tarball:"
  twdx_info ""
  twdx_info "  1. List contents:"
  twdx_info "     tar tzf ${BACKUP_DIR}/system-config-YYYYMMDD-HHMMSS.tar.gz"
  twdx_info ""
  twdx_info "  2. Extract a specific file (e.g. sshd_config):"
  twdx_info "     tar xzf <tarball> -C / ./etc/ssh/sshd_config"
  twdx_info ""
  twdx_info "  3. Extract everything to a review directory:"
  twdx_info "     mkdir /tmp/backup-review"
  twdx_info "     tar xzf <tarball> -C /tmp/backup-review"
  twdx_info "     diff -r /tmp/backup-review/etc/ssh /etc/ssh"
  twdx_info ""
  twdx_info "  4. Restore package list (apt):"
  twdx_info "     dpkg --set-selections < ${BACKUP_DIR}/packages-YYYYMMDD.txt"
  twdx_info "     apt-get dselect-upgrade"
  twdx_info ""
  twdx_info "  5. Re-enable services:"
  twdx_info "     cat <extracted>/enabled-services.txt"
  twdx_info "     systemctl enable <unit-name>"
  twdx_info ""
  twdx_info "Always review extracted files before overwriting live configuration."
}

# ---------------------------------------------------------------------------
# Standalone execution
# ---------------------------------------------------------------------------
if [[ $_standalone -eq 1 ]]; then
  for arg in "$@"; do
    case "$arg" in
      --apply) TWDX_APPLY=1 ;;
      --cron)
        TWDX_APPLY=1
        TWDX_CRON=1
        TWDX_SILENT=1
        ;;
      -h|--help)
        echo "Usage: $0 [--apply] [--cron]"
        echo "  --apply   Create backup (default: dry-run, report only)"
        echo "  --cron    Non-interactive mode for scheduled runs (implies --apply)"
        exit 0
        ;;
    esac
  done

  # shellcheck source=../lib/common.sh
  source "$COMMON_SH"
  twdx_require_root
  twdx_init
  run_backup
  twdx_summary
fi
