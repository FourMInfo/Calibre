#!/usr/bin/env bash
# calibre_backup_to_hub.sh
# Copy the external drive's snapshots (HOST_BACKUP) to the backup hub over ssh,
# keeping their hard links, so the hub can take them off-site.
#
#   ./calibre_backup_to_hub.sh                  copy
#   ./calibre_backup_to_hub.sh --dry-run        show what would be sent and deleted; change nothing
#   ./calibre_backup_to_hub.sh --allow-deletes  copy even if more than MAX_HUB_SNAPSHOT_DELETES
#                                               snapshots would be deleted on the hub
#
# calibre_nightly_backup.sh calls it as its last step, after a clean snapshot
# and rotation, when HUB_SSH_HOST is set. It can be run by hand at any time.
# The first run sends the whole library; later runs send about a night's
# changes.
#
# How: one `rsync -aH --delete` of the whole snapshot tree. -H keeps the hard
# links between the snapshots, and links a new snapshot's unchanged files to
# the copies the hub already has, so nothing unchanged is sent twice.
# Snapshots pruned on the drive are pruned on the hub.
#
# Syncthing cannot do this: it does not keep hard links, so every snapshot
# would arrive as a full copy of the library.
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ── Load local config ─────────────────────────────────────────────────────────
_self_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"

missing_keys=""
for key in HOST_BACKUP LOG_DIR KEEP_LOGS HUB_SSH_HOST HUB_BACKUP; do
    if [[ -z "${!key:-}" ]]; then
        missing_keys="$missing_keys $key"
    fi
done
if [[ -n "$missing_keys" ]]; then
    echo "ERROR: config.sh is missing required key(s):$missing_keys"
    echo "  Compare your config.sh against config.sh.example and add them."
    exit 1
fi
MAX_HUB_SNAPSHOT_DELETES="${MAX_HUB_SNAPSHOT_DELETES:-3}"

DRY_RUN=false
ALLOW_DELETES=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=true ;;
        --allow-deletes) ALLOW_DELETES=true ;;
        *) echo "Usage: $0 [--dry-run] [--allow-deletes]"; exit 2 ;;
    esac
done

LOG_PREFIX="calibre_hub"
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

LOCK_DIR="$HOME/.local/state/calibre-hub/lock"
release_lock() { rm -rf "$LOCK_DIR"; }

fail() {
    echo "  ✗ FAILED: $1"
    echo "=========================================="
    echo "  Copy to the hub FAILED: $(ts)"
    echo "  Log: $LOG_FILE"
    echo "=========================================="
    prune_logs
    exit 1
}

# Snapshot names (daily.*, weekly.*, monthly.*, yearly.*), one per line, sorted.
only_snapshots() { grep -E '^(daily|weekly|monthly|yearly)\.' | sort || true; }

echo "=========================================="
echo "  Calibre snapshots → backup hub$( [[ "$DRY_RUN" == "true" ]] && echo " (DRY RUN)" )"
echo "  $(ts)"
echo "  From: $HOST_BACKUP"
echo "  To:   $HUB_SSH_HOST:$HUB_BACKUP"
echo "=========================================="

# ── One run at a time ─────────────────────────────────────────────────────────
# A first copy by hand can still be running when the 02:00 backup calls this.
# A lock left by a run that died is taken over (its process is gone).
mkdir -p "$(dirname "$LOCK_DIR")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    other=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
        fail "another copy to the hub is running (pid $other)"
    fi
    echo "  Taking over a stale lock (pid ${other:-unknown} is gone)"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"
trap release_lock EXIT

# ── Checks before anything is sent ────────────────────────────────────────────
echo "$(ts) Checking both ends..."

# The drive, as in calibre_nightly_backup.sh: `mount`, not `[[ -d ]]`, because
# an unclean ejection can leave an empty mountpoint folder behind.
HOST_DRIVE=$(echo "$HOST_BACKUP" | cut -d'/' -f1-3)
if ! mount | grep -qF " on $HOST_DRIVE ("; then
    fail "the external drive is not mounted at $HOST_DRIVE"
fi

local_list=$( { ls -1 "$HOST_BACKUP" 2>/dev/null || true; } | only_snapshots)
local_count=$(printf '%s' "$local_list" | grep -c . || true)
if ! printf '%s\n' "$local_list" | grep -q '^daily\.'; then
    # With --delete, a missing or emptied source would empty the hub's copy.
    fail "no daily snapshot in $HOST_BACKUP ($local_count snapshot(s) in all); not mirroring that to the hub"
fi
echo "  ✓ Drive: $local_count snapshots"

if ! hub true; then
    fail "cannot reach $HUB_SSH_HOST over ssh (needs a key that works without a passphrase or agent)"
fi

