#!/usr/bin/env bash
# calibre_nightly_backup.sh
# Nightly backup of Calibre library with rotation
#
# What this script does:
#   1. Stops CalibreWeb and Calibre
#   2. Waits 60 seconds for clean shutdown
#   3. Runs integrity check on library (logs corrupt files, does not abort)
#   4. rsyncs library to external drive (with --link-dest deduplication)
#   5. rclone syncs library to iCloud (with --backup-dir versioning)
#   6. Rotates snapshots: 7 dailies, 4 weeklies, 2 monthlies, 1 yearly
#   7. Restarts CalibreWeb in tmux
#
# External drive uses rsync with hard-link deduplication (--link-dest).
# iCloud uses rclone with --backup-dir versioning because iCloud does not
# support hard links — rsync --link-dest produces broken snapshots on iCloud
# where all versions share inodes and mutate together.
#
# Install as launchd job: use install_calibre_backup_launchd.sh
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ── Load local config ─────────────────────────────────────────────────────────
# SCRIPT_DIR has to be derived here because it is what locates config.sh.
# config.sh may override it; if it doesn't, this script's own directory wins.
_self_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"

# ── Validate config ───────────────────────────────────────────────────────────
# This script runs unattended from launchd with stdout and stderr going to
# /dev/null, so a missing key under `set -u` would kill it silently. Check
# up front, before any output redirection, and say exactly what is missing.
missing_keys=""
for key in LIBRARY LOG_DIR VENV_DIR HOST_BACKUP ICLOUD_BACKUP \
           KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY KEEP_YEARLY KEEP_LOGS; do
    if [[ -z "${!key:-}" ]]; then
        missing_keys="$missing_keys $key"
    fi
done
if [[ -n "$missing_keys" ]]; then
    echo "ERROR: config.sh is missing required key(s):$missing_keys"
    echo "  Compare your config.sh against config.sh.example and add them."
    exit 1
fi

LOG_PREFIX="calibre_backup"
LOG_FILE="$LOG_DIR/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S).log"

# iCloud snapshot and versions directories
# current/  — rolling mirror of live library (always up to date)
# versions/ — files that were changed or deleted, organised by date
ICLOUD_CURRENT="$ICLOUD_BACKUP/current"
ICLOUD_VERSIONS="$ICLOUD_BACKUP/versions"

# ── Helpers ──────────────────────────────────────────────────────────────────
ts() { date +"%Y-%m-%d %H:%M:%S"; }

# Failure tracking. A step that fails must not abort the run — the remaining
# steps still have value, and the _FAILED marker log written at the end is
# what surfaces the problem, exactly as _WARNING does for an absent drive.
# Tracked as a counter plus a string rather than an array because bash 3.2
# under `set -u` errors on ${#arr[@]} when the array is empty.
FAIL_COUNT=0
FAIL_SUMMARY=""
note_failure() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    FAIL_SUMMARY="$FAIL_SUMMARY  - $1
"
    echo "  ✗ FAILED: $1"
}

# True if the external drive is actually mounted.
# `[[ -d ]]` is not enough: an unclean ejection can leave the mountpoint
# directory behind, in which case rsync would happily write the whole
# library onto the internal disk. `grep -F` keeps the path literal so
# regex metacharacters in a drive name can't misfire, and the trailing
# "(" anchors the match so /Volumes/Extreme can't match /Volumes/Extreme2.
host_drive_mounted() {
    mount | grep -qF " on $HOST_DRIVE ("
}

# ── Setup ─────────────────────────────────────────────────────────────────────
# Increase file descriptor limit globally for large library operations
ulimit -n 65536 2>/dev/null || true

mkdir -p "$LOG_DIR"
mkdir -p "$ICLOUD_CURRENT"
mkdir -p "$ICLOUD_VERSIONS"

# Check external drive is mounted before proceeding
HOST_DRIVE=$(echo "$HOST_BACKUP" | cut -d'/' -f1-3)
HOST_BACKUP_OK=false
if ! host_drive_mounted; then
    # Log to a fallback log since main log dir may also be on external
    WARN_LOG="$LOG_DIR/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S)_WARNING.log"
    echo "$(date): WARNING: External drive not mounted at $HOST_DRIVE — External drive backup will be skipped" >> "$WARN_LOG"
    HOST_MOUNTED=false
