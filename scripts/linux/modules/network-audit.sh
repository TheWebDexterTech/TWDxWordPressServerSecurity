#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
#
# network-audit.sh — Network security auditing module for TWDx Linux Maintenance Toolkit
#
# Checks: listening ports, active connections, firewall status, DNS config,
#         network interfaces, open-port comparison, failed SSH attempts,
#         established foreign connections.
#
# Usage:
#   source this file from the launcher, or run standalone:
#     sudo ./network-audit.sh              # dry-run / report only
#     sudo ./network-audit.sh --apply      # same (audit is read-only by nature)
#     sudo ./network-audit.sh --cron       # silent mode, log only
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Known / expected listening services (port -> description)
# Extend this list for your environment.
# ---------------------------------------------------------------------------
declare -A EXPECTED_PORTS=(
  [22]="SSH"
  [80]="HTTP"
  [443]="HTTPS"
)

# Ports commonly used by legitimate services but worth noting
declare -A KNOWN_PORTS=(
  [25]="SMTP"
  [53]="DNS"
  [3306]="MySQL"
  [5432]="PostgreSQL"
  [6379]="Redis"
  [8080]="HTTP-alt"
  [8443]="HTTPS-alt"
  [9090]="Cockpit/Prometheus"
  [11211]="Memcached"
  [27017]="MongoDB"
)

# ---------------------------------------------------------------------------
# Standalone entrypoint
# ---------------------------------------------------------------------------
_network_audit_main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # shellcheck source=../lib/common.sh
  source "${script_dir}/../lib/common.sh"

  for arg in "$@"; do
    case "$arg" in
      --apply)     TWDX_APPLY=1 ;;
      --cron)
        TWDX_APPLY=1
        TWDX_CRON=1
        TWDX_SILENT=1
        ;;
      -h|--help)
        echo "Usage: $0 [--apply] [--cron]"
        echo "  --apply   Run in apply mode (audit is read-only regardless)"
        echo "  --cron    Silent/log-only mode for scheduled runs"
        exit 0
        ;;
    esac
  done

  twdx_require_root
  twdx_init
  run_network_audit
  twdx_summary
}

# ---------------------------------------------------------------------------
# Main audit function
# ---------------------------------------------------------------------------
run_network_audit() {
  twdx_section "Network Security Audit"

  _audit_listening_ports
  _audit_active_connections
  _audit_firewall_status
  _audit_dns_configuration
  _audit_network_interfaces
  _audit_open_ports_comparison
  _audit_failed_ssh_attempts
  _audit_foreign_connections
}

# ---------------------------------------------------------------------------
# 1. Listening Ports
# ---------------------------------------------------------------------------
_audit_listening_ports() {
  twdx_subsection "Listening Ports"

  if ! command -v ss &>/dev/null; then
    twdx_warn "ss not found — skipping listening-port check"
    return
  fi

  local output
  output=$(ss -tulpn 2>/dev/null) || true
  twdx_info "Current listening sockets:"
  twdx_log "$output"

  # Parse listening ports and flag unexpected ones
  local port proto process flagged=0
  while IFS= read -r line; do
    # Extract port from the local address column (4th field, after last ':')
    port=$(echo "$line" | awk '{print $5}' | grep -oE '[0-9]+$' || true)
    proto=$(echo "$line" | awk '{print $1}')
    process=$(echo "$line" | awk '{print $NF}')

    [[ -z "$port" ]] && continue

    if [[ -z "${EXPECTED_PORTS[$port]:-}" ]]; then
      local desc="${KNOWN_PORTS[$port]:-unknown service}"
      twdx_warn "Unexpected listener: port ${port}/${proto} (${desc}) — ${process}"
      flagged=1
    fi
  done < <(echo "$output" | tail -n +2 | grep -i 'LISTEN')

  if [[ $flagged -eq 0 ]]; then
    twdx_success "All listening ports match expected services (SSH/HTTP/HTTPS)"
  fi
}

# ---------------------------------------------------------------------------
# 2. Active Connections
# ---------------------------------------------------------------------------
_audit_active_connections() {
  twdx_subsection "Active Connections"

  if ! command -v ss &>/dev/null; then
    twdx_warn "ss not found — skipping active-connection check"
    return
  fi

  local output count
  output=$(ss -tunp state established 2>/dev/null) || true
  count=$(echo "$output" | tail -n +2 | grep -c . || echo 0)
  twdx_info "Established connections: ${count}"

  if [[ "$count" -gt 0 ]]; then
    twdx_log "$output"
  fi

  # Flag connections to unusual remote ports
  local remote_port flagged=0
  while IFS= read -r line; do
    remote_port=$(echo "$line" | awk '{print $5}' | grep -oE '[0-9]+$' || true)
    [[ -z "$remote_port" ]] && continue

    # Skip common outbound destination ports
    case "$remote_port" in
      22|25|53|80|123|443|587|993|995|8080|8443) continue ;;
    esac

    # Skip ephemeral range as source (32768-60999 on Linux)
    if [[ "$remote_port" -ge 32768 && "$remote_port" -le 60999 ]]; then
      continue
    fi

    twdx_warn "Connection to unusual remote port ${remote_port}: ${line}"
    flagged=1
  done < <(echo "$output" | tail -n +2 | grep -v '^$')

  if [[ $flagged -eq 0 && "$count" -gt 0 ]]; then
    twdx_success "No connections to unusual remote ports detected"
  fi
}

