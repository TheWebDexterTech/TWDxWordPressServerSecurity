#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# twdx-maintain.sh — TWDx Linux Maintenance Toolkit
#
# One-stop-shop for Linux system maintenance: cleanup, hardening,
# health monitoring, performance tuning, backups, network audit,
# and user/permission audit.
#
# All modules are safe by default (dry-run/report). Use --apply to act.
#
# Usage:
#   sudo ./twdx-maintain.sh                    # interactive menu
#   sudo ./twdx-maintain.sh --module cleanup   # run a specific module
#   sudo ./twdx-maintain.sh --all              # run all modules sequentially
#   sudo ./twdx-maintain.sh --all --apply      # run all modules and apply changes
#   sudo ./twdx-maintain.sh --cron             # non-interactive scheduled run
#                                               #   (runs: cleanup, health, backup)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
MODULE=""
RUN_ALL=0

ARGS_FOR_MODULES=()
for arg in "$@"; do
  case "$arg" in
    --module)   MODULE="__next__" ;;
    --all)      RUN_ALL=1 ;;
    --apply)    export TWDX_APPLY=1; ARGS_FOR_MODULES+=("$arg") ;;
    --aggressive) export TWDX_AGGRESSIVE=1; ARGS_FOR_MODULES+=("$arg") ;;
    --cron)
      export TWDX_APPLY=1
      export TWDX_CRON=1
      export TWDX_SILENT=1
      ARGS_FOR_MODULES+=("$arg")
      ;;
    -h|--help)
      cat <<'HELP'
TWDx Linux Maintenance Toolkit v1.0.0

Usage: sudo ./twdx-maintain.sh [OPTIONS]

Options:
  --module <name>   Run a specific module. Available modules:
                      cleanup      — Package updates, cache/log/tmp cleanup
                      health       — System health monitoring (disk, memory, CPU, SMART)
                      performance  — Performance tuning analysis & optimization
                      network      — Network security audit
                      backup       — System config backup & recovery
                      user-audit   — User accounts & permission security audit
  --all             Run all modules sequentially
  --apply           Actually perform changes (default: dry-run/report only)
  --aggressive      Enable interactive review of risky removals/changes
  --cron            Non-interactive scheduled mode (implies --apply, runs
                    cleanup + health + backup only)
  -h, --help        Show this help

Examples:
  sudo ./twdx-maintain.sh                          # interactive menu
  sudo ./twdx-maintain.sh --module health           # health check only
  sudo ./twdx-maintain.sh --all --apply             # run everything, apply safe changes
  sudo ./twdx-maintain.sh --module cleanup --apply --aggressive  # deep cleanup
  sudo ./twdx-maintain.sh --cron                    # scheduled maintenance run

All modules default to DRY-RUN mode — nothing is changed unless --apply is given.
HELP
      exit 0
      ;;
    *)
      if [[ "$MODULE" == "__next__" ]]; then
        MODULE="$arg"
      fi
      ;;
  esac
done

# If MODULE was set to __next__ but no value followed
[[ "$MODULE" == "__next__" ]] && MODULE=""

# ---------------------------------------------------------------------------
# Source shared library
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/common.sh"

twdx_require_root

# Set defaults if not already set by arg parsing
export TWDX_APPLY="${TWDX_APPLY:-0}"
export TWDX_AGGRESSIVE="${TWDX_AGGRESSIVE:-0}"
export TWDX_CRON="${TWDX_CRON:-0}"
export TWDX_SILENT="${TWDX_SILENT:-0}"

twdx_init

# ---------------------------------------------------------------------------
# Module registry
# ---------------------------------------------------------------------------
declare -A MODULES=(
  [cleanup]="modules/cleanup.sh|run_cleanup|System Cleanup"
  [health]="modules/health-monitor.sh|run_health_monitor|Health Monitor"
  [performance]="modules/performance.sh|run_performance|Performance Tuning"
  [network]="modules/network-audit.sh|run_network_audit|Network Audit"
  [backup]="modules/backup.sh|run_backup|Backup & Recovery"
  [user-audit]="modules/user-audit.sh|run_user_audit|User & Permission Audit"
)

MODULE_ORDER=(cleanup health performance network backup user-audit)
CRON_MODULES=(cleanup health backup)

