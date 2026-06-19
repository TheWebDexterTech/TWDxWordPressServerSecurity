#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# common.sh — Shared library for TWDx Linux Maintenance Toolkit
#
# Sourced by twdx-maintain.sh and individual modules. Provides:
#   - Color/formatting helpers
#   - Logging (file + stdout, with silent/cron mode support)
#   - Confirmation prompts (interactive + auto-confirm for cron)
#   - Root check
#   - OS/distro detection
#   - Shared globals
#
# Usage: source this file, do not execute directly.

# Guard against direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This file is a library — source it, don't execute it." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Colors (disabled if stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'
  C_CYAN='\033[0;36m'
  C_DIM='\033[2m'
else
  C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_DIM=''
fi

# ---------------------------------------------------------------------------
# Globals (can be overridden before sourcing)
# ---------------------------------------------------------------------------
TWDX_VERSION="1.0.0"
TWDX_LOG_DIR="${TWDX_LOG_DIR:-/var/log/twdx-maintain}"
TWDX_LOG_FILE="${TWDX_LOG_FILE:-$TWDX_LOG_DIR/twdx-maintain-$(date +%Y%m%d-%H%M%S).log}"
TWDX_APPLY="${TWDX_APPLY:-0}"
TWDX_AGGRESSIVE="${TWDX_AGGRESSIVE:-0}"
TWDX_CRON="${TWDX_CRON:-0}"
TWDX_SILENT="${TWDX_SILENT:-0}"
TWDX_ACTIONS_TAKEN="${TWDX_ACTIONS_TAKEN:-0}"

# OS detection results (populated by detect_os)
TWDX_OS_ID=""
TWDX_OS_VERSION=""
TWDX_OS_PRETTY=""
TWDX_ARCH=""
TWDX_PKG_MANAGER=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
twdx_log() {
  if [[ $TWDX_SILENT -eq 1 ]]; then
    echo -e "$@" >> "$TWDX_LOG_FILE"
  else
    echo -e "$@" | tee -a "$TWDX_LOG_FILE"
  fi
}

twdx_info()    { twdx_log "${C_BLUE}[info]${C_RESET}    $*"; }
twdx_success() { twdx_log "${C_GREEN}[ok]${C_RESET}      $*"; }
twdx_warn()    { twdx_log "${C_YELLOW}[warn]${C_RESET}    $*"; }
twdx_error()   { twdx_log "${C_RED}[error]${C_RESET}   $*"; }
twdx_dry_run() { twdx_log "${C_YELLOW}[dry-run]${C_RESET} $*"; }

twdx_action() {
  TWDX_ACTIONS_TAKEN=$((TWDX_ACTIONS_TAKEN + 1))
  echo -e "${C_GREEN}[ACTION]${C_RESET}  $*" | tee -a "$TWDX_LOG_FILE"
}

twdx_section() {
  if [[ $TWDX_SILENT -eq 0 ]]; then
    twdx_log ""
    twdx_log "${C_BOLD}════════════════════════════════════════════════════════${C_RESET}"
    twdx_log "${C_BOLD}  $1${C_RESET}"
    twdx_log "${C_BOLD}════════════════════════════════════════════════════════${C_RESET}"
  else
    twdx_log "\n--- $1 ---"
  fi
}

twdx_subsection() {
  twdx_log "\n${C_CYAN}── $1 ──${C_RESET}"
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
twdx_confirm() {
  local prompt="$1"
  if [[ $TWDX_CRON -eq 1 ]]; then
    if [[ "${CONFIRM_SAFE:-0}" -eq 1 ]]; then
      twdx_log "$prompt -> auto-yes"
      return 0
    else
      twdx_log "$prompt -> skipped (interactive, not run in cron)"
      return 1
    fi
  fi
  echo -en "${C_YELLOW}$prompt${C_RESET} [y/N]: "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
twdx_require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}This tool must be run as root (use sudo).${C_RESET}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
twdx_detect_os() {
  TWDX_ARCH=$(uname -m)

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    TWDX_OS_ID="${ID:-unknown}"
    TWDX_OS_VERSION="${VERSION_ID:-unknown}"
    TWDX_OS_PRETTY="${PRETTY_NAME:-unknown}"
  fi

  if command -v apt-get &>/dev/null; then
    TWDX_PKG_MANAGER="apt"
  elif command -v dnf &>/dev/null; then
    TWDX_PKG_MANAGER="dnf"
  elif command -v yum &>/dev/null; then
    TWDX_PKG_MANAGER="yum"
  elif command -v pacman &>/dev/null; then
    TWDX_PKG_MANAGER="pacman"
  elif command -v zypper &>/dev/null; then
    TWDX_PKG_MANAGER="zypper"
  else
    TWDX_PKG_MANAGER="unknown"
  fi
}

# ---------------------------------------------------------------------------
# Init (call once from launcher or standalone module)
# ---------------------------------------------------------------------------
twdx_init() {
  mkdir -p "$TWDX_LOG_DIR"
  find "$TWDX_LOG_DIR" -type f -name 'twdx-maintain-*.log' -mtime +90 -delete 2>/dev/null || true
  twdx_detect_os
  twdx_log "TWDx Linux Maintenance Toolkit v${TWDX_VERSION}"
  twdx_log "Log: $TWDX_LOG_FILE"
  twdx_log "OS: $TWDX_OS_PRETTY ($TWDX_ARCH) | Pkg: $TWDX_PKG_MANAGER"
  twdx_log "Mode: $([[ $TWDX_APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
}

# ---------------------------------------------------------------------------
# Summary helper
# ---------------------------------------------------------------------------
twdx_summary() {
  twdx_section "Summary"
  twdx_log "Mode: $([[ $TWDX_APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
  twdx_log "Actions taken: $TWDX_ACTIONS_TAKEN"
  twdx_log "Full log: $TWDX_LOG_FILE"
}
