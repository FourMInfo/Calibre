#!/usr/bin/env bash
# stop_calibreweb.sh
# Gracefully stops CalibreWeb, Calibre app and all Calibre processes

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ── Load local config ─────────────────────────────────────────────────────────
_self_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"

SESSION="$TMUX_SESSION"

# Match the venv's cps binary rather than a bare "cps". pgrep/pkill -f test the
# whole command line, so a bare pattern matches anything containing those three
# letters. With pkill -KILL below, a false match kills an innocent process.
CPS_PATTERN="$VENV_DIR/bin/cps"

# SIGTERM the cps process
if pgrep -f "$CPS_PATTERN" > /dev/null; then
    echo "Stopping CalibreWeb (SIGTERM)..."
    pkill -TERM -f "$CPS_PATTERN" || true
    sleep 5
    # Force kill if still running
    if pgrep -f "$CPS_PATTERN" > /dev/null; then
        echo "Force killing CalibreWeb..."
        pkill -KILL -f "$CPS_PATTERN" || true
    fi
    echo "✓ CalibreWeb stopped"
else
    echo "CalibreWeb is not running"
fi

# Kill tmux session if exists. kill-session takes the whole session down,
# both the cps window and the debugging shell window, in one go.
if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
    echo "✓ tmux session '$SESSION' closed"
fi

# Kill Calibre app and worker processes.
#
# Anchor on the app bundle rather than matching by name. killall is exact-name,
# so the old `killall calibre` + `killall calibre-parallel` pair only covered the
# two workers we happened to know about; anything else Calibre spawns
# (ebook-convert, calibre-server, ...) survived. Every worker does share the
# bundle root at the front of its command line, however deeply nested:
#   /Applications/calibre.app/Contents/ebook-viewer.app/.../MacOS/calibre-parallel
# A bare `-f calibre` would go too far the other way and match anything with the
# word in its argv — a shell in ~/Calibre Library, a tail on calibre_web_*.log,
# the venv path (calibre-web-env) — a false "Stopping Calibre..." at best and,
# with a kill attached, a real hazard.
#
# This does not match the script itself: macOS pgrep excludes the process that
# invoked it, so `stop_calibreweb.sh` never sees its own command line here.
CALIBRE_APP="${CALIBREDB%%/Contents/*}"   # -> /Applications/calibre.app

if [[ -z "$CALIBREDB" || "$CALIBRE_APP" == "$CALIBREDB" ]]; then
    # Either unset, or not a path inside the bundle, so the strip did nothing.
    # Bail out — an empty pattern makes `pkill -f ""` match every process.
    echo "WARNING: CALIBREDB is not a path inside calibre.app — skipping Calibre"
    echo "  process cleanup. Set CALIBREDB in config.sh."
elif pgrep -f "$CALIBRE_APP" > /dev/null; then
    echo "Stopping Calibre (SIGTERM)..."
    pkill -TERM -f "$CALIBRE_APP" || true
    sleep 3
    if pgrep -f "$CALIBRE_APP" > /dev/null; then
        echo "Force killing Calibre..."
        pkill -KILL -f "$CALIBRE_APP" || true
    fi
    echo "✓ Calibre stopped"
else
    echo "Calibre is not running"
fi
