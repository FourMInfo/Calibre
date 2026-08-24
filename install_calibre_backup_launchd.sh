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

SCRIPTS_DIR="$HOME/Code/FourM/Calibre"
PLIST_SRC="$SCRIPTS_DIR/info.fourm.calibre-backup.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/info.fourm.calibre-backup.plist"
BACKUP_SCRIPT="$SCRIPTS_DIR/calibre_nightly_backup.sh"
LOG_DIR="$HOME/Code/FourM/Logs"
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

# Copy plist to LaunchAgents and substitute YOUR_USERNAME with actual username
sed "s/YOUR_USERNAME/$USER/g" "$PLIST_SRC" > "$PLIST_DEST"
echo "  ✓ Plist installed to $PLIST_DEST"

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
