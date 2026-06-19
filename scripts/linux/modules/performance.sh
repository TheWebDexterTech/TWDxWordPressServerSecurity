#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# performance.sh — Performance tuning analysis and optimization
#
# Part of the TWDx Linux Maintenance Toolkit.
# Analyzes system performance settings and optionally applies recommended
# tuning for server workloads.
#
# Default mode: REPORT ONLY. Nothing is changed unless --apply is given.
#
# Usage (standalone):
#   sudo ./performance.sh              # report only
#   sudo ./performance.sh --apply      # offer to apply recommended sysctl values
#   sudo ./performance.sh --apply --aggressive  # also offer to disable slow services
#   sudo ./performance.sh --cron       # non-interactive, implies --apply
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Standalone vs sourced bootstrap
# ---------------------------------------------------------------------------
_PERF_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  _PERF_SOURCED=1
fi

if [[ $_PERF_SOURCED -eq 0 ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # shellcheck source=../lib/common.sh
  source "$SCRIPT_DIR/../lib/common.sh"

  for arg in "$@"; do
    case "$arg" in
      --apply)      TWDX_APPLY=1 ;;
      --aggressive) TWDX_AGGRESSIVE=1 ;;
      --cron)
        TWDX_APPLY=1
        TWDX_CRON=1
        TWDX_SILENT=1
        ;;
      -h|--help)
        echo "Usage: $0 [--apply] [--aggressive] [--cron]"
        echo "  --apply       Apply recommended performance tuning (default: report only)"
        echo "  --aggressive  Also offer to disable slow startup services"
        echo "  --cron        Non-interactive mode for scheduled runs (implies --apply)"
        exit 0
        ;;
    esac
  done

  twdx_require_root
  twdx_init
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly PERF_SYSCTL_DROPIN="/etc/sysctl.d/99-twdx-performance.conf"
readonly PERF_RECOMMENDED_SWAPPINESS=10
readonly PERF_RECOMMENDED_SOMAXCONN=4096
readonly PERF_RECOMMENDED_TCP_MAX_SYN_BACKLOG=4096
readonly PERF_RECOMMENDED_DIRTY_RATIO=10
readonly PERF_RECOMMENDED_DIRTY_BG_RATIO=5
readonly PERF_RECOMMENDED_INOTIFY_WATCHES=524288

# Services that must never be disabled, even in aggressive mode.
readonly PERF_PROTECTED_SERVICES_REGEX='^(ssh|sshd|systemd-|networking|NetworkManager|network-manager|netplan|cloud-init|cron|crond|ufw|resolvconf|systemd-resolved|systemd-networkd|dbus|udev|getty@|serial-getty@)'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read a sysctl value, return empty string on failure.
_sysctl_get() {
  sysctl -n "$1" 2>/dev/null || echo ""
}

