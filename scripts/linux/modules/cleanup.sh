#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# cleanup.sh — System Cleanup module for TWDx Linux Maintenance Toolkit
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_cleanup() {
  twdx_subsection "Package Manager Detection"
  twdx_info "Package manager: $TWDX_PKG_MANAGER"

  # --- apt-based systems ---
  if [[ "$TWDX_PKG_MANAGER" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive

    # Show cache size before cleanup
    local cache_before
    cache_before=$(du -sh /var/cache/apt 2>/dev/null | awk '{print $1}')
    twdx_info "APT cache size before: ${cache_before:-unknown}"

    twdx_subsection "Package Updates"
    if [[ $TWDX_APPLY -eq 1 ]]; then
      local update_ok=0
      for attempt in 1 2 3; do
        if apt-get update >> "$TWDX_LOG_FILE" 2>&1; then
          update_ok=1
          twdx_success "apt-get update succeeded"
          break
        fi
        twdx_warn "apt-get update failed (attempt $attempt/3), retrying in 15s..."
        sleep 15
      done
      if [[ $update_ok -eq 0 ]]; then
        twdx_error "apt-get update failed after 3 attempts — skipping upgrade/autoremove"
        return 1
      fi
    else
      twdx_dry_run "would run: apt-get update"
    fi

    twdx_subsection "Upgradable Packages"
    apt list --upgradable 2>/dev/null | tee -a "$TWDX_LOG_FILE"

    twdx_subsection "Full Upgrade"
    if [[ $TWDX_APPLY -eq 1 ]]; then
      if CONFIRM_SAFE=1 twdx_confirm "Proceed with apt-get full-upgrade -y?"; then
        apt-get full-upgrade -y >> "$TWDX_LOG_FILE" 2>&1
        twdx_action "apt-get full-upgrade completed"
      fi
    else
      twdx_dry_run "would run: apt-get full-upgrade -y"
    fi

    twdx_subsection "Autoremove Orphaned Packages"
    twdx_info "Packages that would be removed:"
    apt-get -s autoremove 2>/dev/null | grep -E '^(Remv|The following packages)' | tee -a "$TWDX_LOG_FILE"

    if [[ $TWDX_APPLY -eq 1 ]]; then
      if CONFIRM_SAFE=1 twdx_confirm "Proceed with apt-get autoremove -y?"; then
        apt-get autoremove -y >> "$TWDX_LOG_FILE" 2>&1
        twdx_action "apt-get autoremove completed"
      fi
    else
      twdx_dry_run "would run: apt-get autoremove -y"
    fi

    twdx_subsection "Cache Cleanup"
    if [[ $TWDX_APPLY -eq 1 ]]; then
      apt-get autoclean -y >> "$TWDX_LOG_FILE" 2>&1
      apt-get clean >> "$TWDX_LOG_FILE" 2>&1
      local cache_after
      cache_after=$(du -sh /var/cache/apt 2>/dev/null | awk '{print $1}')
      twdx_action "APT cache cleaned (${cache_before:-?} -> ${cache_after:-?})"
    else
      twdx_dry_run "would run: apt-get autoclean && apt-get clean"
    fi

  else
    twdx_info "Non-apt system — showing equivalent commands:"
    case "$TWDX_PKG_MANAGER" in
      dnf|yum) twdx_info "  $TWDX_PKG_MANAGER update && $TWDX_PKG_MANAGER autoremove && $TWDX_PKG_MANAGER clean all" ;;
      pacman)  twdx_info "  pacman -Syu && pacman -Qtdq | pacman -Rns - && pacman -Scc" ;;
      zypper)  twdx_info "  zypper refresh && zypper update && zypper clean" ;;
      *)       twdx_warn "Unknown package manager — manual cleanup needed" ;;
    esac
  fi

  # --- Old kernels (apt only) ---
  if [[ "$TWDX_PKG_MANAGER" == "apt" ]]; then
    twdx_subsection "Old Kernel Packages"
    local current_kernel
    current_kernel=$(uname -r)
    twdx_info "Running kernel: $current_kernel"

    dpkg --list | grep -E '^ii  linux-(image|headers|modules)' | awk '{print $2}' | tee -a "$TWDX_LOG_FILE"

    local old_kernels
    old_kernels=$(dpkg --list | grep -E '^ii  linux-(image|headers|modules)-[0-9]' \
                   | awk '{print $2}' | grep -v "${current_kernel//-generic/}" || true)

    if [[ -n "$old_kernels" ]]; then
      twdx_warn "Old kernel packages found (not matching $current_kernel):"
      echo "$old_kernels" | tee -a "$TWDX_LOG_FILE"
      if [[ $TWDX_APPLY -eq 1 && $TWDX_AGGRESSIVE -eq 1 && $TWDX_CRON -eq 0 ]]; then
        if twdx_confirm "Purge these old kernel packages?"; then
          # shellcheck disable=SC2086
          apt-get purge -y $old_kernels >> "$TWDX_LOG_FILE" 2>&1
          twdx_action "Purged old kernel packages"
        fi
      else
        twdx_info "(Use --apply --aggressive to purge. autoremove usually handles this.)"
      fi
    else
      twdx_success "No old kernel packages found"
    fi
  fi

  # --- Journal cleanup ---
  twdx_subsection "Systemd Journal"
  if command -v journalctl &>/dev/null; then
    journalctl --disk-usage 2>&1 | tee -a "$TWDX_LOG_FILE"
    if [[ $TWDX_APPLY -eq 1 ]]; then
      journalctl --vacuum-time=2weeks >> "$TWDX_LOG_FILE" 2>&1
      twdx_action "Vacuumed systemd journal (kept last 2 weeks)"
    else
      twdx_dry_run "would run: journalctl --vacuum-time=2weeks"
    fi
  fi

  # --- Rotated logs ---
  twdx_subsection "Rotated Log Files (>30 days)"
  find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -printf '%p\t%k KB\n' 2>/dev/null \
    | sort -k2 -nr | head -n 20 | tee -a "$TWDX_LOG_FILE"

  if [[ $TWDX_APPLY -eq 1 ]]; then
    local deleted_logs
    deleted_logs=$(find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -mtime +30 -print -delete 2>/dev/null | wc -l)
    [[ "$deleted_logs" -gt 0 ]] && twdx_action "Removed $deleted_logs rotated log files (>30 days)"
  else
    twdx_dry_run "would remove rotated logs older than 30 days"
  fi

  # --- Temp files ---
  twdx_subsection "Stale Temp Files (>10 days)"
  local stale_tmp
  stale_tmp=$(find /tmp /var/tmp -mindepth 1 -mtime +10 2>/dev/null | wc -l)
  twdx_info "Found $stale_tmp stale temp files"

  if [[ $TWDX_APPLY -eq 1 ]]; then
    find /tmp /var/tmp -mindepth 1 -mtime +10 -delete 2>/dev/null
    [[ "$stale_tmp" -gt 0 ]] && twdx_action "Cleared $stale_tmp stale temp files (>10 days)"
  else
    twdx_dry_run "would clear $stale_tmp temp files older than 10 days"
  fi

  # --- Snap cleanup ---
  if command -v snap &>/dev/null; then
    twdx_subsection "Disabled Snap Revisions"
    local disabled_snaps
    disabled_snaps=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
    if [[ -n "$disabled_snaps" ]]; then
      echo "$disabled_snaps" | tee -a "$TWDX_LOG_FILE"
      if [[ $TWDX_APPLY -eq 1 ]]; then
        echo "$disabled_snaps" | while read -r sname rev; do
          snap remove "$sname" --revision="$rev" 2>/dev/null \
            && twdx_action "Removed disabled snap: $sname revision $rev"
        done
      else
        twdx_dry_run "would remove disabled snap revisions listed above"
      fi
    else
      twdx_success "No disabled snap revisions found"
    fi
  fi

  # --- Reboot check ---
  twdx_subsection "Reboot Status"
  if [[ -f /var/run/reboot-required ]]; then
    local reboot_pkgs=""
    [[ -f /var/run/reboot-required.pkgs ]] && reboot_pkgs=$(tr '\n' ' ' < /var/run/reboot-required.pkgs)
    twdx_warn "REBOOT REQUIRED — packages: ${reboot_pkgs:-unknown}"
  else
    twdx_success "No reboot required"
  fi
}

# ---------------------------------------------------------------------------
# Standalone execution
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  for arg in "$@"; do
    case "$arg" in
      --apply) export TWDX_APPLY=1 ;;
      --aggressive) export TWDX_AGGRESSIVE=1 ;;
      --cron) export TWDX_APPLY=1; export TWDX_CRON=1; export TWDX_SILENT=1 ;;
    esac
  done
  # shellcheck source=../lib/common.sh
  source "$SCRIPT_DIR/../lib/common.sh"
  twdx_require_root
  twdx_init
  twdx_section "System Cleanup"
  run_cleanup
  twdx_summary
fi
