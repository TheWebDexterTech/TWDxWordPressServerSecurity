# TWDxWordPressServerSecurity — Claude Context

Hands-off maintenance toolkit for headless WordPress on Ubuntu 24.04.
Pure Bash. No build system, no package manager, no compiled code.
Last refreshed: 2026-05-29.

---

## Commit Preflight (workflow rule)

`main` is production — the install one-liner pulls from `raw.githubusercontent.com/.../main/install.sh`. **Before every commit**, run `bash scripts/pre-commit.sh` (or just `git commit` if the hook is symlinked — see below). It runs three checks:

1. **ShellCheck** on `install.sh`, `uninstall.sh`, `scripts/*.sh` (matches CI; `--severity=style --format=gcc`)
2. **`FILE_CHECKSUMS` drift** — every entry at install.sh:84 must match the actual `sha256sum` of the corresponding `configs/*` or `scripts/*.tpl` file
3. **Secret scan** on the staged diff — AWS keys, GitHub tokens, OpenAI keys, PEM private blocks, long `password=` literals

If any check fails: **fix the issue locally, re-run the preflight, then commit.** Never push a failing tree to `main`. When the user asks me to "commit" or "commit and push":

```
preflight  →  pass? commit  →  pass? push
           ↘  fail? fix locally  →  re-run preflight  →  ...
```

**One-time hook install (per clone):**

```bash
ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit
chmod +x scripts/pre-commit.sh
```

After symlinking, the hook fires automatically on `git commit` and blocks the commit if any check fails. The hook is already installed in this working tree.

---

## Repository Layout

```
.
├── install.sh                 # Main installer (idempotent, interactive + headless)
├── uninstall.sh               # Full teardown + optional SSH/UFW/sysctl rollback
├── scripts/
│   ├── harden.sh              # Standalone OS hardening (SSH/sysctl/UFW)
│   ├── pre-commit.sh          # Commit preflight (shellcheck + checksums + secrets)
│   └── wp-auto-update.sh.tpl  # WP update cron script (template)
├── configs/                   # Files fetched + checksum-verified by install.sh
│   ├── 50unattended-upgrades
│   ├── 20auto-upgrades
│   ├── needrestart.conf
│   ├── auto-reboot.service
│   ├── auto-reboot.timer.tpl
│   └── fail2ban-jail.local
├── .github/workflows/shellcheck.yml   # CI: ShellCheck on all *.sh, configs/ excluded
├── .claudeignore              # Tells Claude Code to skip LICENSE / README from index
├── README.md                  # User-facing docs
└── LICENSE                    # MIT
```

---

## File Map (with anchors)

| File | Purpose | Key symbols (line) |
|---|---|---|
| `install.sh` | Main installer | `show_help`(29) · `FILE_CHECKSUMS` array (84) · `validate_cron_schedule`(96) · `validate_integer_range`(104) · `validate_wp_path`(111) · `validate_wp_user`(120) · `validate_reboot_time`(129) · `validate_log_path`(136) · `fetch_verified`(146). Env: `WP_PATH` `WP_USER` `REBOOT_TIME` `LOG_FILE` `CRON_SCHEDULE` `ENABLE_CLEANUP` `ADMIN_EMAIL` `DRY_RUN` |
| `uninstall.sh` | Teardown — removes cron, timer, scripts, logrotate, fail2ban jail, SSH drop-in, sysctl drop-in. Prompts for WP-CLI / UFW removal and legacy `sshd_config.bak` restore | `info`/`success`/`warn`/`error` (12–15) |
| `scripts/harden.sh` | OS hardening | `show_help`(32) · `validate_port`(80) · `validate_bool`(87) · `SSH_DROPIN` const (117 → `/etc/ssh/sshd_config.d/99-twdxwpss-hardening.conf`) · `SYSCTL_CONF` const (200 → `/etc/sysctl.d/99-twdxwpss-hardening.conf`). Env: `SSH_PORT` `ENABLE_UFW` `OPEN_HTTP` `OPEN_HTTPS` `DRY_RUN` |
| `scripts/wp-auto-update.sh.tpl` | Per-host WP update script — `flock` single-instance guard, per-step `run()` wrapper, exits with failure count | Placeholders: `__WP_PATH__` `__WP_USER__` `__LOG_FILE__` |
| `scripts/pre-commit.sh` | Local commit preflight — runs shellcheck, FILE_CHECKSUMS drift detection, secret scan. Symlinked from `.git/hooks/pre-commit` | `fail`/`ok`/`warn`/`step` helpers; `shipped[]` list mirrors install.sh:84 |
| `configs/50unattended-upgrades` | APT policy — Allowed-Origins incl. ESM, `MailReport on-change`, `Acquire::Retries 3`, `Automatic-Reboot-Time "03:00"`, `Skip-Updates-On-Metered-Connections true` | — |
| `configs/20auto-upgrades` | APT periodic intervals (Update / Download / Autoclean / Unattended all daily) | — |
| `configs/auto-reboot.service` | `oneshot` — runs `shutdown -r +1` iff `/var/run/reboot-required` exists | `ConditionPathExists=/var/run/reboot-required` |
| `configs/auto-reboot.timer.tpl` | systemd timer (`OnCalendar=*-*-* __REBOOT_TIME__`, `Persistent=true`) | Placeholder: `__REBOOT_TIME__` |
| `configs/needrestart.conf` | needrestart: `$nrconf{restart} = 'a'`, suppresses interactive prompts | — |
| `configs/fail2ban-jail.local` | Jails: `sshd` aggressive (4 retries / 10 min → 1 h ban) and `recidive` (3 bans / 1 d → 1 w ban). Exponential `bantime.increment`. `backend = systemd`, `banaction = nftables-multiport` | — |
| `.github/workflows/shellcheck.yml` | ShellCheck — gcc format, `style` severity, `configs/` excluded, `contents: read` only | — |

