#!/usr/bin/env bash
# calibre_nightly_backup.sh
# Nightly backup of Calibre library with rotation
#
# What this script does:
#   1. Stops CalibreWeb and Calibre
#   2. Waits 60 seconds for clean shutdown
#   3. Runs integrity check on library (logs corrupt files, does not abort)
#   4. rsyncs library to external drive (with --link-dest deduplication)
#   5. rsyncs snapshot to iCloud Documents folder
#   6. Rotates snapshots: 7 dailies, 4 weeklies, 2 monthlies, 1 yearly
#   7. Restarts CalibreWeb in tmux
#
# Install as launchd job: use install_calibre_backup_launchd.sh
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

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
VENV_DIR="$HOME/Code/venv/calibre-web-env"
SCRIPTS_DIR="$HOME/Code/FourM/Calibre"
LOG_DIR="$HOME/Code/FourM/Logs"
LOG_FILE="$LOG_DIR/calibre_backup_$(date +%Y%m%d_%H%M%S).log"

# ── Helpers ──────────────────────────────────────────────────────────────────
ts() { date +"%Y-%m-%d %H:%M:%S"; }

# ── Setup ─────────────────────────────────────────────────────────────────────
# Increase file descriptor limit globally for large library operations
ulimit -n 65536 2>/dev/null || true

mkdir -p "$LOG_DIR"
mkdir -p "$ICLOUD_BACKUP"

# Check external drive is mounted before proceeding
HOST_DRIVE=$(dirname "$HOST_BACKUP")
if [[ ! -d "$HOST_DRIVE" ]]; then
    # Log to a fallback log since main log dir may also be on external
    WARN_LOG="$LOG_DIR/calibre_backup_$(date +%Y%m%d_%H%M%S)_WARNING.log"
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

# ── Helper: rotate snapshots ──────────────────────────────────────────────────
rotate_snapshots() {
    local backup_root="$1"
    local is_remote="${2:-false}"
    local remote_host="${3:-}"

    run_cmd() {
        if [[ "$is_remote" == "true" ]]; then
            ssh "$remote_host" "$@"
        else
            eval "$@"
        fi
    }

    local now
    now=$(date +%s)
    local dow
    dow=$(date +%u)  # 1=Monday 7=Sunday
    local dom
    dom=$(date +%d)  # day of month
    local month
    month=$(date +%m)

    # Promote daily → weekly (on Sunday)
    if [[ "$dow" == "7" ]]; then
        local latest_daily
        latest_daily=$(run_cmd "ls -1d '$backup_root'/daily.* 2>/dev/null | sort | tail -1" || true)
        if [[ -n "$latest_daily" ]]; then
            local weekly_name="$backup_root/weekly.$(date +%Y%m%d)"
            run_cmd "mkdir -p '$weekly_name' && cp -al '$latest_daily/.' '$weekly_name/'" || true
            echo "  → Promoted to weekly: $weekly_name"
        fi
    fi

    # Promote weekly → monthly (on 1st of month)
    if [[ "$dom" == "01" ]]; then
        local latest_weekly
        latest_weekly=$(run_cmd "ls -1d '$backup_root'/weekly.* 2>/dev/null | sort | tail -1" || true)
        if [[ -n "$latest_weekly" ]]; then
            local monthly_name="$backup_root/monthly.$(date +%Y%m)"
            run_cmd "mkdir -p '$monthly_name' && cp -al '$latest_weekly/.' '$monthly_name/'" || true
            echo "  → Promoted to monthly: $monthly_name"
        fi
    fi

    # Promote monthly → yearly (on Jan 1st)
    if [[ "$dom" == "01" && "$month" == "01" ]]; then
        local latest_monthly
        latest_monthly=$(run_cmd "ls -1d '$backup_root'/monthly.* 2>/dev/null | sort | tail -1" || true)
        if [[ -n "$latest_monthly" ]]; then
            local yearly_name="$backup_root/yearly.$(date +%Y)"
            run_cmd "mkdir -p '$yearly_name' && cp -al '$latest_monthly/.' '$yearly_name/'" || true
            echo "  → Promoted to yearly: $yearly_name"
        fi
    fi

    # Prune old snapshots
    prune() {
        local prefix="$1"
        local keep="$2"
        local count
        count=$(run_cmd "ls -1d '$backup_root'/${prefix}.* 2>/dev/null | wc -l | tr -d ' \n'" || echo "0")
        if [[ "$count" -gt "$keep" ]]; then
            local to_delete=$(( count - keep ))
            run_cmd "ls -1d '$backup_root'/${prefix}.* 2>/dev/null | sort | head -$to_delete | xargs rm -rf" || true
            echo "  → Pruned $to_delete old ${prefix} snapshot(s)"
        fi
    }

    prune "daily"   "$KEEP_DAILY"
    prune "weekly"  "$KEEP_WEEKLY"
    prune "monthly" "$KEEP_MONTHLY"
    prune "yearly"  "$KEEP_YEARLY"
}

