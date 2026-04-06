#!/usr/bin/env bash
# install_calibre_backup_launchd.sh
# Installs the Calibre nightly backup as a launchd job running at 2am
#
# Usage:
#   ./install_calibre_backup_launchd.sh
#
# To uninstall:
#   launchctl unload ~/Library/LaunchAgents/info.fourm.calibre-backup.plist
#   rm ~/Library/LaunchAgents/info.fourm.calibre-backup.plist

set -euo pipefail

SCRIPTS_DIR="$HOME/Code/FourM/Calibre"
PLIST_SRC="$SCRIPTS_DIR/info.fourm.calibre-backup.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/info.fourm.calibre-backup.plist"
BACKUP_SCRIPT="$SCRIPTS_DIR/calibre_nightly_backup.sh"
LOG_DIR="$HOME/Code/FourM/Logs"

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

# Unload existing job if present
if launchctl list | grep -q "info.fourm.calibre-backup" 2>/dev/null; then
    echo "  Unloading existing launchd job..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Copy plist to LaunchAgents and substitute YOUR_USERNAME with actual username
sed "s/YOUR_USERNAME/$USER/g" "$PLIST_SRC" > "$PLIST_DEST"
echo "  ✓ Plist installed to $PLIST_DEST"

# Load the job
launchctl load "$PLIST_DEST"
echo "  ✓ launchd job loaded"

echo ""
echo "=========================================="
echo "  Done. Backup will run nightly at 2am."
echo ""
echo "  To run manually right now:"
echo "    bash $BACKUP_SCRIPT"
echo ""
echo "  To check job is loaded:"
echo "    launchctl list | grep calibre"
echo ""
echo "  To uninstall:"
echo "    launchctl unload $PLIST_DEST"
echo "    rm $PLIST_DEST"
echo "=========================================="