# The same mount test on the hub: if its drive is missing, rsync would fill
# the hub's internal disk under /Volumes instead.
HUB_DRIVE=$(echo "$HUB_BACKUP" | cut -d'/' -f1-3)
if ! hub "mount | grep -qF $(q " on $HUB_DRIVE (")"; then
    fail "the hub's drive is not mounted at $HUB_DRIVE on $HUB_SSH_HOST"
fi
if ! hub "test -d $(q "$(dirname "$HUB_BACKUP")")"; then
    fail "$(dirname "$HUB_BACKUP") does not exist on $HUB_SSH_HOST"
fi
echo "  ✓ Hub: $HUB_SSH_HOST, drive mounted"

hub_list=$(hub "ls -1 $(q "$HUB_BACKUP") 2>/dev/null || true" | only_snapshots)
to_add=$(comm -23 <(printf '%s\n' "$local_list") <(printf '%s\n' "$hub_list") | grep . || true)
to_delete=$(comm -13 <(printf '%s\n' "$local_list") <(printf '%s\n' "$hub_list") | grep . || true)
delete_count=$(printf '%s' "$to_delete" | grep -c . || true)

echo "  New on the hub:     ${to_add:-(none)}" | tr '\n' ' '; echo ""
echo "  Deleted on the hub: ${to_delete:-(none)}" | tr '\n' ' '; echo ""

# A normal night deletes one daily, and on some nights a weekly or monthly.
# Many more means the drive lost snapshots: stop before the hub loses them too.
if [[ "$delete_count" -gt "$MAX_HUB_SNAPSHOT_DELETES" && "$ALLOW_DELETES" != "true" ]]; then
    fail "$delete_count snapshots would be deleted on the hub (limit $MAX_HUB_SNAPSHOT_DELETES, MAX_HUB_SNAPSHOT_DELETES in config.sh). Check the drive; if it is right, run again with --allow-deletes"
fi

# Names starting or ending with a space: a warning, not a failure. On
# 2026-11-24 one such name (a Calibre data file) arrived on the hub without its
# space and failed the copy; the cause was not found, and tests of openrsync
# keep such names. New names come in with the newest snapshot, so only that
# one is searched (about a second).
newest_daily=$(printf '%s\n' "$local_list" | grep '^daily\.' | tail -1)
spaced=$(find "$HOST_BACKUP/$newest_daily" \( -name ' *' -o -name '* ' \) 2>/dev/null || true)
if [[ -n "$spaced" ]]; then
    echo "  ⚠ WARNING: names starting or ending with a space in $newest_daily (shown in [ ]):"
    printf '%s\n' "$spaced" | while IFS= read -r p; do
        rel=${p#"$HOST_BACKUP/$newest_daily/"}
        dir=${rel%/*}; [[ "$dir" == "$rel" ]] && dir="."
        echo "      [${rel##*/}]  in $dir"
    done
    echo "    Rename them in the library. One such name failed the hub copy on 2026-11-24."
else
    echo "  ✓ No names starting or ending with a space in $newest_daily"
fi
echo ""

# ── Copy ──────────────────────────────────────────────────────────────────────
echo "$(ts) Copying..."
rsync_opts=(-aH --delete --exclude='.DS_Store' --stats -e "$SSH_CMD")
if [[ "$DRY_RUN" == "true" ]]; then
    rsync_opts+=(--dry-run)
fi

rsync_status=0
rsync "${rsync_opts[@]}" "$HOST_BACKUP/" "$HUB_SSH_HOST:$(q "$HUB_BACKUP")/" || rsync_status=$?
if [[ "$rsync_status" -ne 0 ]]; then
    fail "rsync exited $rsync_status"
fi
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "=========================================="
    echo "  Dry run done, nothing changed: $(ts)"
    echo "  Note: a dry run counts every hard-linked path as a transfer, so its"
    echo "  sizes are the snapshots' full size. A real copy sends each file once"
    echo "  (measure with: du -sh \"$HOST_BACKUP\")."
    echo "  Log: $LOG_FILE"
    echo "=========================================="
    prune_logs
    exit 0
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo "$(ts) Verifying..."
hub_list=$(hub "ls -1 $(q "$HUB_BACKUP") 2>/dev/null || true" | only_snapshots)
if [[ "$hub_list" != "$local_list" ]]; then
    fail "the hub's snapshots differ from the drive's after the copy:
$(diff <(printf '%s\n' "$local_list") <(printf '%s\n' "$hub_list") || true)"
fi
echo "  ✓ Same $local_count snapshots on both"

# Hard links: with more than one snapshot, an unchanged book in the newest
# daily shares its file with the older snapshots. If no file there has a
# second link, the snapshots arrived as full copies.
if [[ "$local_count" -gt 1 ]]; then
    linked=$(hub "find $(q "$HUB_BACKUP/$newest_daily") -type f -links +1 -print -quit" || true)
    if [[ -z "$linked" ]]; then
        fail "no hard links in $newest_daily on the hub: the snapshots were copied as full copies"
    fi
    echo "  ✓ Hard links kept ($newest_daily shares files with the older snapshots)"
fi

echo ""
echo "=========================================="
echo "  Copy to the hub complete: $(ts)"
echo "  Log: $LOG_FILE"
echo "=========================================="
prune_logs