# ---------------------------------------------------------------------------
# 3. Firewall Status
# ---------------------------------------------------------------------------
_audit_firewall_status() {
  twdx_subsection "Firewall Status"

  local fw_found=0

  # Check UFW first
  if command -v ufw &>/dev/null; then
    fw_found=1
    local ufw_output
    ufw_output=$(ufw status verbose 2>/dev/null) || true
    twdx_info "UFW status:"
    twdx_log "$ufw_output"

    if echo "$ufw_output" | grep -qi 'Status: active'; then
      twdx_success "UFW firewall is active"
    else
      twdx_warn "UFW is installed but NOT active — system may be unprotected"
    fi
  fi

  # Fall back to iptables if no UFW
  if [[ $fw_found -eq 0 ]]; then
    if command -v iptables &>/dev/null; then
      fw_found=1
      local ipt_output rule_count
      ipt_output=$(iptables -L -n 2>/dev/null) || true
      rule_count=$(echo "$ipt_output" | grep -cvE '^(Chain |target |$)' || echo 0)
      twdx_info "iptables rules (no UFW detected):"
      twdx_log "$ipt_output"

      if [[ "$rule_count" -gt 0 ]]; then
        twdx_info "iptables has ${rule_count} rule(s) configured"
      else
        twdx_warn "iptables has no custom rules — system may be unprotected"
      fi
    fi
  fi

  # Check nftables as well
  if command -v nft &>/dev/null; then
    local nft_output
    nft_output=$(nft list ruleset 2>/dev/null) || true
    if [[ -n "$nft_output" ]]; then
      twdx_info "nftables ruleset detected ($(echo "$nft_output" | grep -c 'rule' || echo 0) rules)"
    fi
  fi

  if [[ $fw_found -eq 0 ]]; then
    twdx_warn "No firewall (UFW or iptables) found — system is likely unprotected"
  fi
}

# ---------------------------------------------------------------------------
# 4. DNS Configuration
# ---------------------------------------------------------------------------
_audit_dns_configuration() {
  twdx_subsection "DNS Configuration"

  # Show resolv.conf
  if [[ -f /etc/resolv.conf ]]; then
    twdx_info "Contents of /etc/resolv.conf:"
    twdx_log "$(cat /etc/resolv.conf)"

    # Check for plaintext DNS (port 53 is unencrypted by default)
    local nameservers
    nameservers=$(grep -E '^\s*nameserver\s+' /etc/resolv.conf | awk '{print $2}')
    if [[ -n "$nameservers" ]]; then
      twdx_info "Configured nameservers: $(echo "$nameservers" | tr '\n' ' ')"
      twdx_warn "DNS queries are likely sent in plaintext (standard port 53) — consider DNS-over-TLS or DNS-over-HTTPS"
    fi
  else
    twdx_warn "/etc/resolv.conf not found"
  fi

  # Check systemd-resolved
  if systemctl is-active systemd-resolved &>/dev/null; then
    twdx_info "systemd-resolved is running"
    if command -v resolvectl &>/dev/null; then
      local resolved_status
      resolved_status=$(resolvectl status 2>/dev/null | head -n 20) || true
      twdx_log "$resolved_status"

      # Check if DNS-over-TLS is enabled
      if echo "$resolved_status" | grep -qi 'DNSOverTLS.*yes\|DNSOverTLS.*opportunistic'; then
        twdx_success "DNS-over-TLS is enabled via systemd-resolved"
      else
        twdx_warn "DNS-over-TLS is not enabled in systemd-resolved"
      fi
    fi
  else
    twdx_info "systemd-resolved is not running — DNS handled by /etc/resolv.conf directly"
  fi
}

# ---------------------------------------------------------------------------
# 5. Network Interfaces
# ---------------------------------------------------------------------------
_audit_network_interfaces() {
  twdx_subsection "Network Interfaces"

  if ! command -v ip &>/dev/null; then
    twdx_warn "ip command not found — skipping interface check"
    return
  fi

  local output
  output=$(ip addr show 2>/dev/null) || true
  twdx_info "Network interfaces:"
  twdx_log "$output"

  # Check for promiscuous mode
  local promisc_ifaces
  promisc_ifaces=$(ip link show 2>/dev/null | grep -i 'PROMISC' | awk -F: '{print $2}' | tr -d ' ') || true

  if [[ -n "$promisc_ifaces" ]]; then
    while IFS= read -r iface; do
      [[ -z "$iface" ]] && continue
      twdx_warn "Interface ${iface} is in PROMISCUOUS mode — possible packet sniffing"
    done <<< "$promisc_ifaces"
  else
    twdx_success "No interfaces in promiscuous mode"
  fi
}

