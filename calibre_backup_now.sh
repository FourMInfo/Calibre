#!/usr/bin/env bash
# calibre_backup_now.sh
# Copy the live library to the backup hub now, by hand, after a day of
# metadata or tagging work you do not want to lose before the 02:00 nightly.
#
#   calibre_backup_now.sh            copy
#   calibre_backup_now.sh --dry-run  show what would be sent and deleted; change nothing
#
# What it does:
#   1. refuses to start while the Calibre app is open (quit it first: a by-hand
#      run should not kill an edit in progress, as the nightly does)
#   2. stops CalibreWeb (stop_calibreweb.sh), so metadata.db holds still
#   3. rsync -a --delete of LIBRARY to HUB_SSH_HOST:HUB_LIBRARY_COPY over ssh
#   4. checks metadata.db and the file count are the same on both ends
#   5. starts CalibreWeb again, also when a step above failed
#
# The copy is a mirror, not a snapshot: it holds the library as it was at the
# last run. The nightly's snapshots (HOST_BACKUP, and their copy on the hub)
# keep the history. full-text-search.db (about 18 GB, rewritten whenever books
# are added) is left out; the nightly snapshots carry it.
#
# Run by name from anywhere through ~/.local/bin (Dotfiles.Private links.txt):
# the script resolves that link to find config.sh and its sibling scripts.
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ── Load local config ─────────────────────────────────────────────────────────
# readlink -f: when run through the ~/.local/bin link, $0 is the link, and
# config.sh lives beside the real file.
_self_dir="$(dirname "$(readlink -f "$0")")"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"

missing_keys=""
for key in LIBRARY LOG_DIR KEEP_LOGS CALIBREDB HUB_SSH_HOST HUB_LIBRARY_COPY; do
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
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Usage: $0 [--dry-run]"; exit 2 ;;
    esac
done

LOG_PREFIX="calibre_now"
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

# Files the copy compares, counted the same way on both ends (see EXCLUDES).
COUNT_CMD="find . -type f ! -name .DS_Store ! -path ./full-text-search.db | wc -l | tr -d ' '"

LOCK_DIR="$HOME/.local/state/calibre-now/lock"
HUB_LOCK_DIR="$HOME/.local/state/calibre-hub/lock"

WEB_STOPPED=false
restart_web() {
    if [[ "$WEB_STOPPED" == "true" ]]; then
        WEB_STOPPED=false
        echo ""
        echo "$(ts) Starting CalibreWeb..."
        if bash "$SCRIPT_DIR/start_calibreweb.sh"; then
            echo "  ✓ CalibreWeb started"
        else
            echo "  ✗ start_calibreweb.sh returned an error: CalibreWeb may not be running"
            echo "    Start it by hand: $SCRIPT_DIR/start_calibreweb.sh"
        fi
    fi
}

on_exit() {
    restart_web
    rm -rf "$LOCK_DIR"
}

fail() {
    echo "  ✗ FAILED: $1"
    restart_web
    echo "=========================================="
    echo "  Library copy to the hub FAILED: $(ts)"
    echo "  Log: $LOG_FILE"
    echo "=========================================="
    prune_logs
    exit 1
}

echo "=========================================="
echo "  Calibre library → backup hub, now$( [[ "$DRY_RUN" == "true" ]] && echo " (DRY RUN)" )"
echo "  $(ts)"
echo "  From: $LIBRARY"
echo "  To:   $HUB_SSH_HOST:$HUB_LIBRARY_COPY"
echo "=========================================="

# ── One run at a time ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOCK_DIR")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    other=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
        fail "another run is in progress (pid $other)"
    fi
    echo "  Taking over a stale lock (pid ${other:-unknown} is gone)"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"
trap on_exit EXIT

# Not while the nightly runs: it stops and starts CalibreWeb itself.
if pgrep -f "calibre_nightly_backup.sh" > /dev/null; then
    fail "the nightly backup is running; try again when it is done"
