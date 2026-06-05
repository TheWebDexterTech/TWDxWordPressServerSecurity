#!/usr/bin/env bash
# =============================================================================
# TWDxWordPressServerSecurity — commit preflight
# https://github.com/TheWebDexterTech/TWDxWordPressServerSecurity
#
# Runs three local checks before a commit lands on main (production):
#   1. ShellCheck on every shell script  (matches CI)
#   2. FILE_CHECKSUMS drift              (sha256 of configs/*, scripts/*.tpl
#                                         must match install.sh:84)
#   3. Secret scan on the staged diff    (AWS keys, GH tokens, OpenAI keys,
#                                         PEM private keys)
#
# One-time install:
#   ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit
#   chmod +x scripts/pre-commit.sh
#
# Or run manually any time:
#   bash scripts/pre-commit.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
fail() { echo -e "${RED}[preflight] FAIL:${NC} $*" >&2; exit 1; }
ok()   { echo -e "${GREEN}[preflight]  ok :${NC} $*"; }
warn() { echo -e "${YELLOW}[preflight] warn:${NC} $*"; }
step() { echo -e "\n${BOLD}▸ $*${NC}"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ── 1. ShellCheck ────────────────────────────────────────────────────────────
step "ShellCheck"
if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck --severity=style --format=gcc install.sh uninstall.sh scripts/*.sh; then
        fail "shellcheck reported issues — fix them before committing"
    fi
    ok "shellcheck clean"
else
    warn "shellcheck not installed — skipping locally (CI will still run it)"
fi

# ── 2. FILE_CHECKSUMS drift ──────────────────────────────────────────────────
step "FILE_CHECKSUMS drift"
shipped=(
    configs/50unattended-upgrades
    configs/20auto-upgrades
    configs/needrestart.conf
    configs/auto-reboot.service
    configs/auto-reboot.timer.tpl
    configs/fail2ban-jail.local
    scripts/wp-auto-update.sh.tpl
)
drift=0
for f in "${shipped[@]}"; do
    [[ -f "$f" ]] || fail "shipped file missing from working tree: $f"
    actual=$(sha256sum "$f" | awk '{print $1}')
    registered=$(grep -E "\[\"$f\"\]=" install.sh | sed -E 's/.*"([a-f0-9]{64})".*/\1/' || true)
    if [[ -z "$registered" ]]; then
        echo "  $f → no FILE_CHECKSUMS entry in install.sh"
        drift=1
        continue
    fi
    if [[ "$actual" != "$registered" ]]; then
        echo "  $f"
        echo "    install.sh: $registered"
        echo "    actual    : $actual"
        drift=1
    fi
done
if (( drift == 1 )); then
    fail "FILE_CHECKSUMS drift — update the registry at install.sh:84 before committing."
fi
ok "all ${#shipped[@]} shipped-file checksums match install.sh:84"

# ── 3. Secret scan on staged diff ────────────────────────────────────────────
step "Secret scan (staged diff)"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    staged_diff=$(git diff --cached -U0)
else
    # First commit — no HEAD yet
    staged_diff=$(git diff --cached -U0 --no-index /dev/null . 2>/dev/null || true)
fi

if [[ -z "$staged_diff" ]]; then
    warn "no staged changes — running checks against working tree only"
else
    # AWS access key · GitHub PAT · OpenAI key · PEM private key block · generic password=
    pattern='(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|password[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']{8,})'
    if echo "$staged_diff" | grep -nEi "$pattern" >&2; then
        fail "possible secret detected in staged diff — review before committing"
    fi
    ok "no obvious secrets in staged diff"
fi

echo
echo -e "${GREEN}${BOLD}[preflight] all checks passed${NC}"
