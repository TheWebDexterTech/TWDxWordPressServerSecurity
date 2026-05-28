# TWDxWordPressServerSecurity — Claude Context

Hands-off maintenance toolkit for headless WordPress on Ubuntu 24.04. Shell scripts only. No build system, no package manager, no compiled code.

---

## File Map

| File | Purpose | Key vars / functions |
|---|---|---|
| `install.sh` | Main installer (idempotent, interactive + headless) | `WP_PATH` `WP_USER` `REBOOT_TIME` `LOG_FILE` `CRON_SCHEDULE` `ENABLE_CLEANUP` `ADMIN_EMAIL` `DRY_RUN`; `fetch_verified()` `show_help()` `validate_cron_schedule()` `validate_integer_range()` `validate_wp_path()` `validate_wp_user()` `validate_reboot_time()` `validate_log_path()` |
| `uninstall.sh` | Full teardown + optional rollback of SSH/UFW/sysctl; removes new SSH drop-in and `fail2ban` jail.local | — |
| `scripts/harden.sh` | Standalone OS hardening — SSH (drop-in at `/etc/ssh/sshd_config.d/99-twdxwpss-hardening.conf`), expanded sysctl, UFW | `SSH_PORT` `ENABLE_UFW` `OPEN_HTTP` `OPEN_HTTPS` `DRY_RUN`; `show_help()` `validate_port()` `validate_bool()` |
| `scripts/wp-auto-update.sh.tpl` | WP update cron script (template) — uses `flock`, per-step error capture, exits with failure count | Placeholders: `__WP_PATH__` `__WP_USER__` `__LOG_FILE__` |
| `configs/50unattended-upgrades` | APT upgrade policy (origins inc. ESM, MailReport, Acquire retries, auto-reboot 03:00) | — |
| `configs/20auto-upgrades` | APT periodic trigger intervals | — |
| `configs/auto-reboot.service` | systemd oneshot: reboots when `/var/run/reboot-required` exists | — |
| `configs/auto-reboot.timer.tpl` | systemd timer template | Placeholder: `__REBOOT_TIME__` |
| `configs/needrestart.conf` | needrestart: auto-restart services (`$nrconf{restart} = 'a'`), suppress prompts | — |
| `configs/fail2ban-jail.local` | fail2ban jail: `sshd` aggressive + `recidive` long-ban; exponential bantime; nftables backend | — |
| `.github/workflows/shellcheck.yml` | CI: ShellCheck on all `.sh`, gcc format, `style` severity; `configs/` excluded; least-privilege `contents: read` | — |
| `README.md` | User-facing docs (install, variables, logs, uninstall) | — |

---

## Dependency Graph

```
install.sh
  ├── fetch_verified() → configs/50unattended-upgrades  → /etc/apt/apt.conf.d/50unattended-upgrades
  ├── fetch_verified() → configs/20auto-upgrades         → /etc/apt/apt.conf.d/20auto-upgrades
  ├── fetch_verified() → configs/needrestart.conf        → /etc/needrestart/needrestart.conf
  ├── fetch_verified() → configs/auto-reboot.service     → /etc/systemd/system/auto-reboot.service
  ├── fetch_verified() → configs/auto-reboot.timer.tpl   → /etc/systemd/system/auto-reboot.timer
  │     (sed: __REBOOT_TIME__ → $REBOOT_TIME)
  ├── fetch_verified() → configs/fail2ban-jail.local     → /etc/fail2ban/jail.local
  ├── fetch_verified() → scripts/wp-auto-update.sh.tpl   → /usr/local/bin/wp-auto-update.sh
  │     (sed: __WP_PATH__, __WP_USER__, __LOG_FILE__)
  ├── inline heredoc   → /usr/local/bin/vm-system-cleanup.sh  (when ENABLE_CLEANUP=true)
  ├── inline heredoc   → /etc/logrotate.d/twdxwpss
  └── generated        → /etc/cron.d/twdxwpss

scripts/harden.sh   — standalone, no dependency on install.sh
  ├── generates → /etc/ssh/sshd_config.d/99-twdxwpss-hardening.conf (drop-in)
  ├── generates → /etc/sysctl.d/99-twdxwpss-hardening.conf
  └── configures UFW rules (IPv6 explicit, low logging)

uninstall.sh        — standalone, reverses install.sh and optionally harden.sh
  ├── removes   → /etc/cron.d/twdxwpss
  ├── removes   → /etc/systemd/system/auto-reboot.{service,timer}
  ├── removes   → /usr/local/bin/wp-auto-update.sh + vm-system-cleanup.sh
  ├── removes   → /var/lock/wp-auto-update.lock
  ├── removes   → /etc/logrotate.d/twdxwpss
  ├── removes   → /etc/fail2ban/jail.local (prompt)
  ├── removes   → /etc/sysctl.d/99-twdxwpss-hardening.conf (if present)
  ├── removes   → /etc/ssh/sshd_config.d/99-twdxwpss-hardening.conf (if present)
  └── optionally restores /etc/ssh/sshd_config.bak (legacy installs), disables UFW
```

---

## Conventions

| Convention | Detail |
|---|---|
| Dry-run pattern | `DRY_RUN="${DRY_RUN:-false}"`. Flag: `--dry-run`. Every side-effecting command guarded by `if [[ "$DRY_RUN" == "true" ]]; then dry_run "..."; else <real command>; fi` |
| Idempotency | `install.sh` and `harden.sh` are both safe to re-run |
| Template placeholders | `__VAR_NAME__` format, substituted by `sed -e "s|__VAR__|${VAR}|g"`. Inputs validated by `validate_*()` before sed |
| Colour / logging | `info` (blue) / `success` (green) / `warn` (yellow) / `error` (red+exit) / `step` (bold) / `dry_run` (yellow) — same set in every script |
| ShellCheck | CI runs on all `.sh` files; `configs/` excluded (not shell scripts). Use `# shellcheck disable=SCXXXX` inline for known false-positives |
| Checksum registry | `declare -A FILE_CHECKSUMS` near top of `install.sh` (around line 84). **Update all entries when any `configs/` or `scripts/*.tpl` file changes** — recompute with `sha256sum <file>` |
| Cron placement | Jobs go to `/etc/cron.d/twdxwpss` (not root crontab) |
| Log permissions | Created with `install -m 640 -o root -g adm` — not world-readable |

---

## What NOT to Read for Typical Tasks

| File | Skip when... |
|---|---|
| `README.md` | Any code task — it's user docs, not implementation detail |
| `LICENSE` | Always — MIT boilerplate |
| `configs/needrestart.conf` | Unless the question is specifically about needrestart policy |
| `.github/workflows/shellcheck.yml` | Unless the question involves CI or adding new shell files |