fi
hub_other=$(cat "$HUB_LOCK_DIR/pid" 2>/dev/null || true)
if [[ -n "$hub_other" ]] && kill -0 "$hub_other" 2>/dev/null; then
    fail "a snapshot copy to the hub is running (pid $hub_other); try again when it is done"
fi

# ── Checks before anything is stopped or sent ─────────────────────────────────
echo "$(ts) Checking both ends..."

# With --delete, a missing or empty library would empty the hub's copy.
if [[ ! -f "$LIBRARY/metadata.db" ]]; then
    fail "no metadata.db in $LIBRARY; not mirroring that to the hub"
fi
echo "  ✓ Library: $LIBRARY"

# The Calibre app, matched on its bundle as in stop_calibreweb.sh.
CALIBRE_APP="${CALIBREDB%%/Contents/*}"
if [[ "$CALIBRE_APP" == "$CALIBREDB" ]]; then
    fail "CALIBREDB in config.sh is not a path inside calibre.app"
fi
if [[ "$DRY_RUN" != "true" ]] && pgrep -f "$CALIBRE_APP" > /dev/null; then
    fail "Calibre is open. Quit it, then run this again"
fi

if ! hub true; then
    fail "cannot reach $HUB_SSH_HOST over ssh"
fi

# If the hub's drive is missing, rsync would fill its internal disk under /Volumes.
HUB_DRIVE=$(echo "$HUB_LIBRARY_COPY" | cut -d'/' -f1-3)
if ! hub "mount | grep -qF $(q " on $HUB_DRIVE (")"; then
    fail "the hub's drive is not mounted at $HUB_DRIVE on $HUB_SSH_HOST"
fi
if ! hub "test -d $(q "$(dirname "$HUB_LIBRARY_COPY")")"; then
    fail "$(dirname "$HUB_LIBRARY_COPY") does not exist on $HUB_SSH_HOST"
fi
echo "  ✓ Hub: $HUB_SSH_HOST, drive mounted"
echo ""

# ── Stop CalibreWeb ───────────────────────────────────────────────────────────
if [[ "$DRY_RUN" != "true" ]]; then
    echo "$(ts) Stopping CalibreWeb..."
    WEB_STOPPED=true
    if ! bash "$SCRIPT_DIR/stop_calibreweb.sh"; then
        fail "stop_calibreweb.sh returned an error"
    fi
    echo ""
fi

# ── Copy ──────────────────────────────────────────────────────────────────────
echo "$(ts) Copying..."
rsync_opts=(-a --delete --exclude='.DS_Store' --exclude='/full-text-search.db' --stats -e "$SSH_CMD")
if [[ "$DRY_RUN" == "true" ]]; then
    rsync_opts+=(--dry-run --itemize-changes)
fi

rsync_status=0
rsync "${rsync_opts[@]}" "$LIBRARY/" "$HUB_SSH_HOST:$(q "$HUB_LIBRARY_COPY")/" || rsync_status=$?
if [[ "$rsync_status" -ne 0 ]]; then
    fail "rsync exited $rsync_status"
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
local_md5=$(md5 -q "$LIBRARY/metadata.db")
hub_md5=$(hub "md5 -q $(q "$HUB_LIBRARY_COPY/metadata.db")" || true)
if [[ "$local_md5" != "$hub_md5" ]]; then
    fail "metadata.db differs on the hub (here $local_md5, hub ${hub_md5:-none})"
fi
echo "  ✓ metadata.db the same on both"

local_count=$(cd "$LIBRARY" && eval "$COUNT_CMD")
hub_count=$(hub "cd $(q "$HUB_LIBRARY_COPY") && $COUNT_CMD" || true)
if [[ "$local_count" != "$hub_count" ]]; then
    fail "file count differs (here $local_count, hub ${hub_count:-none})"
fi
echo "  ✓ Same $local_count files on both"

restart_web

echo ""
echo "=========================================="
echo "  Library copy to the hub complete: $(ts)"
echo "  Log: $LOG_FILE"
echo "=========================================="
prune_logs
