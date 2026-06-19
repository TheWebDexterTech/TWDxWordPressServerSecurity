#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# user-audit.sh — User & Permission Audit module for TWDx Linux Maintenance Toolkit
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_user_audit() {
  # --- 1. Human user accounts ---
  twdx_subsection "User Accounts (UID >= 1000)"
  local user_count=0
  local never_logged=()

  while IFS=: read -r username _ uid _ _ home shell; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    user_count=$((user_count + 1))

    local last_login
    last_login=$(lastlog -u "$username" 2>/dev/null | tail -n1)
    if echo "$last_login" | grep -q "Never logged in"; then
      twdx_warn "  $username (UID $uid) — never logged in"
      never_logged+=("$username")
    else
      local login_date
      login_date=$(echo "$last_login" | awk '{print $4, $5, $6, $7, $8, $9}')
      twdx_info "  $username (UID $uid) — last login: $login_date"
    fi
  done < /etc/passwd

  twdx_info "Total human accounts: $user_count"

  if [[ ${#never_logged[@]} -gt 0 && $TWDX_APPLY -eq 1 && $TWDX_CRON -eq 0 ]]; then
    for user in "${never_logged[@]}"; do
      if twdx_confirm "Lock account '$user' (never logged in)?"; then
        usermod -L "$user" 2>/dev/null && twdx_action "Locked unused account: $user"
      fi
    done
  fi

  # --- 2. Root / sudo access ---
  twdx_subsection "Root & Sudo Access"
  twdx_info "Users in sudo group:"
  getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' '\n' | sed 's/^/    /' | tee -a "$TWDX_LOG_FILE"
  getent group wheel 2>/dev/null | cut -d: -f4 | tr ',' '\n' | sed 's/^/    /' | tee -a "$TWDX_LOG_FILE"

  twdx_info "NOPASSWD entries in sudoers:"
  local nopasswd_count=0
  for f in /etc/sudoers /etc/sudoers.d/*; do
    [[ -f "$f" ]] || continue
    local matches
    matches=$(grep -n 'NOPASSWD' "$f" 2>/dev/null | grep -v '^#' || true)
    if [[ -n "$matches" ]]; then
      twdx_warn "  $f:"
      echo "$matches" | sed 's/^/      /' | tee -a "$TWDX_LOG_FILE"
      nopasswd_count=$((nopasswd_count + 1))
    fi
  done
  [[ $nopasswd_count -eq 0 ]] && twdx_success "  No NOPASSWD entries found"

  # --- 3. Password policy ---
  twdx_subsection "Password Policy"
  if [[ -f /etc/login.defs ]]; then
    local pass_max pass_min pass_warn
    pass_max=$(grep -E '^PASS_MAX_DAYS' /etc/login.defs | awk '{print $2}')
    pass_min=$(grep -E '^PASS_MIN_DAYS' /etc/login.defs | awk '{print $2}')
    pass_warn=$(grep -E '^PASS_WARN_AGE' /etc/login.defs | awk '{print $2}')
    twdx_info "  PASS_MAX_DAYS: ${pass_max:-unset} (recommend: 90)"
    twdx_info "  PASS_MIN_DAYS: ${pass_min:-unset} (recommend: 1)"
    twdx_info "  PASS_WARN_AGE: ${pass_warn:-unset} (recommend: 14)"

    [[ "${pass_max:-99999}" -gt 365 ]] && twdx_warn "  PASS_MAX_DAYS is very high or unlimited"
  fi

  twdx_info "Checking for empty passwords..."
  local empty_pw=0
  while IFS=: read -r username pw _; do
    if [[ "$pw" == "" || "$pw" == "!" || "$pw" == "!!" || "$pw" == "*" ]]; then
      continue
    fi
    # An empty second field means no password set
  done < /etc/shadow 2>/dev/null
  # Alternative: check for accounts with no password hash
  local no_pw_users
  no_pw_users=$(awk -F: '($2 == "" ) {print $1}' /etc/shadow 2>/dev/null || true)
  if [[ -n "$no_pw_users" ]]; then
    twdx_warn "  Accounts with EMPTY passwords:"
    echo "$no_pw_users" | sed 's/^/      /' | tee -a "$TWDX_LOG_FILE"
    empty_pw=1
  fi
  [[ $empty_pw -eq 0 ]] && twdx_success "  No empty passwords found"

  # --- 4. SSH authorized keys ---
  twdx_subsection "SSH Authorized Keys"
  while IFS=: read -r username _ uid _ _ home _; do
    [[ "$uid" -lt 1000 && "$username" != "root" ]] && continue
    local keyfile="$home/.ssh/authorized_keys"
    if [[ -f "$keyfile" ]]; then
      local key_count
      key_count=$(grep -c -E '^(ssh-|ecdsa-)' "$keyfile" 2>/dev/null || echo 0)
      if [[ "$key_count" -gt 0 ]]; then
        twdx_info "  $username: $key_count key(s) in $keyfile"
      fi
    fi
  done < /etc/passwd

  # root keys
  if [[ -f /root/.ssh/authorized_keys ]]; then
    local root_keys
    root_keys=$(grep -c -E '^(ssh-|ecdsa-)' /root/.ssh/authorized_keys 2>/dev/null || echo 0)
    [[ "$root_keys" -gt 0 ]] && twdx_warn "  root has $root_keys authorized key(s) — consider disabling direct root SSH"
  fi

  # --- 5. SUID/SGID binaries ---
  twdx_subsection "SUID/SGID Binaries"
  twdx_info "Scanning for SUID/SGID files (this may take a moment)..."

  local known_safe="^/(usr/)?(s)?bin/(su|sudo|mount|umount|ping|passwd|chsh|chfn|newgrp|gpasswd|pkexec|fusermount|fusermount3|unix_chkpwd|at|crontab|ssh-agent|Xorg|wall|write|expiry|chage|dotlockfile)\$"

  local unusual_suid=0
  while IFS= read -r f; do
    local base
    base=$(basename "$f")
    if ! echo "/$base" | grep -qE "$known_safe"; then
      twdx_warn "  Unusual SUID/SGID: $f ($(stat -c '%U:%G %a' "$f" 2>/dev/null))"
      unusual_suid=$((unusual_suid + 1))
    fi
  done < <(find / -path /proc -prune -o -path /sys -prune -o \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null)

  [[ $unusual_suid -eq 0 ]] && twdx_success "  All SUID/SGID binaries match known-safe list"

  # --- 6. World-writable files ---
  twdx_subsection "World-Writable Files"
  twdx_info "Scanning /etc, /usr, /var (excluding /tmp, /proc, /sys)..."
  local ww_count=0
  while IFS= read -r f; do
    twdx_warn "  World-writable: $f"
    ww_count=$((ww_count + 1))
  done < <(find /etc /usr /var -path /var/tmp -prune -o -path /proc -prune -o -path /sys -prune \
           -o -type f -perm -0002 -print 2>/dev/null | head -n 50)

  [[ $ww_count -eq 0 ]] && twdx_success "  No world-writable files found in /etc, /usr, /var"
  [[ $ww_count -ge 50 ]] && twdx_warn "  (showing first 50 — there may be more)"

  # --- 7. Unowned files ---
  twdx_subsection "Unowned Files"
  local unowned_count=0
  while IFS= read -r f; do
    twdx_warn "  No valid owner: $f"
    unowned_count=$((unowned_count + 1))
  done < <(find /etc /usr /var -path /proc -prune -o -path /sys -prune -o \( -nouser -o -nogroup \) -print 2>/dev/null | head -n 30)

  [[ $unowned_count -eq 0 ]] && twdx_success "  No unowned files found"

  # --- 8. Home directory permissions ---
  twdx_subsection "Home Directory Permissions"
  local bad_home_perms=()
  while IFS=: read -r username _ uid _ _ home _; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ -d "$home" ]] || continue
    local perms
    perms=$(stat -c '%a' "$home" 2>/dev/null || echo "")
    local other="${perms:2:1}"
    if [[ "${other:-0}" -gt 0 ]]; then
      twdx_warn "  $home ($username) — mode $perms (world-accessible)"
      bad_home_perms+=("$home")
    else
      twdx_info "  $home ($username) — mode $perms"
    fi
  done < /etc/passwd

  if [[ ${#bad_home_perms[@]} -gt 0 && $TWDX_APPLY -eq 1 && $TWDX_CRON -eq 0 ]]; then
    if twdx_confirm "Fix home directory permissions (set to 750)?"; then
      for d in "${bad_home_perms[@]}"; do
        chmod 750 "$d" 2>/dev/null && twdx_action "Fixed permissions on $d (750)"
      done
    fi
  fi

  # --- 9. Recent login history ---
  twdx_subsection "Recent Login History"
  twdx_info "Last 10 logins:"
  last -n 10 2>/dev/null | tee -a "$TWDX_LOG_FILE"

  local root_logins
  root_logins=$(last -n 50 2>/dev/null | grep -c '^root ' || echo 0)
  if [[ "$root_logins" -gt 0 ]]; then
    twdx_warn "  $root_logins direct root login(s) in recent history — consider using sudo instead"
  else
    twdx_success "  No direct root logins in recent history"
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
  twdx_section "User & Permission Audit"
  run_user_audit
  twdx_summary
fi
