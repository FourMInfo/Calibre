#!/usr/bin/env bash
# calibre_restore_finalize.sh
# Finalizes a Calibre restore after manual review of the preview.
# Run this ONLY after running calibre_restore_preview.sh and
# verifying the preview library looks correct in the Calibre app.
#
# What this script does:
#   1. Confirms you are ready to proceed
#   2. cp -R current ~/Calibre Library to external drive with timestamp (safety copy)
#   3. rm -rf ~/Calibre Library
#   4. cp -R preview folder to ~/Calibre Library
#   5. Restarts CalibreWeb
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# ── Load local config ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo "ERROR: config.sh not found at $SCRIPT_DIR/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$SCRIPT_DIR/config.sh"

# ── Derived paths (not in config) ─────────────────────────────────────────────
LIBRARY="$HOME/Calibre Library"
SCRIPTS_DIR="$HOME/Code/FourM/Calibre"
LOG_DIR="$HOME/Code/FourM/Logs"
PREVIEW_PATH_FILE="$LOG_DIR/.calibre_restore_preview_path"

echo "=========================================="
echo "  Calibre Restore Finalize"
echo "  $(date)"
echo "=========================================="
echo ""

# ── Check preview path exists ─────────────────────────────────────────────────
if [[ ! -f "$PREVIEW_PATH_FILE" ]]; then
    echo "ERROR: No preview path found."
    echo "  Run calibre_restore_preview.sh first."
    exit 1
fi

PREVIEW_PATH=$(cat "$PREVIEW_PATH_FILE")

if [[ ! -d "$PREVIEW_PATH" ]]; then
    echo "ERROR: Preview folder not found at: $PREVIEW_PATH"
    echo "  Run calibre_restore_preview.sh again."
    exit 1
fi

echo "  Preview folder : $PREVIEW_PATH"
echo "  Live library   : $LIBRARY"
echo ""
echo "  ⚠ WARNING: This will PERMANENTLY replace your live library."
echo "  The current library will be backed up to external drive first."
echo ""
read -r -p "Have you reviewed the preview in Calibre and are satisfied? (yes/no): " reviewed
if [[ "$reviewed" != "yes" ]]; then
    echo "Aborted. Run calibre_restore_preview.sh and review first."
    exit 0
fi

echo ""
read -r -p "FINAL CONFIRMATION — replace live library with preview? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Make sure CalibreWeb and Calibre are stopped ──────────────────────────────
echo ""
echo "[ 1/5 ] Ensuring CalibreWeb and Calibre are stopped..."
pkill -TERM -f "cps" 2>/dev/null || true
killall calibre 2>/dev/null || true
killall calibre-parallel 2>/dev/null || true
sleep 10
echo "  ✓ Done"
echo ""

# ── Step 2: Safety copy of current library ────────────────────────────────────
echo "[ 2/5 ] Backing up current library to external drive..."
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAFETY_COPY="$HOST_BACKUP/pre_restore_${TIMESTAMP}"

if [[ -d "$LIBRARY" ]]; then
    cp -R "$LIBRARY" "$SAFETY_COPY"
    echo "  ✓ Safety copy created: $SAFETY_COPY"
else
    echo "  ⚠ No existing library found at $LIBRARY — skipping safety copy"
fi
echo ""

# ── Step 3: Remove current library ───────────────────────────────────────────
echo "[ 3/5 ] Removing current library..."
if [[ -d "$LIBRARY" ]]; then
    rm -rf "$LIBRARY"
    echo "  ✓ Removed: $LIBRARY"
fi
echo ""

# ── Step 4: Copy preview to live library ─────────────────────────────────────
echo "[ 4/5 ] Copying preview to live library location..."
cp -R "$PREVIEW_PATH" "$LIBRARY"
echo "  ✓ Library restored to: $LIBRARY"
echo ""

# ── Step 5: Restart CalibreWeb ────────────────────────────────────────────────
echo "[ 5/5 ] Restarting CalibreWeb..."
if [[ -f "$SCRIPTS_DIR/start_calibreweb.sh" ]]; then
    bash "$SCRIPTS_DIR/start_calibreweb.sh"
    echo "  ✓ CalibreWeb restarted"
else
    echo "  ⚠ start_calibreweb.sh not found"
    echo "    Start manually with: source $HOME/Code/venv/calibre-web-env/bin/activate && cps &"
fi

# Clean up preview path file
rm -f "$PREVIEW_PATH_FILE"

echo ""
echo "=========================================="
echo "  Restore complete: $(date)"
echo ""
echo "  Restored from : $PREVIEW_PATH"
echo "  Safety copy   : $SAFETY_COPY"
echo "=========================================="
