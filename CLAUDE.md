# TWDxWordPressServerSecurity — Claude Context

Hands-off maintenance toolkit for headless WordPress on Ubuntu 24.04. Shell scripts only. No build system, no package manager, no compiled code.

---

## File Map

| File | Purpose | Key vars / functions |
|---|---|---|
| `install.sh` | Main installer (idempotent, interactive + headless) | `WP_PATH` `WP_USER` `REBOOT_TIME` `LOG_FILE` `CRON_SCHEDULE` `ENABLE_CLEANUP` `ADMIN_EMAIL` `DRY_RUN`; `fetch_verified()` `validate_cron_schedule()` `validate_integer_range()` `validate_wp_path()` `validate_wp_user()` `validate_reboot_time()` `validate_log_path()` |
| `uninstall.sh` | Full teardown + optional rollback of SSH/UFW/sysctl | — |
| `scripts/harden.sh` | Standalone OS hardening (SSH/sysctl/UFW) | `SSH_PORT` `ENABLE_UFW` `OPEN_HTTP` `OPEN_HTTPS` `DRY_RUN`; `set_sshd_option()` `validate_port()` `validate_bool()` |
| `scripts/wp-auto-update.sh.tpl` | WP update cron script (template) | Placeholders: `__WP_PATH__` `__WP_USER__` `__LOG_FILE__` |
| `configs/50unattended-upgrades` | APT upgrade policy (allowed origins, auto-reboot at 03:00) | — |
| `configs/20auto-upgrades` | APT periodic trigger intervals | — |
| `configs/auto-reboot.service` | systemd oneshot: reboots when `/var/run/reboot-required` exists | — |
| `configs/auto-reboot.timer.tpl` | systemd timer template | Placeholder: `__REBOOT_TIME__` |
| `configs/needrestart.conf` | needrestart: auto-restart services (`$nrconf{restart} = 'a'`), suppress prompts | — |
| `cleanup.sh` | Empty placeholder — not yet implemented | — |
| `.github/workflows/shellcheck.yml` | CI: ShellCheck on all `.sh` files; `configs/` excluded from scan | — |
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
  ├── fetch_verified() → scripts/wp-auto-update.sh.tpl   → /usr/local/bin/wp-auto-update.sh
  │     (sed: __WP_PATH__, __WP_USER__, __LOG_FILE__)
  ├── inline heredoc   → /usr/local/bin/vm-system-cleanup.sh  (when ENABLE_CLEANUP=true)
  ├── inline heredoc   → /etc/logrotate.d/twdxwpss
  └── generated        → /etc/cron.d/twdxwpss

scripts/harden.sh   — standalone, no dependency on install.sh
  ├── modifies  → /etc/ssh/sshd_config (backup to .bak first)
  ├── generates → /etc/sysctl.d/99-twdxwpss-hardening.conf
  └── configures UFW rules

uninstall.sh        — standalone, reverses install.sh and optionally harden.sh
  ├── removes   → /etc/cron.d/twdxwpss
  ├── removes   → /etc/systemd/system/auto-reboot.{service,timer}
  ├── removes   → /usr/local/bin/wp-auto-update.sh + vm-system-cleanup.sh
  ├── removes   → /etc/logrotate.d/twdxwpss
  ├── removes   → /etc/sysctl.d/99-twdxwpss-hardening.conf (if present)
  └── optionally restores /etc/ssh/sshd_config.bak, disables UFW
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
| Checksum registry | `declare -A FILE_CHECKSUMS` at line 56 of `install.sh`. **Update all entries when any `configs/` or `scripts/*.tpl` file changes** |
| Cron placement | Jobs go to `/etc/cron.d/twdxwpss` (not root crontab) |
| Log permissions | Created with `install -m 640 -o root -g adm` — not world-readable |

---

## What NOT to Read for Typical Tasks

| File | Skip when... |
|---|---|
| `README.md` | Any code task — it's user docs, not implementation detail |
| `cleanup.sh` | Always — it is empty |
| `LICENSE` | Always — MIT boilerplate |
| `configs/needrestart.conf` | Unless the question is specifically about needrestart policy |
| `.github/workflows/shellcheck.yml` | Unless the question involves CI or adding new shell files |
