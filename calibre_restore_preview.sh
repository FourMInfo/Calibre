#!/usr/bin/env bash
# calibre_restore_preview.sh
# Lists available Calibre backup snapshots and rsyncs chosen snapshot
# to a timestamped folder on external drive for review.
# Does NOT touch the live library.
#
# Usage:
#   ./calibre_restore_preview.sh
#
# After this script completes:
#   1. Open Calibre app
#   2. Switch library to the preview folder to review
#   3. When satisfied, run calibre_restore_finalize.sh
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
HOST_PREVIEW="$(dirname "$HOST_BACKUP")/CalibreRestore"
SCRIPTS_DIR="$HOME/Code/FourM/Calibre"
LOG_DIR="$HOME/Code/FourM/Logs"
VENV_DIR="$HOME/Code/venv/calibre-web-env"

mkdir -p "$LOG_DIR"

echo "=========================================="
echo "  Calibre Restore Preview"
echo "  $(date)"
echo "=========================================="
echo ""

# ── Collect available snapshots ───────────────────────────────────────────────
echo "Scanning available snapshots..."
echo ""

snapshots=()
labels=()
idx=1

# External drive
if [[ -d "$HOST_BACKUP" ]]; then
    while IFS= read -r snap; do
        snapshots+=("$snap")
        labels+=("[$idx] External drive — $(basename "$snap")")
        ((idx++)) || true
    done < <(ls -1d "$HOST_BACKUP"/{daily,weekly,monthly,yearly}.* 2>/dev/null | sort -r)
fi

# iCloud
if [[ -d "$ICLOUD_BACKUP" ]]; then
    while IFS= read -r snap; do
        snapshots+=("$snap")
        labels+=("[$idx] iCloud — $(basename "$snap")")
        ((idx++)) || true
    done < <(ls -1d "$ICLOUD_BACKUP"/{daily,weekly,monthly,yearly}.* 2>/dev/null | sort -r)
fi

if [[ ${#snapshots[@]} -eq 0 ]]; then
    echo "ERROR: No snapshots found. Have you run a backup yet?"
    exit 1
fi

# ── Display snapshot list ─────────────────────────────────────────────────────
echo "Available snapshots:"
echo ""
for label in "${labels[@]}"; do
    echo "  $label"
done
echo ""

read -r -p "Enter snapshot number to restore: " choice

# Validate choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#snapshots[@]} ]]; then
    echo "ERROR: Invalid selection"
    exit 1
fi

selected="${snapshots[$((choice - 1))]}"
selected_label="${labels[$((choice - 1))]}"
snap_path="$selected"

echo ""
echo "  Selected: $selected_label"
echo ""
read -r -p "Confirm restore preview of this snapshot? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Stop CalibreWeb and Calibre ───────────────────────────────────────────────
echo ""
echo "Stopping CalibreWeb and Calibre..."
pkill -TERM -f "cps" 2>/dev/null || true
killall calibre 2>/dev/null || true
killall calibre-parallel 2>/dev/null || true
echo "  Waiting 60 seconds for clean shutdown..."
sleep 60
echo "  ✓ Done"
echo ""

# ── rsync snapshot to preview folder ─────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PREVIEW_PATH="$HOST_PREVIEW/preview_${TIMESTAMP}_$(basename "$snap_path")"
mkdir -p "$PREVIEW_PATH"

echo "Restoring snapshot to preview folder..."
echo "  Destination: $PREVIEW_PATH"
echo ""

rsync -aH --delete "$snap_path/" "$PREVIEW_PATH/"

echo "  ✓ Snapshot restored to preview folder"
echo ""

# ── Integrity check on preview ────────────────────────────────────────────────
echo "Running integrity check on preview..."
if [[ -f "$SCRIPTS_DIR/calibre_check_integrity.sh" ]]; then
    bash "$SCRIPTS_DIR/calibre_check_integrity.sh" "$PREVIEW_PATH" "$LOG_DIR"
    echo "  ✓ Integrity check complete"
else
    echo "  ⚠ calibre_check_integrity.sh not found — skipping"
fi
echo ""

# ── Save preview path for finalize script ────────────────────────────────────
echo "$PREVIEW_PATH" > "$LOG_DIR/.calibre_restore_preview_path"

echo "=========================================="
echo "  Preview ready."
echo ""
echo "  Preview location:"
echo "  $PREVIEW_PATH"
echo ""
echo "  Next steps:"
echo "  1. Open Calibre app"
echo "  2. Switch library to the preview folder above"
echo "  3. Review that everything looks correct"
echo "  4. When satisfied, run:"
echo "     $SCRIPTS_DIR/calibre_restore_finalize.sh"
echo ""
echo "  NOTE: CalibreWeb is currently stopped."
echo "  If you decide NOT to proceed with restore,"
echo "  restart it manually with:"
echo "     $SCRIPTS_DIR/start_calibreweb.sh"
echo "=========================================="
