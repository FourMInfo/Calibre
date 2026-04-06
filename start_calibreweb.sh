#!/usr/bin/env bash
# start_calibreweb.sh
# Starts CalibreWeb inside a tmux session called "calibreweb"
# Attach with: tmux attach -t calibreweb

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
VENV_DIR="$HOME/Code/venv/calibre-web-env"
SESSION="calibreweb"

# Check if cps process is actually running (not just tmux session)
if pgrep -f "cps" > /dev/null; then
    echo "CalibreWeb is already running"
    echo "Attach with: tmux attach -t $SESSION"
    exit 0
fi

# Kill stale tmux session if it exists without cps running
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Stale tmux session found — cleaning up..."
    tmux kill-session -t "$SESSION"
fi

echo "Starting CalibreWeb..."
tmux new-session -d -s "$SESSION"
tmux send-keys -t "$SESSION" "source $VENV_DIR/bin/activate && cps" Enter
echo "✓ CalibreWeb started in tmux session '$SESSION'"
echo "  Attach with: tmux attach -t $SESSION"
echo "  Access at:   $CALIBRE_HOST"
