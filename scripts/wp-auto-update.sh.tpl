#!/bin/bash
set -euo pipefail
# wp-auto-update.sh
# Installed by TWDxWordPressServerSecurity — https://github.com/thewebdexter/TWDxWordPressServerSecurity

WP_PATH="__WP_PATH__"
WP_USER="__WP_USER__"
LOG="__LOG_FILE__"

{
    echo ""
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
    sudo -u "$WP_USER" wp --path="$WP_PATH" core update
    sudo -u "$WP_USER" wp --path="$WP_PATH" plugin update --all
    sudo -u "$WP_USER" wp --path="$WP_PATH" theme update --all
    sudo -u "$WP_USER" wp --path="$WP_PATH" core language update
    sudo -u "$WP_USER" wp --path="$WP_PATH" cache flush
    sudo -u "$WP_USER" wp --path="$WP_PATH" db optimize
    echo "=== done ==="
} >> "$LOG" 2>&1
