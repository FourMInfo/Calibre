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

# Kill Calibre app and worker processes. pgrep -x matches the process name
# exactly; `pgrep -f calibre` was always true here, because this script's own
# command line contains "calibreweb".
if pgrep -x calibre > /dev/null || pgrep -x calibre-parallel > /dev/null; then
    echo "Stopping Calibre..."
    killall calibre 2>/dev/null || true
    killall calibre-parallel 2>/dev/null || true
    echo "✓ Calibre stopped"
fi