run_module() {
  local key="$1"
  local entry="${MODULES[$key]}"
  local file="${entry%%|*}"
  local rest="${entry#*|}"
  local func="${rest%%|*}"
  local label="${rest#*|}"

  local module_path="$SCRIPT_DIR/$file"
  if [[ ! -f "$module_path" ]]; then
    twdx_error "Module file not found: $module_path"
    return 1
  fi

  twdx_section "$label"
  # shellcheck disable=SC1090
  source "$module_path"
  "$func"
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
show_menu() {
  echo ""
  echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BOLD}║        TWDx Linux Maintenance Toolkit v${TWDX_VERSION}            ║${C_RESET}"
  echo -e "${C_BOLD}╠══════════════════════════════════════════════════════════╣${C_RESET}"
  echo -e "${C_BOLD}║                                                          ║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}1)${C_RESET}  System Cleanup                                      ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}      ${C_DIM}Updates, cache/log/tmp cleanup, old kernels, snaps${C_RESET}    ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}                                                          ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}2)${C_RESET}  Health Monitor                                      ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}      ${C_DIM}Disk, memory, CPU, SMART, zombies, failed services${C_RESET}   ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}                                                          ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}3)${C_RESET}  Performance Tuning                                  ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}      ${C_DIM}Swappiness, I/O scheduler, boot time, sysctl${C_RESET}         ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}                                                          ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}4)${C_RESET}  Network Audit                                      ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}      ${C_DIM}Open ports, firewall, SSH attempts, connections${C_RESET}      ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}                                                          ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}5)${C_RESET}  Backup & Recovery                                   ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}      ${C_DIM}Config backup, package list, cron export, restore${C_RESET}    ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}                                                          ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}6)${C_RESET}  User & Permission Audit                             ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}      ${C_DIM}Accounts, sudo, SSH keys, SUID, world-writable${C_RESET}      ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}                                                          ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}A)${C_RESET}  Run All Modules                                     ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}Q)${C_RESET}  Quit                                                ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}║                                                          ║${C_RESET}"
  echo -e "${C_BOLD}║${C_RESET}  Mode: $([[ $TWDX_APPLY -eq 1 ]] && echo -e "${C_GREEN}APPLY${C_RESET}" || echo -e "${C_YELLOW}DRY-RUN${C_RESET}")  $([[ $TWDX_AGGRESSIVE -eq 1 ]] && echo -e "| ${C_RED}AGGRESSIVE${C_RESET}" || echo "")                                    ${C_BOLD}║${C_RESET}"
  echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  echo ""
}

menu_to_module() {
  case "$1" in
    1) echo "cleanup" ;;
    2) echo "health" ;;
    3) echo "performance" ;;
    4) echo "network" ;;
    5) echo "backup" ;;
    6) echo "user-audit" ;;
    *) echo "" ;;
  esac
}

interactive_menu() {
  while true; do
    show_menu
    read -r -p "Select an option: " choice
    case "$choice" in
      [1-6])
        local mod
        mod=$(menu_to_module "$choice")
        run_module "$mod"
        echo ""
        read -r -p "Press Enter to return to menu..."
        ;;
      [Aa])
        for mod in "${MODULE_ORDER[@]}"; do
          run_module "$mod"
        done
        twdx_summary
        echo ""
        read -r -p "Press Enter to return to menu..."
        ;;
      [Qq])
        twdx_log "Exiting. Full log: $TWDX_LOG_FILE"
        exit 0
        ;;
      *)
        echo -e "${C_RED}Invalid option. Please select 1-6, A, or Q.${C_RESET}"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
if [[ $TWDX_CRON -eq 1 ]]; then
  # Cron mode: run safe modules only, no interaction
  for mod in "${CRON_MODULES[@]}"; do
    run_module "$mod"
  done
  twdx_summary

  ACTIONS_TAKEN=$(grep -c '^\[ACTION\]' "$TWDX_LOG_FILE" 2>/dev/null || echo 0)
  NOTIF_MSG="twdx-maintain: $ACTIONS_TAKEN action(s). See $TWDX_LOG_FILE"
  echo "$NOTIF_MSG" | systemd-cat -t twdx-maintain -p info 2>/dev/null || true
  if who | grep -q .; then
    wall "$NOTIF_MSG" 2>/dev/null || true
  fi

elif [[ -n "$MODULE" ]]; then
  # Single module mode
  if [[ -z "${MODULES[$MODULE]+_}" ]]; then
    twdx_error "Unknown module: $MODULE"
    twdx_log "Available: ${!MODULES[*]}"
    exit 1
  fi
  run_module "$MODULE"
  twdx_summary

elif [[ $RUN_ALL -eq 1 ]]; then
  # Run all modules
  for mod in "${MODULE_ORDER[@]}"; do
    run_module "$mod"
  done
  twdx_summary

else
  # Interactive menu
  interactive_menu
fi
