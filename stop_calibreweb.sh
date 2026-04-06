#!/usr/bin/env bash
# stop_calibreweb.sh
# Gracefully stops CalibreWeb, Calibre app and all Calibre processes

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

SESSION="calibreweb"

# SIGTERM the cps process
if pgrep -f "cps" > /dev/null; then
    echo "Stopping CalibreWeb (SIGTERM)..."
    pkill -TERM -f "cps" || true
    sleep 5
    # Force kill if still running
    if pgrep -f "cps" > /dev/null; then
        echo "Force killing CalibreWeb..."
        pkill -KILL -f "cps" || true
    fi
    echo "✓ CalibreWeb stopped"
else
    echo "CalibreWeb is not running"
fi

# Kill tmux session if exists
if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
    echo "✓ tmux session '$SESSION' closed"
fi

# Kill Calibre app and worker processes
if pgrep -f "calibre" > /dev/null; then
    echo "Stopping Calibre..."
    killall calibre 2>/dev/null || true
    killall calibre-parallel 2>/dev/null || true
    echo "✓ Calibre stopped"
fi