# ── Step 1: Stop CalibreWeb and Calibre ───────────────────────────────────────
echo "$(ts) [ 1/7 ] Stopping CalibreWeb and Calibre..."

if [[ -f "$SCRIPTS_DIR/stop_calibreweb.sh" ]]; then
    bash "$SCRIPTS_DIR/stop_calibreweb.sh"
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

if [[ -f "$SCRIPTS_DIR/calibre_check_integrity.sh" ]]; then
    bash "$SCRIPTS_DIR/calibre_check_integrity.sh" "$LIBRARY" "$LOG_DIR" > "/dev/null"
    echo "  ✓ Integrity check complete — review $LOG_DIR for any corrupt files"
else
    echo "  ⚠ calibre_check_integrity.sh not found — skipping integrity check"
fi
echo ""

# ── Step 4: rsync to external drive ─────────────────────────────────────────
echo "$(ts) [ 4/7 ] Backing up to external drive..."

SNAPSHOT_NAME="daily.$(date +%Y%m%d_%H%M%S)"
HOST_SNAPSHOT="$HOST_BACKUP/$SNAPSHOT_NAME"

if [[ "$HOST_MOUNTED" == "false" ]]; then
    echo "  ⚠ External drive not mounted — skipping external backup"
else
    # Find last snapshot for --link-dest (safe glob — no error if none exist yet)
    HOST_LAST=$(find "$HOST_BACKUP" -maxdepth 1 -type d \( -name "daily.*" -o -name "weekly.*" -o -name "monthly.*" -o -name "yearly.*" \) 2>/dev/null | sort | tail -1 || true)

    if [[ -n "$HOST_LAST" ]]; then
        echo "  Using --link-dest: $HOST_LAST"
        rsync -aH --delete --exclude='.DS_Store' --link-dest="$HOST_LAST" "$LIBRARY/" "$HOST_SNAPSHOT/"
    else
        echo "  No previous snapshot found — full backup"
        rsync -aH --delete --exclude='.DS_Store' "$LIBRARY/" "$HOST_SNAPSHOT/"
    fi

    echo "  ✓ External drive backup complete: $HOST_SNAPSHOT"
fi
echo ""

# ── Step 5: rsync to iCloud ───────────────────────────────────────────────────
echo "$(ts) [ 5/7 ] Backing up to iCloud..."

# Increase file descriptor limit for large library rsync
ulimit -n 65536 2>/dev/null || true

ICLOUD_LAST=$(find "$ICLOUD_BACKUP" -maxdepth 1 -type d \( -name "daily.*" -o -name "weekly.*" -o -name "monthly.*" -o -name "yearly.*" \) 2>/dev/null | sort | tail -1 || true)

if [[ -n "$ICLOUD_LAST" ]]; then
    echo "  Using --link-dest: $ICLOUD_LAST"
    rsync -aH --delete --exclude='.DS_Store' --link-dest="$ICLOUD_LAST" "$LIBRARY/" "$ICLOUD_BACKUP/$SNAPSHOT_NAME/"
else
    echo "  No previous snapshot found in iCloud — full backup"
    rsync -aH --delete --exclude='.DS_Store' "$LIBRARY/" "$ICLOUD_BACKUP/$SNAPSHOT_NAME/"
fi

echo "  ✓ iCloud backup complete"
echo ""

# ── Step 7: Rotate snapshots ─────────────────────────────────────────────────
echo "$(ts) [ 6/7 ] Rotating snapshots..."

if [[ "$HOST_MOUNTED" == "true" ]]; then
    echo "  External drive:"
    rotate_snapshots "$HOST_BACKUP" "false"
else
    echo "  External drive: skipped (drive not mounted)"
fi

echo "  iCloud:"
rotate_snapshots "$ICLOUD_BACKUP" "false"

echo "  ✓ Rotation complete"
echo ""

# ── Step 8: Restart CalibreWeb ────────────────────────────────────────────────
echo "$(ts) [ 7/7 ] Restarting CalibreWeb..."

if [[ -f "$SCRIPTS_DIR/start_calibreweb.sh" ]]; then
    bash "$SCRIPTS_DIR/start_calibreweb.sh"
    echo "  ✓ CalibreWeb restarted"
else
    echo "  ⚠ start_calibreweb.sh not found at $SCRIPTS_DIR"
    echo "    Start manually with: source $VENV_DIR/bin/activate && cps &"
fi

echo ""
echo "=========================================="
echo "  Backup complete: $(ts)"
echo "  Log: $LOG_FILE"
echo "=========================================="

# ── Log rotation: keep last 30 logs ──────────────────────────────────────────
log_count=$(ls -1 "$LOG_DIR"/calibre_backup_*.log 2>/dev/null | wc -l | tr -d ' \n')
if [[ "$log_count" -gt 30 ]]; then
    to_delete=$(( log_count - 30 ))
    ls -1 "$LOG_DIR"/calibre_backup_*.log | sort | head -"$to_delete" | xargs rm -f
    echo "  → Pruned $to_delete old log(s)"
fi