else
    mkdir -p "$HOST_BACKUP"
    HOST_MOUNTED=true
fi

# Redirect all output to log file and stdout
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "  Calibre Nightly Backup"
echo "  $(ts)"
echo "=========================================="
echo ""

# ── Helper: rotate snapshots (external drive only — uses hard links) ──────────
# iCloud rotation is handled separately via rclone_rotate_icloud()
rotate_snapshots() {
    local backup_root="$1"

    local dow
    dow=$(date +%u)  # 1=Monday 7=Sunday
    local dom
    dom=$(date +%d)  # day of month
    local month
    month=$(date +%m)

    # Promote daily → weekly (on Sunday)
    if [[ "$dow" == "7" ]]; then
        local latest_daily
        latest_daily=$(ls -1d "$backup_root"/daily.* 2>/dev/null | sort | tail -1 || true)
        if [[ -n "$latest_daily" ]]; then
            local weekly_name="$backup_root/weekly.$(date +%Y%m%d)"
            mkdir -p "$weekly_name" && cp -al "$latest_daily/." "$weekly_name/" || true
            echo "  → Promoted to weekly: $weekly_name"
        fi
    fi

    # Promote weekly → monthly (on 1st of month)
    if [[ "$dom" == "01" ]]; then
        local latest_weekly
        latest_weekly=$(ls -1d "$backup_root"/weekly.* 2>/dev/null | sort | tail -1 || true)
        if [[ -n "$latest_weekly" ]]; then
            local monthly_name="$backup_root/monthly.$(date +%Y%m)"
            mkdir -p "$monthly_name" && cp -al "$latest_weekly/." "$monthly_name/" || true
            echo "  → Promoted to monthly: $monthly_name"
        fi
    fi

    # Promote monthly → yearly (on Jan 1st)
    if [[ "$dom" == "01" && "$month" == "01" ]]; then
        local latest_monthly
        latest_monthly=$(ls -1d "$backup_root"/monthly.* 2>/dev/null | sort | tail -1 || true)
        if [[ -n "$latest_monthly" ]]; then
            local yearly_name="$backup_root/yearly.$(date +%Y)"
            mkdir -p "$yearly_name" && cp -al "$latest_monthly/." "$yearly_name/" || true
            echo "  → Promoted to yearly: $yearly_name"
        fi
    fi

    # Prune old snapshots
    prune() {
        local prefix="$1"
        local keep="$2"
        local count
        # `ls` exits nonzero when the glob matches nothing, which pipefail
        # would turn into a fatal error, so absorb it inside the pipeline.
        count=$( { ls -1d "$backup_root"/${prefix}.* 2>/dev/null || true; } | wc -l | tr -d ' \n')
        if [[ "$count" -gt "$keep" ]]; then
            local to_delete=$(( count - keep ))
            ls -1d "$backup_root"/${prefix}.* 2>/dev/null | sort | head -"$to_delete" | xargs rm -rf || true
            echo "  → Pruned $to_delete old ${prefix} snapshot(s)"
        fi
    }

    prune "daily"   "$KEEP_DAILY"
    prune "weekly"  "$KEEP_WEEKLY"
    prune "monthly" "$KEEP_MONTHLY"
    prune "yearly"  "$KEEP_YEARLY"
}

# ── Helper: rotate iCloud versions (rclone-based, no hard links) ──────────────
# iCloud versions are stored as dated folders under $ICLOUD_VERSIONS/
# Each folder contains only the files that changed or were deleted that night.
# Retention mirrors the external drive: KEEP_DAILY versions kept.
# Weekly/monthly/yearly promotion is not done for iCloud versions since
# each version folder contains only deltas, not full snapshots — promoting
# a delta folder as a weekly would be misleading.
rclone_rotate_icloud() {
    local count
    count=$( { ls -1d "$ICLOUD_VERSIONS"/daily.* 2>/dev/null || true; } | wc -l | tr -d ' \n')
    if [[ "$count" -gt "$KEEP_DAILY" ]]; then
        local to_delete=$(( count - KEEP_DAILY ))
        ls -1d "$ICLOUD_VERSIONS"/daily.* 2>/dev/null | sort | head -"$to_delete" | xargs rm -rf || true
        echo "  → Pruned $to_delete old iCloud version(s)"
    fi
}