# ---------------------------------------------------------------------------
# 6. Open Ports Comparison
# ---------------------------------------------------------------------------
_audit_open_ports_comparison() {
  twdx_subsection "Open Ports vs Expected Services"

  if ! command -v ss &>/dev/null; then
    twdx_warn "ss not found — skipping port comparison"
    return
  fi

  local listening_ports
  listening_ports=$(ss -tulpn 2>/dev/null | tail -n +2 | grep -i 'LISTEN' \
    | awk '{print $5}' | grep -oE '[0-9]+$' | sort -un) || true

  if [[ -z "$listening_ports" ]]; then
    twdx_info "No listening ports detected"
    return
  fi

  twdx_info "Port comparison summary:"

  local unknown_count=0
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    if [[ -n "${EXPECTED_PORTS[$port]:-}" ]]; then
      twdx_success "Port ${port} — ${EXPECTED_PORTS[$port]} (expected)"
    elif [[ -n "${KNOWN_PORTS[$port]:-}" ]]; then
      twdx_info "Port ${port} — ${KNOWN_PORTS[$port]} (known service, verify if needed)"
    else
      twdx_warn "Port ${port} — UNKNOWN service (investigate)"
      unknown_count=$((unknown_count + 1))
    fi
  done <<< "$listening_ports"

  if [[ $unknown_count -eq 0 ]]; then
    twdx_success "All open ports map to known services"
  else
    twdx_warn "${unknown_count} unknown port(s) detected — review recommended"
  fi
}

# ---------------------------------------------------------------------------
# 7. Failed SSH Attempts (last 24 hours)
# ---------------------------------------------------------------------------
_audit_failed_ssh_attempts() {
  twdx_subsection "Failed SSH Login Attempts (last 24h)"

  local fail_count=0 top_ips=""

  # Try journalctl first (systemd systems)
  if command -v journalctl &>/dev/null; then
    fail_count=$(journalctl _SYSTEMD_UNIT=sshd.service --since "24 hours ago" --no-pager 2>/dev/null \
      | grep -ciE 'failed password|invalid user|authentication failure' || echo 0)

    top_ips=$(journalctl _SYSTEMD_UNIT=sshd.service --since "24 hours ago" --no-pager 2>/dev/null \
      | grep -iE 'failed password|invalid user' \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | sort | uniq -c | sort -rn | head -n 5) || true

  # Fall back to auth.log
  elif [[ -f /var/log/auth.log ]]; then
    local since_ts
    since_ts=$(date -d '24 hours ago' '+%b %e' 2>/dev/null) || since_ts=""

    if [[ -n "$since_ts" ]]; then
      fail_count=$(grep -cE 'sshd.*(Failed password|Invalid user|authentication failure)' /var/log/auth.log 2>/dev/null || echo 0)
    else
      fail_count=$(grep -cE 'sshd.*(Failed password|Invalid user|authentication failure)' /var/log/auth.log 2>/dev/null || echo 0)
    fi

    top_ips=$(grep -E 'sshd.*(Failed password|Invalid user)' /var/log/auth.log 2>/dev/null \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | sort | uniq -c | sort -rn | head -n 5) || true
  else
    twdx_warn "Neither journalctl nor /var/log/auth.log available — cannot check SSH failures"
    return
  fi

  twdx_info "Failed SSH login attempts (last 24h): ${fail_count}"

  if [[ "$fail_count" -gt 100 ]]; then
    twdx_warn "High number of failed SSH attempts (${fail_count}) — possible brute-force attack"
  elif [[ "$fail_count" -gt 0 ]]; then
    twdx_info "Some failed SSH attempts detected — review source IPs below"
  else
    twdx_success "No failed SSH login attempts in the last 24 hours"
  fi

  if [[ -n "$top_ips" ]]; then
    twdx_info "Top 5 source IPs for failed SSH attempts:"
    twdx_log "$top_ips"
  fi
}

# ---------------------------------------------------------------------------
# 8. Established Foreign Connections
# ---------------------------------------------------------------------------
_audit_foreign_connections() {
  twdx_subsection "Established Foreign Connections"

  if ! command -v ss &>/dev/null; then
    twdx_warn "ss not found — skipping foreign connection check"
    return
  fi

  local remote_ips
  remote_ips=$(ss -tunp state established 2>/dev/null \
    | tail -n +2 \
    | awk '{print $5}' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
    | sort -u) || true

  if [[ -z "$remote_ips" ]]; then
    twdx_info "No established connections to non-private remote IPs"
    return
  fi

  local ip_count
  ip_count=$(echo "$remote_ips" | grep -c . || echo 0)
  twdx_info "Unique non-private remote IPs with established connections: ${ip_count}"
  twdx_log "$remote_ips"

  if [[ "$ip_count" -gt 20 ]]; then
    twdx_warn "Large number of unique remote connections (${ip_count}) — review recommended"
  fi
}

# ---------------------------------------------------------------------------
# Run standalone if not sourced
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _network_audit_main "$@"
fi
