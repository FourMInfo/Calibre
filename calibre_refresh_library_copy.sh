#!/usr/bin/env bash
# calibre_refresh_library_copy.sh
# Bring the hub's library copy (HUB_LIBRARY_COPY, the mirror calibre_backup_now.sh
# writes) up to date with a snapshot that is already on the hub (HUB_BACKUP).
# The copy runs on the hub itself, disk to disk: nothing crosses the network.
#
#   calibre_refresh_library_copy.sh                          from the newest daily on the hub
#   calibre_refresh_library_copy.sh daily.YYYYMMDD_HHMMSS    from that snapshot
#   calibre_refresh_library_copy.sh [snapshot] --dry-run     show what would change; change nothing
#
# calibre_nightly_backup.sh runs it as its last step, with tonight's snapshot,
# once the snapshots have reached the hub. So the copy always starts from last
# night's backup, and a by-hand calibre_backup_now.sh sends only that day's work.
#
# The snapshot was taken with Calibre and CalibreWeb stopped, so neither has to
# be stopped here. full-text-search.db is left out, as in calibre_backup_now.sh.
# It shares calibre_backup_now.sh's lock: the two never write the copy at once.
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ── Load local config ─────────────────────────────────────────────────────────
_self_dir="$(dirname "$(readlink -f "$0")")"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"

missing_keys=""
for key in LOG_DIR KEEP_LOGS HUB_SSH_HOST HUB_BACKUP HUB_LIBRARY_COPY; do
    if [[ -z "${!key:-}" ]]; then
        missing_keys="$missing_keys $key"
    fi
done
if [[ -n "$missing_keys" ]]; then
    echo "ERROR: config.sh is missing required key(s):$missing_keys"
    echo "  Compare your config.sh against config.sh.example and add them."
    exit 1
fi

