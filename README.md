# VM-Auto-security

Hands-off maintenance for headless WordPress servers on Ubuntu 24.04. Set it up once and forget about it — security patches, bug fixes, service restarts, kernel reboots, system cleanup, and WordPress updates all happen automatically.

Built for lean cloud setups where you want the server to take care of itself. 

**Developed by [TheWebDexter.com](https://thewebdexter.com)**

---

## What it does

| Layer | Tool | When |
|---|---|---|
| OS security patches + bug fixes | `unattended-upgrades` | Daily |
| Restart services after library updates | `needrestart` | After every `apt` run |
| Reboot if a kernel update is pending | systemd timer | Nightly (default 03:30 UTC) |
| Update WP core, plugins, themes | WP-CLI + cron | Configurable (Default: Weekly) |
| System Cleanup (apt caches & logs) | bash + cron | Configurable (Default: Weekly) |

---

## Requirements

- Ubuntu 24.04 LTS (tested on both `x86_64` and `aarch64`)
- Root or sudo access
- WordPress already installed
- Outbound internet access (to fetch WP-CLI and configs on first run)

---

## Quick Install (Recommended)

You do not need to clone this repository. Simply run the following one-liner on your server. It includes an interactive terminal menu to configure your maintenance schedule and cleanup preferences.

```bash
curl -fsSL [https://raw.githubusercontent.com/thewebdexter/VM-auto-security/main/install.sh](https://raw.githubusercontent.com/thewebdexter/VM-auto-security/main/install.sh) | sudo bash

```

The script is entirely **idempotent** — it is completely safe to re-run on an existing server if you want to update your settings or get the latest features.

---

## Manual Install (Clone Repository)

If you prefer to review the files locally or make your own modifications before installing, you can clone the repository directly:

```bash
git clone [https://github.com/thewebdexter/VM-auto-security.git](https://github.com/thewebdexter/VM-auto-security.git)
cd VM-auto-security
sudo bash install.sh

```

---

## Headless Configuration (Optional)

If you prefer to bypass the interactive menu (e.g., for automated provisioning), you can pass all configuration options as inline environment variables. This works for both the quick install and the manual install:

**One-liner example:**

```bash
curl -fsSL [https://raw.githubusercontent.com/thewebdexter/VM-auto-security/main/install.sh](https://raw.githubusercontent.com/thewebdexter/VM-auto-security/main/install.sh) | \
  sudo WP_PATH=/var/www/mysite \
  WP_USER=nginx \
  ENABLE_CLEANUP=true \
  CRON_SCHEDULE="0 4 * * 1" \
  bash

```

**Clone example:**

```bash
sudo WP_PATH=/var/www/mysite WP_USER=nginx ENABLE_CLEANUP=true bash install.sh

```

| Variable | Default | Description |
| --- | --- | --- |
| `WP_PATH` | `/var/www/html` | Path to WordPress root |
| `WP_USER` | `www-data` | OS user that owns WP files |
| `ENABLE_CLEANUP` | `true` | Automates `apt autoremove/autoclean` and journal log trimming |
| `CRON_SCHEDULE` | `0 3 * * 0` | Standard cron string for WP updates (Default: Sun 03:00) |
| `REBOOT_TIME` | `03:30:00` | Nightly reboot check time (UTC) |
| `LOG_FILE` | `/var/log/wp-auto-update.log` | WP update log path |

*(Note: If `ENABLE_CLEANUP` is true, the cleanup script will automatically run 30 minutes after the WordPress update to prevent CPU spikes).*

---

## Verify the install

```bash
# OS updater running?
systemctl status unattended-upgrades

# Test a dry run
unattended-upgrade --dry-run

# Reboot timer scheduled?
systemctl list-timers auto-reboot.timer

# WP-CLI connected?
sudo -u www-data wp --path=/var/www/html core version

# Check active cron jobs
crontab -l

```

---

## Logs

| What | Where |
| --- | --- |
| OS updates | `/var/log/unattended-upgrades/unattended-upgrades.log` |
| dpkg changes | `/var/log/unattended-upgrades/unattended-upgrades-dpkg.log` |
| WP updates | `/var/log/wp-auto-update.log` |
| System Cleanup | `/var/log/vm-system-cleanup.log` |

---

## Notes

* **Reboots** only happen when a kernel update is actually pending (`/var/run/reboot-required`). Most nightly checks will do nothing.
* **WP plugin updates** flush the object cache automatically, but occasionally major updates can break a site. Check the log if you're actively developing.
* **Cloudflared / tunnel daemons** reconnect automatically on reboot as long as they're enabled as systemd services.
* The installer does not touch your web server, database, or WordPress files directly — only system-level tooling is configured.

---

## Uninstall

If you ever need to remove the automation:

```bash
# Remove cron jobs
crontab -l | grep -v "wp-auto-update" | grep -v "vm-system-cleanup" | crontab -

# Disable systemd timer
systemctl disable --now auto-reboot.timer
rm /etc/systemd/system/auto-reboot.{service,timer}
systemctl daemon-reload

# Disable unattended-upgrades (optional — it's a standard Ubuntu package)
systemctl disable --now unattended-upgrades

# Remove scripts and WP-CLI
rm /usr/local/bin/wp /usr/local/bin/wp-auto-update.sh /usr/local/bin/vm-system-cleanup.sh

```
## License

MIT