---

## Dependency Graph

```
install.sh
  ├── fetch_verified  configs/50unattended-upgrades  → /etc/apt/apt.conf.d/50unattended-upgrades
  ├── fetch_verified  configs/20auto-upgrades        → /etc/apt/apt.conf.d/20auto-upgrades
  ├── fetch_verified  configs/needrestart.conf       → /etc/needrestart/needrestart.conf
  ├── fetch_verified  configs/auto-reboot.service    → /etc/systemd/system/auto-reboot.service
  ├── fetch_verified  configs/auto-reboot.timer.tpl  → /etc/systemd/system/auto-reboot.timer
  │     (sed: __REBOOT_TIME__ → $REBOOT_TIME)
  ├── fetch_verified  configs/fail2ban-jail.local    → /etc/fail2ban/jail.local
  ├── fetch_verified  scripts/wp-auto-update.sh.tpl  → /usr/local/bin/wp-auto-update.sh
  │     (sed: __WP_PATH__, __WP_USER__, __LOG_FILE__)
  ├── curl + sha512   wp-cli.phar                    → /usr/local/bin/wp     (skipped if `wp` already on PATH)
  ├── inline heredoc                                  → /usr/local/bin/vm-system-cleanup.sh  (only if ENABLE_CLEANUP=true)
  ├── inline heredoc                                  → /etc/logrotate.d/twdxwpss
  └── generated                                       → /etc/cron.d/twdxwpss
        ├── WP update line     uses $CRON_SCHEDULE
        └── Cleanup line       forces minute "30" of the same hour/day to avoid overlap (install.sh:430)

scripts/harden.sh   — standalone, no install.sh dependency
  ├── generates → /etc/ssh/sshd_config.d/99-twdxwpss-hardening.conf  (validated with `sshd -t` before reload)
  ├── generates → /etc/sysctl.d/99-twdxwpss-hardening.conf           (applied via `sysctl --system`)
  └── ufw       → IPV6=yes, default deny-in / allow-out, low logging, opens $SSH_PORT + 80/443 per flags

uninstall.sh        — interactive, reverses install.sh + optionally harden.sh
  removes (always): /etc/cron.d/twdxwpss · /etc/systemd/system/auto-reboot.{service,timer}
                   · /usr/local/bin/{wp-auto-update.sh,vm-system-cleanup.sh}
                   · /var/lock/wp-auto-update.lock · /etc/logrotate.d/{twdxwpss,vm-auto-security}
                   · /etc/sysctl.d/99-twdxwpss-hardening.conf · /etc/ssh/sshd_config.d/99-twdxwpss-hardening.conf
  prompts for:     WP-CLI removal · /etc/fail2ban/jail.local removal · disable unattended-upgrades+fail2ban
                   · restore /etc/ssh/sshd_config.bak (legacy installs only) · `ufw disable`
```

---

## Runtime Artifacts (post-install, on a deployed host)

Not in the repo — useful when answering triage/debugging questions.

