#!/usr/bin/env bash
# install_calibre_backup_launchd.sh
# Installs the Calibre nightly backup as a launchd job running at 2am
#
# Usage:
#   ./install_calibre_backup_launchd.sh
#
# To uninstall:
#   launchctl bootout gui/$(id -u)/info.fourm.calibre-backup
#   rm ~/Library/LaunchAgents/info.fourm.calibre-backup.plist

set -euo pipefail

# ── Load local config ─────────────────────────────────────────────────────────
_self_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"

PLIST_SRC="$SCRIPT_DIR/info.fourm.calibre-backup.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/info.fourm.calibre-backup.plist"
BACKUP_SCRIPT="$SCRIPT_DIR/calibre_nightly_backup.sh"
LABEL="info.fourm.calibre-backup"
DOMAIN="gui/$(id -u)"

echo "=========================================="
echo "  Install Calibre Backup launchd Job"
echo "=========================================="
echo ""

# Checks
if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    echo "ERROR: Backup script not found at $BACKUP_SCRIPT"
    exit 1
fi

if [[ ! -f "$PLIST_SRC" ]]; then
    echo "ERROR: Plist not found at $PLIST_SRC"
    exit 1
fi

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

# Boot out existing job if present. `bootout`/`bootstrap` are the modern
# replacement for `unload`/`load` — recent macOS versions are unreliable
# about the legacy pair, often failing with a generic I/O error even when
# nothing is actually wrong. This is a one-time registration step only:
# once bootstrapped, launchd itself reloads the job automatically on every
# subsequent login/reboot by scanning LaunchAgents directly — this script
# never needs to run again unless you're reinstalling on a new machine or
# changing the plist.
echo "  Booting out any existing job (harmless if none is loaded)..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# Write the plist with the real script path substituted in. The template ships
# with a __BACKUP_SCRIPT__ placeholder rather than a hardcoded path so the job
# always points at wherever this repo actually lives — a plist that assumed
# ~/Code/FourM/Calibre would silently run nothing if the repo were cloned
# anywhere else. Substitution is done with bash's own ${var//pat/repl} rather
# than sed so that / and & in the path need no escaping.
plist_template="$(cat "$PLIST_SRC")"
printf '%s\n' "${plist_template//__BACKUP_SCRIPT__/$BACKUP_SCRIPT}" > "$PLIST_DEST"
echo "  ✓ Plist installed to $PLIST_DEST"
echo "    Runs: $BACKUP_SCRIPT"

# Load the job
launchctl bootstrap "$DOMAIN" "$PLIST_DEST"
echo "  ✓ launchd job loaded"

echo ""
echo "=========================================="
echo "  Done. Backup will run nightly at 2am."
echo ""
echo "  To run manually right now:"
echo "    bash $BACKUP_SCRIPT"
echo ""
echo "  To check job is loaded:"
echo "    launchctl print $DOMAIN/$LABEL"
echo "    launchctl list | grep calibre"
echo ""
echo "  To uninstall:"
echo "    launchctl bootout $DOMAIN/$LABEL"
echo "    rm $PLIST_DEST"
echo "=========================================="