DRY_RUN=false
SNAPSHOT=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        daily.*|weekly.*|monthly.*|yearly.*)
            if [[ -n "$SNAPSHOT" || "$arg" == */* ]]; then
                echo "Usage: $0 [snapshot name] [--dry-run]"; exit 2
            fi
            SNAPSHOT="$arg" ;;
        *) echo "Usage: $0 [snapshot name] [--dry-run]"; exit 2 ;;
    esac
done

LOG_PREFIX="calibre_libcopy"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Helpers ──────────────────────────────────────────────────────────────────
ts() { date +"%Y-%m-%d %H:%M:%S"; }

# Quote one value for the hub's shell (zsh on macOS reads bash's %q quoting).
q() { printf '%q' "$1"; }

SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=20"
hub() { $SSH_CMD "$HUB_SSH_HOST" "$1"; }

prune_logs() {
    local count
    count=$( { ls -1 "$LOG_DIR"/"${LOG_PREFIX}"_*.log 2>/dev/null || true; } | wc -l | tr -d ' \n')
    if [[ "$count" -gt "$KEEP_LOGS" ]]; then
        ls -1 "$LOG_DIR"/"${LOG_PREFIX}"_*.log | sort | head -"$(( count - KEEP_LOGS ))" | xargs rm -f
    fi
}

# Files compared, counted the same way as in calibre_backup_now.sh.
COUNT_CMD="find . -type f ! -name .DS_Store ! -path ./full-text-search.db | wc -l | tr -d ' '"

# calibre_backup_now.sh's lock, and the snapshot copy's.
LOCK_DIR="$HOME/.local/state/calibre-now/lock"
HUB_LOCK_DIR="$HOME/.local/state/calibre-hub/lock"

fail() {
    echo "  ✗ FAILED: $1"
    echo "=========================================="
    echo "  Library copy refresh FAILED: $(ts)"
    echo "  Log: $LOG_FILE"
    echo "=========================================="
    prune_logs
    exit 1
}

echo "=========================================="
echo "  Hub library copy ← snapshot on the hub$( [[ "$DRY_RUN" == "true" ]] && echo " (DRY RUN)" )"
echo "  $(ts)"
echo "  Hub:  $HUB_SSH_HOST"
echo "  From: $HUB_BACKUP/${SNAPSHOT:-<newest daily>}"
echo "  To:   $HUB_LIBRARY_COPY"
echo "=========================================="

# ── One run at a time ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOCK_DIR")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    other=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
        fail "calibre_backup_now.sh or another refresh is running (pid $other)"
    fi
    echo "  Taking over a stale lock (pid ${other:-unknown} is gone)"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# A snapshot copy still running means the newest snapshot on the hub may be partial.
hub_other=$(cat "$HUB_LOCK_DIR/pid" 2>/dev/null || true)
if [[ -n "$hub_other" ]] && kill -0 "$hub_other" 2>/dev/null; then
    fail "a snapshot copy to the hub is running (pid $hub_other); try again when it is done"
fi

# ── Checks before anything is changed ─────────────────────────────────────────
echo "$(ts) Checking the hub..."
if ! hub true; then
    fail "cannot reach $HUB_SSH_HOST over ssh"
fi

HUB_DRIVE=$(echo "$HUB_LIBRARY_COPY" | cut -d'/' -f1-3)
if ! hub "mount | grep -qF $(q " on $HUB_DRIVE (")"; then
    fail "the hub's drive is not mounted at $HUB_DRIVE on $HUB_SSH_HOST"
fi
if ! hub "test -d $(q "$HUB_LIBRARY_COPY")"; then
    fail "$HUB_LIBRARY_COPY does not exist on $HUB_SSH_HOST (seed it first: see SCRIPTS.md)"
fi

if [[ -z "$SNAPSHOT" ]]; then
    SNAPSHOT=$(hub "ls -1 $(q "$HUB_BACKUP") 2>/dev/null || true" | grep -E '^daily\.' | sort | tail -1 || true)
    if [[ -z "$SNAPSHOT" ]]; then
        fail "no daily snapshot in $HUB_BACKUP on $HUB_SSH_HOST"
    fi
fi
SOURCE="$HUB_BACKUP/$SNAPSHOT"

# With --delete, a missing or empty source would empty the copy.
if ! hub "test -f $(q "$SOURCE/metadata.db")"; then
    fail "no metadata.db in $SOURCE on $HUB_SSH_HOST; not mirroring that"
fi
echo "  ✓ Snapshot: $SNAPSHOT"
echo "  ✓ Copy: $HUB_LIBRARY_COPY, drive mounted"
echo ""

# ── Copy, on the hub ──────────────────────────────────────────────────────────
echo "$(ts) Copying on $HUB_SSH_HOST..."
rsync_cmd="rsync -a --delete --exclude=.DS_Store --exclude=/full-text-search.db --stats"
if [[ "$DRY_RUN" == "true" ]]; then
    rsync_cmd="$rsync_cmd --dry-run --itemize-changes"
fi

rsync_status=0
hub "$rsync_cmd $(q "$SOURCE")/ $(q "$HUB_LIBRARY_COPY")/" || rsync_status=$?
if [[ "$rsync_status" -ne 0 ]]; then
    fail "rsync on the hub exited $rsync_status"
fi
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "=========================================="
    echo "  Dry run done, nothing changed: $(ts)"
    echo "  Log: $LOG_FILE"
    echo "=========================================="
    prune_logs
    exit 0
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo "$(ts) Verifying..."
src_md5=$(hub "md5 -q $(q "$SOURCE/metadata.db")" || true)
copy_md5=$(hub "md5 -q $(q "$HUB_LIBRARY_COPY/metadata.db")" || true)
if [[ -z "$src_md5" || "$src_md5" != "$copy_md5" ]]; then
    fail "metadata.db differs (snapshot ${src_md5:-none}, copy ${copy_md5:-none})"
fi
echo "  ✓ metadata.db the same in the snapshot and the copy"

src_count=$(hub "cd $(q "$SOURCE") && $COUNT_CMD" || true)
copy_count=$(hub "cd $(q "$HUB_LIBRARY_COPY") && $COUNT_CMD" || true)
if [[ -z "$src_count" || "$src_count" != "$copy_count" ]]; then
    fail "file count differs (snapshot ${src_count:-none}, copy ${copy_count:-none})"
fi
echo "  ✓ Same $src_count files in both"

echo ""
echo "=========================================="
echo "  Library copy refreshed from $SNAPSHOT: $(ts)"
echo "  Log: $LOG_FILE"
echo "=========================================="
prune_logs
