#!/usr/bin/env bash
# calibre_restore_preview.sh
# Lists available Calibre backup snapshots and rsyncs/rclones chosen snapshot
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
# Snapshot sources:
#   External drive — rsync hard-link snapshots, each a full point-in-time copy
#   iCloud current — rolling mirror of live library (always most recent state)
#   iCloud versions — dated delta folders of changed/deleted files (not full copies)
#
# NOTE: iCloud version folders contain only files that changed or were deleted
# on that night, not full library snapshots. To restore to a specific iCloud
# version you would need to start from iCloud/current and layer back the
# relevant version deltas manually. For full point-in-time restore use the
# external drive snapshots. iCloud current is the recommended iCloud restore
# option for most scenarios.
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

# iCloud paths — must match calibre_nightly_backup.sh
ICLOUD_CURRENT="$ICLOUD_BACKUP/current"
ICLOUD_VERSIONS="$ICLOUD_BACKUP/versions"

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
snap_types=()   # "rsync" or "rclone" — determines copy method
idx=1

# External drive — full hard-link snapshots, use rsync to restore
if [[ -d "$HOST_BACKUP" ]]; then
    while IFS= read -r snap; do
        snapshots+=("$snap")
        labels+=("[$idx] External drive — $(basename "$snap") (full snapshot)")
        snap_types+=("rsync")
        ((idx++)) || true
    done < <(ls -1d "$HOST_BACKUP"/{daily,weekly,monthly,yearly}.* 2>/dev/null | sort -r)
fi

# iCloud current — rolling mirror, use rclone to restore
if [[ -d "$ICLOUD_CURRENT" ]]; then
    snapshots+=("$ICLOUD_CURRENT")
    labels+=("[$idx] iCloud — current (rolling mirror, most recent state)")
    snap_types+=("rclone")
    ((idx++)) || true
fi

# iCloud versions — delta folders, listed for reference but flagged
if [[ -d "$ICLOUD_VERSIONS" ]]; then
    while IFS= read -r snap; do
        snapshots+=("$snap")
        labels+=("[$idx] iCloud version — $(basename "$snap") (delta only — see NOTE above)")
        snap_types+=("rclone_delta")
        ((idx++)) || true
    done < <(ls -1d "$ICLOUD_VERSIONS"/daily.* 2>/dev/null | sort -r)
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
selected_type="${snap_types[$((choice - 1))]}"

# Warn if user selects an iCloud delta version
if [[ "$selected_type" == "rclone_delta" ]]; then
    echo ""
    echo "  ⚠ WARNING: iCloud version folders contain only changed/deleted files"
    echo "    from that night, not a full library snapshot. This preview will"
    echo "    only contain those delta files, not your complete library."
    echo "    For a full restore use an external drive snapshot or iCloud current."
    echo ""
    read -r -p "  Proceed anyway? (yes/no): " delta_confirm
    if [[ "$delta_confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

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

# ── Copy snapshot to preview folder ──────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PREVIEW_PATH="$HOST_PREVIEW/preview_${TIMESTAMP}_$(basename "$selected")"
mkdir -p "$PREVIEW_PATH"

echo "Restoring snapshot to preview folder..."
echo "  Source:      $selected"
echo "  Destination: $PREVIEW_PATH"
echo "  Method:      $selected_type"
echo ""

if [[ "$selected_type" == "rsync" ]]; then
    rsync -aH --delete "$selected/" "$PREVIEW_PATH/"
else
    # rclone for iCloud current and delta versions
    rclone sync "$selected/" "$PREVIEW_PATH/" -v 2>&1 | grep -v "^$" || true
fi

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