# ── Step 1: Stop CalibreWeb and Calibre ───────────────────────────────────────
echo "$(ts) [ 1/7 ] Stopping CalibreWeb and Calibre..."

if [[ -f "$SCRIPT_DIR/stop_calibreweb.sh" ]]; then
    bash "$SCRIPT_DIR/stop_calibreweb.sh" || note_failure "stop_calibreweb.sh returned an error"
else
    # Fallback if stop script not found
    pkill -TERM -f "cps" 2>/dev/null || true
    killall calibre 2>/dev/null || true
    killall calibre-parallel 2>/dev/null || true
fi

echo "  Waiting 60 seconds for clean shutdown..."
sleep 60
echo "  ✓ Done"
echo ""

# ── Step 2: Verify library is accessible ─────────────────────────────────────
echo "$(ts) [ 2/7 ] Verifying library..."
if [[ ! -d "$LIBRARY" ]]; then
    echo "  ERROR: Library not found at $LIBRARY — aborting backup"
    exit 1
fi
if [[ ! -f "$LIBRARY/metadata.db" ]]; then
    echo "  ERROR: metadata.db not found — library may be corrupt, aborting backup"
    exit 1
fi
echo "  ✓ Library OK"
echo ""

# ── Step 3: Integrity check ──────────────────────────────────────────────────
echo "$(ts) [ 3/7 ] Running integrity check..."

if [[ -f "$SCRIPT_DIR/calibre_check_integrity.sh" ]]; then
    bash "$SCRIPT_DIR/calibre_check_integrity.sh" "$LIBRARY" "$LOG_DIR" > "/dev/null" \
        || note_failure "integrity check returned an error"
    echo "  ✓ Integrity check complete — review $LOG_DIR for any corrupt files"
else
    echo "  ⚠ calibre_check_integrity.sh not found — skipping integrity check"
    note_failure "calibre_check_integrity.sh not found at $SCRIPT_DIR"
fi
echo ""

# ── Step 4: rsync to external drive ─────────────────────────────────────────
echo "$(ts) [ 4/7 ] Backing up to external drive..."

SNAPSHOT_NAME="daily.$(date +%Y%m%d_%H%M%S)"
HOST_SNAPSHOT="$HOST_BACKUP/$SNAPSHOT_NAME"

# Re-verify drive is still mounted immediately before rsync
# (it may have been present at startup but disconnected during shutdown wait)
if ! host_drive_mounted || [[ ! -d "$(dirname "$HOST_BACKUP")" ]]; then
    echo "  ⚠ External drive not mounted — skipping external backup"
    HOST_MOUNTED=false
else
    # Find last snapshot for --link-dest (safe glob — no error if none exist yet)
    HOST_LAST=$(find "$HOST_BACKUP" -maxdepth 1 -type d \( -name "daily.*" -o -name "weekly.*" -o -name "monthly.*" -o -name "yearly.*" \) 2>/dev/null | sort | tail -1 || true)

    rsync_status=0
    if [[ -n "$HOST_LAST" ]]; then
        echo "  Using --link-dest: $HOST_LAST"
        rsync -aH --delete --exclude='.DS_Store' --link-dest="$HOST_LAST" "$LIBRARY/" "$HOST_SNAPSHOT/" || rsync_status=$?
    else
        echo "  No previous snapshot found — full backup"
        rsync -aH --delete --exclude='.DS_Store' "$LIBRARY/" "$HOST_SNAPSHOT/" || rsync_status=$?
    fi

    if [[ "$rsync_status" -eq 0 ]]; then
        HOST_BACKUP_OK=true
        echo "  ✓ External drive backup complete: $HOST_SNAPSHOT"
    else
        note_failure "rsync to external drive failed (exit $rsync_status) — snapshot $HOST_SNAPSHOT may be incomplete"
    fi
fi
echo ""

# ── Step 5: rclone to iCloud ──────────────────────────────────────────────────
# rclone sync mirrors the live library to iCloud/current/
# --backup-dir moves changed/deleted files to a dated versions folder
# before overwriting, giving point-in-time recovery without hard links.
# iCloud does not support hard links so rsync --link-dest is not used here.
echo "$(ts) [ 5/7 ] Backing up to iCloud..."

ICLOUD_VERSION_DIR="$ICLOUD_VERSIONS/daily.$(date +%Y%m%d_%H%M%S)"