| Path | Created by | Purpose |
|---|---|---|
| `/etc/cron.d/twdxwpss` | install.sh §8 | WP update + optional cleanup cron lines |
| `/usr/local/bin/wp-auto-update.sh` | install.sh §7 | Rendered template — runs under `flock` |
| `/usr/local/bin/vm-system-cleanup.sh` | install.sh §4 | apt autoremove/autoclean + journal vacuum |
| `/var/lock/wp-auto-update.lock` | wp-auto-update.sh runtime | `flock` single-instance guard |
| `/var/log/wp-auto-update.log` | install.sh §7 | mode 640, owner `root:adm` |
| `/var/log/vm-system-cleanup.log` | install.sh §4 | mode 640, owner `root:adm` |
| `/etc/logrotate.d/twdxwpss` | install.sh §5 | Weekly, rotate 4, compress |
| `/etc/systemd/system/auto-reboot.{service,timer}` | install.sh §3 | Conditional kernel reboot |

---

## Conventions

| Convention | Detail |
|---|---|
| Dry-run | `DRY_RUN="${DRY_RUN:-false}"`, flags `--dry-run` / `--check`. Every side-effect guarded by `if [[ "$DRY_RUN" == "true" ]]; then dry_run "..."; else <real command>; fi` |
| Idempotency | `install.sh` and `harden.sh` are both safe to re-run |
| Template placeholders | `__VAR_NAME__` format, substituted with `sed -e "s\|__VAR__\|${VAR}\|g"`. Inputs validated by `validate_*()` before sed |
| Logging palette | `info` (blue) · `success` (green) · `warn` (yellow) · `error` (red+exit) · `step` (bold) · `dry_run` (yellow). Same set in install.sh / uninstall.sh / harden.sh |
| ShellCheck | CI runs on all `.sh`; `configs/` excluded. Use `# shellcheck disable=SCXXXX` inline for known false-positives |
| Checksum registry | `declare -A FILE_CHECKSUMS` at **install.sh:84**. **Update the matching entry when any `configs/` or `scripts/*.tpl` file changes** — recompute with `sha256sum <file>` |
| Cron placement | `/etc/cron.d/twdxwpss`, not root crontab. Cleanup line minute forced to `30` (install.sh:430) to offset from the WP update line |
| Log permissions | Created with `install -m 640 -o root -g adm` — not world-readable |
| Drop-in style | New OS-level config goes to `/etc/<thing>.d/99-twdxwpss-hardening.conf`, never mutates the upstream file |

---

## Common Change Recipes

| Goal | Files to touch |
|---|---|
| Edit a config that ships to disk (e.g. tighten fail2ban) | (1) edit `configs/<file>`  (2) `sha256sum configs/<file>`  (3) update `FILE_CHECKSUMS["configs/<file>"]` at install.sh:84 — the pre-commit hook will block the commit if you forget |
| Add a brand-new shipped config | (1) create `configs/<file>`  (2) add `FILE_CHECKSUMS` entry  (3) add the path to the `shipped[]` array in `scripts/pre-commit.sh`  (4) add `fetch_verified` call in the matching `step` block in install.sh  (5) add removal line in uninstall.sh  (6) update the Dependency Graph above |
| Tweak SSH or sysctl rule | edit the heredoc in `scripts/harden.sh` (SSH §1 / sysctl §2). No checksum — harden.sh embeds these inline, not via `fetch_verified` |
| Add a new env var | (1) default + interactive prompt block in install.sh  (2) add a `validate_*` if non-trivial  (3) document in `show_help`  (4) document in README.md headless-configuration table |
| Change the WP update script | edit `scripts/wp-auto-update.sh.tpl`, then bump its checksum (recipe row 1) |
| Add a CI rule | extend `.github/workflows/shellcheck.yml`. Keep `permissions: contents: read` and `configs/` ignored |

---

## Quick Commands

```bash
# Lint locally (matches CI)
shellcheck install.sh uninstall.sh scripts/*.sh

# Preview an install without writing anything
sudo bash install.sh --dry-run
sudo bash scripts/harden.sh --dry-run

# Recompute every shipped-file checksum (paste into FILE_CHECKSUMS)
for f in configs/50unattended-upgrades configs/20auto-upgrades configs/needrestart.conf \
         configs/auto-reboot.service configs/auto-reboot.timer.tpl configs/fail2ban-jail.local \
         scripts/wp-auto-update.sh.tpl; do
  printf '    ["%s"]="%s"\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
done
```

---

## What NOT to Read for Typical Tasks

| File | Skip when... |
|---|---|
| `README.md` | Any code task — it's user docs, not implementation. Already in `.claudeignore` |
| `LICENSE` | Always — MIT boilerplate. Already in `.claudeignore` |
| `configs/needrestart.conf` | Unless the question is specifically about needrestart policy |
| `.github/workflows/shellcheck.yml` | Unless the question involves CI or adding new shell files |
| `.github/{FUNDING,dependabot}.yml` | Always — non-functional metadata |
