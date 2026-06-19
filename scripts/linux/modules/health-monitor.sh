#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# health-monitor.sh — System health monitoring module for TWDx Linux Maintenance Toolkit
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Standalone runner
# ---------------------------------------------------------------------------
run_health_monitor() {
  twdx_section "System Health Monitor"

  # -- 1. Disk Usage --------------------------------------------------------
  twdx_subsection "Disk Usage"
  local df_output
  df_output=$(df -h --output=target,pcent,size,used,avail,fstype -x tmpfs -x devtmpfs -x squashfs 2>/dev/null) \
    || df_output=$(df -h 2>/dev/null)
  twdx_info "$df_output"

  local issues=0
  while IFS= read -r line; do
    local pct mount
    pct=$(echo "$line" | awk '{print $2}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $1}')
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    if (( pct > 95 )); then
      twdx_error "CRITICAL: $mount is ${pct}% full"
      issues=$((issues + 1))
    elif (( pct > 85 )); then
      twdx_warn "$mount is ${pct}% full"
      issues=$((issues + 1))
    fi
  done <<< "$df_output"
  (( issues == 0 )) && twdx_success "All partitions below 85% usage"

  # -- 2. Memory & Swap -----------------------------------------------------
  twdx_subsection "Memory & Swap"
  twdx_info "$(free -h)"

  local swap_total swap_used
  swap_total=$(free | awk '/^Swap:/{print $2}')
  swap_used=$(free | awk '/^Swap:/{print $3}')
  if (( swap_total > 0 )); then
    local swap_pct=$(( (swap_used * 100) / swap_total ))
    if (( swap_pct > 50 )); then
      twdx_warn "Swap usage is ${swap_pct}% — possible memory pressure"
    else
      twdx_success "Swap usage is ${swap_pct}%"
    fi
  else
    twdx_info "No swap configured"
  fi

  twdx_info "Top 10 memory-consuming processes:"
  twdx_info "$(ps aux --sort=-%mem | head -n 11)"

  # -- 3. CPU Load -----------------------------------------------------------
  twdx_subsection "CPU Load"
  twdx_info "$(uptime)"

  local load1 num_cpus
  load1=$(awk '{print $1}' /proc/loadavg)
  num_cpus=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
  if awk "BEGIN {exit !($load1 > $num_cpus)}"; then
    twdx_warn "1-min load average ($load1) exceeds CPU count ($num_cpus)"
  else
    twdx_success "Load average ($load1) is within normal range for $num_cpus CPU(s)"
  fi

  # -- 4. Zombie Processes ---------------------------------------------------
  twdx_subsection "Zombie Processes"
  local zombie_count
  zombie_count=$(ps aux | awk '$8 ~ /^Z/ {count++} END {print count+0}')
  if (( zombie_count > 0 )); then
    twdx_warn "$zombie_count zombie process(es) found:"
    twdx_info "$(ps aux | awk '$8 ~ /^Z/')"
  else
    twdx_success "No zombie processes"
  fi

  # -- 5. Failed systemd Services -------------------------------------------
  twdx_subsection "Failed systemd Services"
  if command -v systemctl &>/dev/null; then
    local failed
    failed=$(systemctl --failed --no-legend 2>/dev/null)
    if [[ -n "$failed" ]]; then
      twdx_warn "Failed units detected:"
      twdx_info "$failed"
    else
      twdx_success "No failed systemd units"
    fi
  else
    twdx_info "systemctl not available — skipping"
  fi

  # -- 6. Disk I/O Health (SMART) -------------------------------------------
  twdx_subsection "Disk I/O Health"
  if command -v smartctl &>/dev/null; then
    local disk
    for disk in $(lsblk -dpno NAME 2>/dev/null | grep -E '/dev/(sd|nvme|vd)'); do
      local smart_status
      smart_status=$(smartctl -H "$disk" 2>/dev/null | grep -i 'overall\|result' || true)
      if [[ -n "$smart_status" ]]; then
        if echo "$smart_status" | grep -qi 'PASSED\|OK'; then
          twdx_success "$disk: $smart_status"
        else
          twdx_warn "$disk: $smart_status"
        fi
      else
        twdx_info "$disk: SMART data not available"
      fi
    done
  else
    twdx_info "smartctl not installed — SMART health checks skipped (install smartmontools for disk health monitoring)"
  fi

  # -- 7. System Uptime & Last Reboot ---------------------------------------
  twdx_subsection "System Uptime & Last Reboot"
  twdx_info "Uptime: $(uptime -p 2>/dev/null || uptime)"
  twdx_info "Last reboot: $(who -b 2>/dev/null | awk '{print $3, $4}' || echo 'unknown')"

  local uptime_days
  uptime_days=$(awk '{print int($1/86400)}' /proc/uptime)
  if (( uptime_days > 90 )); then
    twdx_warn "System has been up for $uptime_days days without a reboot — consider scheduling one"
  else
    twdx_success "Uptime is $uptime_days day(s)"
  fi

  # -- 8. Kernel Messages ---------------------------------------------------
  twdx_subsection "Kernel Messages"
  if dmesg &>/dev/null; then
    local error_count
    error_count=$(dmesg --level=err,warn 2>/dev/null | tail -n 50 | grep -ciE 'error|fail' || echo 0)
    if (( error_count > 0 )); then
      twdx_warn "$error_count error/failure message(s) in recent kernel log (last 50 lines):"
      twdx_info "$(dmesg --level=err,warn 2>/dev/null | tail -n 50 | grep -iE 'error|fail')"
    else
      twdx_success "No recent error/failure messages in kernel log"
    fi
  else
    twdx_info "Cannot read dmesg — insufficient permissions"
  fi

  # -- 9. OOM Killer Activity -----------------------------------------------
  twdx_subsection "OOM Killer Activity"
  if command -v journalctl &>/dev/null; then
    local oom_count
    oom_count=$(journalctl -k --since "7 days ago" --no-pager 2>/dev/null | grep -ci 'out of memory\|oom-killer\|oom_reaper' || echo 0)
    if (( oom_count > 0 )); then
      twdx_warn "OOM killer was invoked $oom_count time(s) in the last 7 days:"
      twdx_info "$(journalctl -k --since '7 days ago' --no-pager 2>/dev/null | grep -i 'out of memory\|oom-killer\|oom_reaper' | tail -n 10)"
    else
      twdx_success "No OOM killer activity in the last 7 days"
    fi
  else
    twdx_info "journalctl not available — OOM check skipped"
  fi

  twdx_success "Health monitor complete"
}

# ---------------------------------------------------------------------------
# Standalone entry point
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  for arg in "$@"; do
    case "$arg" in
      --apply) export TWDX_APPLY=1 ;;
      --cron)  export TWDX_APPLY=1; export TWDX_CRON=1; export TWDX_SILENT=1 ;;
      -h|--help)
        echo "Usage: $0 [--apply] [--cron]"
        echo "  --apply  Run in apply mode (health monitor is read-only, but sets the flag)"
        echo "  --cron   Non-interactive mode for scheduled runs (implies --apply)"
        exit 0
        ;;
    esac
  done

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=../lib/common.sh
  source "${SCRIPT_DIR}/../lib/common.sh"
  twdx_require_root
  twdx_init
  run_health_monitor
  twdx_summary
fi