# `grep -v "^$"` exits 1 when it prints nothing, which pipefail would treat
# as a failed sync, so disable errexit around the pipeline and read rclone's
# own status out of PIPESTATUS instead of swallowing it with `|| true`.
set +e
rclone sync "$LIBRARY/" "$ICLOUD_CURRENT/" \
    --backup-dir "$ICLOUD_VERSION_DIR" \
    --exclude='.DS_Store' \
    --exclude='.stfolder/**' \
    -v \
    2>&1 | grep -v "^$"
rclone_status=${PIPESTATUS[0]}
set -e

if [[ "$rclone_status" -eq 0 ]]; then
    echo "  ✓ iCloud backup complete: $ICLOUD_CURRENT"
    echo "  ✓ Changed/deleted files versioned to: $ICLOUD_VERSION_DIR"
else
    note_failure "rclone sync to iCloud failed (exit $rclone_status) — iCloud copy is out of date"
fi
echo ""

# ── Step 6: Rotate snapshots ─────────────────────────────────────────────────
echo "$(ts) [ 6/7 ] Rotating snapshots..."

# Rotation only runs after a clean rsync. Promoting a partially written
# snapshot to weekly/monthly/yearly would bake the damage into long-term
# retention, so a failed rsync means today's snapshot stays a daily.
if [[ "$HOST_BACKUP_OK" == "true" ]]; then
    echo "  External drive:"
    rotate_snapshots "$HOST_BACKUP"
elif [[ "$HOST_MOUNTED" == "true" ]]; then
    echo "  External drive: skipped (backup failed — not promoting a partial snapshot)"
else
    echo "  External drive: skipped (drive not mounted)"
fi

echo "  iCloud versions:"
rclone_rotate_icloud

echo "  ✓ Rotation complete"
echo ""

# ── Step 7: Restart CalibreWeb ────────────────────────────────────────────────
echo "$(ts) [ 7/7 ] Restarting CalibreWeb..."

if [[ -f "$SCRIPT_DIR/start_calibreweb.sh" ]]; then
    if bash "$SCRIPT_DIR/start_calibreweb.sh"; then
        echo "  ✓ CalibreWeb restarted"
    else
        note_failure "start_calibreweb.sh returned an error — CalibreWeb may not be running"
    fi
else
    echo "  ⚠ start_calibreweb.sh not found at $SCRIPT_DIR"
    echo "    Start manually with: source $VENV_DIR/bin/activate && cps &"
    note_failure "start_calibreweb.sh not found at $SCRIPT_DIR — CalibreWeb was not restarted"
fi

echo ""
echo "=========================================="
echo "  Backup complete: $(ts)"
echo "  Log: $LOG_FILE"
echo "=========================================="

# ── Log rotation ─────────────────────────────────────────────────────────────
# Runs before the failure marker is written so today's _FAILED log survives.
log_count=$( { ls -1 "$LOG_DIR"/"${LOG_PREFIX}"_*.log 2>/dev/null || true; } | wc -l | tr -d ' \n')
if [[ "$log_count" -gt "$KEEP_LOGS" ]]; then
    to_delete=$(( log_count - KEEP_LOGS ))
    ls -1 "$LOG_DIR"/"${LOG_PREFIX}"_*.log | sort | head -"$to_delete" | xargs rm -f
    echo "  → Pruned $to_delete old log(s)"
fi

# ── Failure marker ───────────────────────────────────────────────────────────
# Every step above runs to completion regardless of individual failures — the
# partial backup is still worth having. Failures are surfaced here instead,
# as a _FAILED log sitting next to the _WARNING log, plus a notification.
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    FAIL_LOG="$LOG_DIR/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S)_FAILED.log"
    {
        echo "Calibre nightly backup completed with $FAIL_COUNT failure(s) - $(ts)"
        echo ""
        echo "Failed steps:"
        printf '%s' "$FAIL_SUMMARY"
        echo ""
        echo "Full log: $LOG_FILE"
    } > "$FAIL_LOG"

    osascript -e "display notification \"$FAIL_COUNT step(s) failed. See $(basename "$FAIL_LOG")\" with title \"Calibre backup\"" 2>/dev/null || true

    echo ""
    echo "  ⚠ $FAIL_COUNT step(s) failed — see $FAIL_LOG"
    exit 1
fi