# Read the first line of a file, return empty string on failure.
_read_first_line() {
  head -n1 "$1" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# 1. Swappiness
# ---------------------------------------------------------------------------
_check_swappiness() {
  twdx_subsection "Swappiness"

  local current
  current=$(_sysctl_get vm.swappiness)

  if [[ -z "$current" ]]; then
    twdx_warn "Could not read vm.swappiness"
    return
  fi

  twdx_info "Current vm.swappiness: $current (default: 60)"

  if [[ "$current" -le "$PERF_RECOMMENDED_SWAPPINESS" ]]; then
    twdx_success "Swappiness is already at or below recommended value ($PERF_RECOMMENDED_SWAPPINESS)"
  else
    twdx_warn "Swappiness $current is high for a server — recommend $PERF_RECOMMENDED_SWAPPINESS"
    twdx_info "High swappiness causes the kernel to swap out memory aggressively,"
    twdx_info "increasing I/O latency on servers with ample RAM."

    if [[ $TWDX_APPLY -eq 1 ]]; then
      if twdx_confirm "Set vm.swappiness=$PERF_RECOMMENDED_SWAPPINESS (runtime + sysctl drop-in)?"; then
        sysctl -w "vm.swappiness=$PERF_RECOMMENDED_SWAPPINESS" >> "$TWDX_LOG_FILE" 2>&1
        twdx_action "Set vm.swappiness=$PERF_RECOMMENDED_SWAPPINESS (runtime)"
      fi
    else
      twdx_dry_run "Would set vm.swappiness=$PERF_RECOMMENDED_SWAPPINESS"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 2. I/O Scheduler
# ---------------------------------------------------------------------------
_check_io_scheduler() {
  twdx_subsection "I/O Scheduler"

  local found_any=0

  for dev_path in /sys/block/*/queue/scheduler; do
    [[ -f "$dev_path" ]] || continue
    found_any=1

    local dev
    dev=$(echo "$dev_path" | sed 's|/sys/block/||;s|/queue/scheduler||')

    # Skip virtual/loop devices
    [[ "$dev" == loop* ]] && continue
    [[ "$dev" == ram* ]] && continue
    [[ "$dev" == dm-* ]] && continue

    local sched_line
    sched_line=$(_read_first_line "$dev_path")
    # Active scheduler is wrapped in [brackets]
    local active
    active=$(echo "$sched_line" | grep -oP '\[\K[^\]]+' || echo "unknown")

    # Detect if SSD (rotational == 0) or HDD (rotational == 1)
    local rotational_file="/sys/block/$dev/queue/rotational"
    local is_ssd=0
    if [[ -f "$rotational_file" ]]; then
      local rot
      rot=$(_read_first_line "$rotational_file")
      [[ "$rot" == "0" ]] && is_ssd=1
    fi

    local dev_type="HDD"
    local recommended="bfq"
    if [[ $is_ssd -eq 1 ]]; then
      dev_type="SSD/VM"
      recommended="mq-deadline"
    fi

    twdx_info "$dev ($dev_type): scheduler=$active  (available: $sched_line)"

    if [[ "$active" == "$recommended" ]]; then
      twdx_success "$dev: already using recommended scheduler ($recommended)"
    elif [[ "$active" == "none" ]]; then
      twdx_info "$dev: scheduler is 'none' (common for NVMe — no action needed)"
    else
      twdx_warn "$dev: recommend '$recommended' for $dev_type (currently '$active')"
    fi
  done

  if [[ $found_any -eq 0 ]]; then
    twdx_info "No block device scheduler information found"
  fi
}

# ---------------------------------------------------------------------------
# 3. Startup Services
# ---------------------------------------------------------------------------
_check_startup_services() {
  twdx_subsection "Startup Services"

  if ! command -v systemd-analyze &>/dev/null; then
    twdx_info "systemd-analyze not available — skipping boot analysis"
    return
  fi

  twdx_info "Boot time summary:"
  local boot_time
  boot_time=$(systemd-analyze time 2>/dev/null) || true
  if [[ -n "$boot_time" ]]; then
    twdx_log "  $boot_time"
  else
    twdx_warn "Could not retrieve boot time (system may be running in a container)"
    return
  fi

  twdx_info "Top 15 slowest services at boot:"
  local blame_output
  blame_output=$(systemd-analyze blame 2>/dev/null | head -n 15) || true
  if [[ -n "$blame_output" ]]; then
    while IFS= read -r line; do
      twdx_log "  $line"
    done <<< "$blame_output"
  fi

  if [[ $TWDX_APPLY -eq 1 && $TWDX_AGGRESSIVE -eq 1 && $TWDX_CRON -eq 0 ]]; then
    twdx_info "Reviewing slow startup services for possible disabling..."
    local slow_services
    slow_services=$(systemd-analyze blame 2>/dev/null \
      | head -n 15 \
      | awk '{print $2}' \
      | grep '\.service$') || true

    for svc in $slow_services; do
      [[ -z "$svc" ]] && continue
      if [[ "$svc" =~ $PERF_PROTECTED_SERVICES_REGEX ]]; then
        twdx_info "Skipping protected service: $svc"
        continue
      fi

      if twdx_confirm "Disable slow service '$svc' from boot?"; then
        systemctl disable "$svc" >> "$TWDX_LOG_FILE" 2>&1
        twdx_action "Disabled startup service: $svc"
      fi
    done
  elif [[ $TWDX_AGGRESSIVE -eq 0 ]]; then
    twdx_info "Use --apply --aggressive to interactively disable slow startup services"
  fi
}

# ---------------------------------------------------------------------------
# 4. Resource-Heavy Processes
# ---------------------------------------------------------------------------
_check_heavy_processes() {
  twdx_subsection "Resource-Heavy Processes"

  twdx_info "Top 10 processes by CPU usage:"
  local cpu_output
  cpu_output=$(ps aux --sort=-%cpu 2>/dev/null | head -n 11) || true
  if [[ -n "$cpu_output" ]]; then
    while IFS= read -r line; do
      twdx_log "  $line"
    done <<< "$cpu_output"
  fi

  twdx_info "Top 10 processes by memory usage:"
  local mem_output
  mem_output=$(ps aux --sort=-%mem 2>/dev/null | head -n 11) || true
  if [[ -n "$mem_output" ]]; then
    while IFS= read -r line; do
      twdx_log "  $line"
    done <<< "$mem_output"
  fi
}

# ---------------------------------------------------------------------------
# 5. File Descriptor Limits
# ---------------------------------------------------------------------------
_check_fd_limits() {
  twdx_subsection "File Descriptor Limits"

  local soft_limit
  soft_limit=$(ulimit -n 2>/dev/null || echo "unknown")
  twdx_info "Current soft file descriptor limit (ulimit -n): $soft_limit"

  local file_max
  file_max=$(_sysctl_get fs.file-max)
  twdx_info "System-wide file descriptor limit (fs.file-max): ${file_max:-unknown}"

  local file_nr
  file_nr=$(_read_first_line /proc/sys/fs/file-nr)
  if [[ -n "$file_nr" ]]; then
    local allocated free max_nr
    allocated=$(echo "$file_nr" | awk '{print $1}')
    free=$(echo "$file_nr" | awk '{print $2}')
    max_nr=$(echo "$file_nr" | awk '{print $3}')
    twdx_info "File descriptors: allocated=$allocated  free=$free  max=$max_nr"
  fi

  if [[ "$soft_limit" != "unknown" && "$soft_limit" -lt 65536 ]]; then
    twdx_warn "Soft FD limit ($soft_limit) is low for a server — consider raising to 65536+"
    twdx_info "Edit /etc/security/limits.conf or use a systemd override for the target service"
  else
    twdx_success "File descriptor soft limit ($soft_limit) looks adequate"
  fi

  if [[ -n "$file_max" && "$file_max" -lt 100000 ]]; then
    twdx_warn "System-wide fs.file-max ($file_max) is low — recommend at least 100000"
  elif [[ -n "$file_max" ]]; then
    twdx_success "System-wide fs.file-max ($file_max) looks adequate"
  fi
}

# ---------------------------------------------------------------------------
# 6. Kernel Tuning Review
# ---------------------------------------------------------------------------
_check_kernel_tuning() {
  twdx_subsection "Kernel Tuning Review"

  local -A tuning_map=(
    ["net.core.somaxconn"]="$PERF_RECOMMENDED_SOMAXCONN"
    ["net.ipv4.tcp_max_syn_backlog"]="$PERF_RECOMMENDED_TCP_MAX_SYN_BACKLOG"
    ["vm.dirty_ratio"]="$PERF_RECOMMENDED_DIRTY_RATIO"
    ["vm.dirty_background_ratio"]="$PERF_RECOMMENDED_DIRTY_BG_RATIO"
    ["fs.inotify.max_user_watches"]="$PERF_RECOMMENDED_INOTIFY_WATCHES"
  )

  local needs_tuning=0
  local sysctl_content=""

  for key in net.core.somaxconn net.ipv4.tcp_max_syn_backlog vm.dirty_ratio vm.dirty_background_ratio fs.inotify.max_user_watches; do
    local current recommended
    current=$(_sysctl_get "$key")
    recommended="${tuning_map[$key]}"

    if [[ -z "$current" ]]; then
      twdx_warn "$key: could not read current value"
      continue
    fi

    twdx_info "$key = $current (recommended: $recommended)"

    local suboptimal=0
    case "$key" in
      vm.dirty_ratio|vm.dirty_background_ratio)
        # For dirty ratios, lower is better for servers (less data loss risk)
        [[ "$current" -gt "$recommended" ]] && suboptimal=1
        ;;
      *)
        # For everything else, higher is better
        [[ "$current" -lt "$recommended" ]] && suboptimal=1
        ;;
    esac

    if [[ $suboptimal -eq 1 ]]; then
      twdx_warn "$key is suboptimal for server workloads"
      needs_tuning=1
      sysctl_content+="$key = $recommended"$'\n'
    else
      twdx_success "$key is at or above recommended value"
    fi
  done

  # Also include swappiness in the drop-in if it needs tuning
  local current_swappiness
  current_swappiness=$(_sysctl_get vm.swappiness)
  if [[ -n "$current_swappiness" && "$current_swappiness" -gt "$PERF_RECOMMENDED_SWAPPINESS" ]]; then
    sysctl_content="vm.swappiness = $PERF_RECOMMENDED_SWAPPINESS"$'\n'"$sysctl_content"
    needs_tuning=1
  fi

  if [[ $needs_tuning -eq 1 && $TWDX_APPLY -eq 1 ]]; then
    if twdx_confirm "Write recommended sysctl values to $PERF_SYSCTL_DROPIN and apply?"; then
      {
        echo "# TWDx Performance Tuning"
        echo "# Generated by TWDx Linux Maintenance Toolkit on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "#"
        echo "$sysctl_content"
      } > "$PERF_SYSCTL_DROPIN"
      sysctl --system >> "$TWDX_LOG_FILE" 2>&1
      twdx_action "Wrote performance sysctl values to $PERF_SYSCTL_DROPIN and applied"
    fi
  elif [[ $needs_tuning -eq 1 ]]; then
    twdx_dry_run "Would write recommended sysctl values to $PERF_SYSCTL_DROPIN"
  else
    twdx_success "All checked kernel parameters are at or above recommended values"
  fi
}

# ---------------------------------------------------------------------------
# 7. Transparent Huge Pages
# ---------------------------------------------------------------------------
_check_thp() {
  twdx_subsection "Transparent Huge Pages (THP)"

  local thp_enabled_path="/sys/kernel/mm/transparent_hugepage/enabled"
  local thp_defrag_path="/sys/kernel/mm/transparent_hugepage/defrag"

  if [[ ! -f "$thp_enabled_path" ]]; then
    twdx_info "THP sysfs interface not found — THP may not be available on this kernel"
    return
  fi

  local thp_enabled
  thp_enabled=$(_read_first_line "$thp_enabled_path")
  twdx_info "THP status: $thp_enabled"

  local active_mode
  active_mode=$(echo "$thp_enabled" | grep -oP '\[\K[^\]]+' || echo "unknown")

  if [[ -f "$thp_defrag_path" ]]; then
    local thp_defrag
    thp_defrag=$(_read_first_line "$thp_defrag_path")
    twdx_info "THP defrag: $thp_defrag"
  fi

  if [[ "$active_mode" == "always" ]]; then
    twdx_warn "THP is set to 'always' — this can cause latency spikes"
    twdx_info "Databases (MySQL, PostgreSQL, Redis, MongoDB) often perform worse with THP enabled."
    twdx_info "Consider setting to 'madvise' so only applications that opt in use THP."
    twdx_info "To change: echo madvise > $thp_enabled_path"
  elif [[ "$active_mode" == "madvise" ]]; then
    twdx_success "THP is set to 'madvise' — applications opt in individually (recommended)"
  elif [[ "$active_mode" == "never" ]]; then
    twdx_info "THP is disabled entirely"
  else
    twdx_info "THP mode: $active_mode"
  fi
}

# ---------------------------------------------------------------------------
# 8. CPU Governor
# ---------------------------------------------------------------------------
_check_cpu_governor() {
  twdx_subsection "CPU Frequency Governor"

  local governor_path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"

  if [[ ! -f "$governor_path" ]]; then
    twdx_info "CPU frequency scaling not available (common in VMs/containers)"
    return
  fi

  local governor
  governor=$(_read_first_line "$governor_path")
  twdx_info "Current CPU governor: $governor"

  # List available governors
  local available_path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
  if [[ -f "$available_path" ]]; then
    local available
    available=$(_read_first_line "$available_path")
    twdx_info "Available governors: $available"
  fi

  case "$governor" in
    performance)
      twdx_success "CPU governor is 'performance' — optimal for dedicated servers"
      ;;
    powersave)
      twdx_warn "CPU governor is 'powersave' — may throttle performance"
      twdx_info "For servers, 'performance' governor keeps CPUs at maximum frequency."
      twdx_info "To change: echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
      ;;
    ondemand|conservative|schedutil)
      twdx_info "CPU governor '$governor' scales frequency dynamically"
      twdx_info "For latency-sensitive servers, consider 'performance' governor"
      ;;
    *)
      twdx_info "CPU governor: $governor"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
run_performance() {
  twdx_section "Performance Tuning Analysis"

  _check_swappiness
  _check_io_scheduler
  _check_startup_services
  _check_heavy_processes
  _check_fd_limits
  _check_kernel_tuning
  _check_thp
  _check_cpu_governor
}

# ---------------------------------------------------------------------------
# Run standalone
# ---------------------------------------------------------------------------
if [[ $_PERF_SOURCED -eq 0 ]]; then
  run_performance
  twdx_summary
fi
