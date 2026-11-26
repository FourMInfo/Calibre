#!/usr/bin/env bash
# calibre_backup_permissions.sh
# Checks that the nightly backup will be allowed to read the iCloud backup folder
# and the external drive, by doing what the backup does, the way the backup does it.
#
# Why this exists:
#   macOS asks once per program before it may touch ~/Documents (where the iCloud
#   backup lives) or a removable drive. The nightly backup runs at 2am from launchd,
#   so when that question comes up, nobody answers it: the job waits, with Calibre
#   and CalibreWeb stopped, until someone clicks the dialog in the morning. It comes
#   up on a new Mac, and again after an upgrade replaces rclone (2026-11-08: an 8-hour
#   stall after brew upgraded rclone).
#
# What it does:
#   1. Starts a one-off launchd job in your login session, as the nightly job runs,
#      that calls this same script with --probe.
#   2. The probe runs, as the backup does:
#        rclone lsd "$ICLOUD_BACKUP"            (read-only listing of the iCloud folder)
#        rsync --list-only "$HOST_BACKUP/"      (read-only listing of the external drive)
#   3. Waits for the result and reports each one. If macOS shows a dialog on this
#      Mac's screen in the meantime, answer it (Allow), and the probe finishes.
#
# You start it from a terminal, but it never reads those folders from the terminal
# itself: macOS would credit that access to the terminal app, not to what launchd
# runs at night, so it would prove nothing. That is why the probe goes through launchd.
#
# Usage:
#   ./calibre_backup_permissions.sh               wait up to 300 seconds for the probe
#   ./calibre_backup_permissions.sh --timeout 60
#
# Exit status: 0 when every probe passed, 1 when one failed, 2 when no answer came
# back in time (a dialog is probably waiting on screen; answer it, then run again).
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ── Load local config ─────────────────────────────────────────────────────────
# readlink -f: run through a ~/.local/bin link, $0 is the link; config.sh is beside the real file.
_self_dir="$(dirname "$(readlink -f "$0")")"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"
SELF="$SCRIPT_DIR/$(basename "$0")"

LABEL="info.fourm.calibre-permission-check"
DOMAIN="gui/$(id -u)"

# ── Probe mode: what the launchd job runs ─────────────────────────────────────
# Writes <name>.rc and <name>.out per probe into the result directory, then a
# "done" file last, which is what the waiting side looks for.
if [[ "${1:-}" == "--probe" ]]; then
    out="${2:?--probe needs a result directory}"

    rclone_bin="$(command -v rclone || true)"
    if [[ -z "$rclone_bin" ]]; then
        echo "rclone not found on PATH ($PATH)" > "$out/icloud.out"
        echo 127 > "$out/icloud.rc"
    else
        echo "$rclone_bin" > "$out/icloud.bin"
        rc=0
        rclone lsd "$ICLOUD_BACKUP" > "$out/icloud.out" 2>&1 || rc=$?
        echo "$rc" > "$out/icloud.rc"
    fi

    # Same mount test as the nightly backup: a leftover mountpoint directory
    # is not the drive.
    host_drive=$(echo "$HOST_BACKUP" | cut -d'/' -f1-3)
    if mount | grep -qF " on $host_drive ("; then
        echo "$(command -v rsync)" > "$out/drive.bin"
        rc=0
        rsync --list-only "$HOST_BACKUP/" > "$out/drive.out" 2>&1 || rc=$?
        echo "$rc" > "$out/drive.rc"
    else
        echo "$host_drive is not mounted" > "$out/drive.out"
        echo skipped > "$out/drive.rc"
    fi

    touch "$out/done"
    exit 0
fi

# ── Normal mode ───────────────────────────────────────────────────────────────
timeout=300
if [[ "${1:-}" == "--timeout" ]]; then
    timeout="${2:?--timeout needs a number of seconds}"
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--timeout SECONDS]"
    exit 1
fi

missing_keys=""
for key in ICLOUD_BACKUP HOST_BACKUP; do
    if [[ -z "${!key:-}" ]]; then
        missing_keys="$missing_keys $key"
    fi
done
if [[ -n "$missing_keys" ]]; then
    echo "ERROR: config.sh is missing required key(s):$missing_keys"
    exit 1
fi

result_dir="$(mktemp -d -t calibre-permissions)"
plist="$result_dir/$LABEL.plist"

# Build the plist with plutil rather than from a template: paths go in as
# plain strings, so a path containing & or < needs no XML escaping.
plutil -create xml1 "$plist"
plutil -insert Label -string "$LABEL" "$plist"
plutil -insert ProgramArguments -array "$plist"
plutil -insert ProgramArguments -string /bin/bash -append "$plist"
plutil -insert ProgramArguments -string "$SELF" -append "$plist"
plutil -insert ProgramArguments -string --probe -append "$plist"
plutil -insert ProgramArguments -string "$result_dir" -append "$plist"
plutil -insert RunAtLoad -bool true "$plist"
plutil -insert StandardOutPath -string "$result_dir/job.log" "$plist"
plutil -insert StandardErrorPath -string "$result_dir/job.log" "$plist"
plutil -lint "$plist" > /dev/null

# A job left from an earlier run that timed out, and that run's result folder
# (the same mktemp template, in the same TMPDIR). This run's own folder is kept.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for stale in "$(dirname "$result_dir")"/calibre-permissions.*; do
    [[ -d "$stale" && "$stale" != "$result_dir" ]] && rm -rf "$stale"
done

echo "Checking the backup's access to:"
echo "  iCloud folder : $ICLOUD_BACKUP"
echo "  External drive: $HOST_BACKUP"
echo ""
launchctl bootstrap "$DOMAIN" "$plist"

waited=0
hinted=false
while [[ ! -f "$result_dir/done" ]]; do
    if [[ "$waited" -ge "$timeout" ]]; then
        echo ""
        echo "No answer after $timeout seconds."
        echo "  A macOS dialog is probably waiting on this Mac's screen, asking whether"
        echo "  bash, rclone or rsync may access your Documents folder or a removable"
        echo "  volume. Click Allow, then run this script again to confirm."
        echo "  (The waiting job is left alone so the dialog stays answerable.)"
        exit 2
    fi
    if [[ "$waited" -ge 10 && "$hinted" == "false" ]]; then
        echo "Still waiting. If a dialog appears on this Mac's screen asking for access"
        echo "to Documents or a removable volume, click Allow."
        hinted=true
    fi
    sleep 2
    waited=$(( waited + 2 ))
done

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

failed=0
report() {
    local name="$1" what="$2"
    local rc
    rc="$(cat "$result_dir/$name.rc")"
    local bin=""
    [[ -f "$result_dir/$name.bin" ]] && bin=" ($(cat "$result_dir/$name.bin"))"
    if [[ "$rc" == "0" ]]; then
        echo "  ✓ $what$bin"
    elif [[ "$rc" == "skipped" ]]; then
        echo "  - $what: skipped, $(cat "$result_dir/$name.out")"
    else
        failed=1
        echo "  ✗ $what$bin failed (exit $rc):"
        sed 's/^/      /' "$result_dir/$name.out" | head -5
        if grep -qi "not permitted" "$result_dir/$name.out"; then
            echo "    macOS refused access. System Settings → Privacy & Security →"
            echo "    Files and Folders (or Full Disk Access): allow the program named above,"
            echo "    then run this script again."
        fi
    fi
}

echo "Result:"
report icloud "iCloud folder, read by rclone"
report drive  "External drive, read by rsync"

rm -rf "$result_dir"
exit "$failed"
