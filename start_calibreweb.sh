#!/usr/bin/env bash
# start_calibreweb.sh
# Starts CalibreWeb inside a tmux session with two windows:
#   cps   — CalibreWeb itself. Its application log is written by CalibreWeb
#           to $CALIBRE_WEB_CONFIG and is neither copied nor rotated here.
#   shell — an interactive shell with the venv already active, for debugging
# Attach with: tmux attach -t calibreweb

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
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"

SESSION="$TMUX_SESSION"

# Check if cps process is actually running (not just tmux session).
# Match the venv's cps binary, not a bare "cps" — pgrep -f tests the whole
# command line, so a bare pattern matches anything containing those three
# letters and makes this script refuse to start for no reason.
if pgrep -f "$VENV_DIR/bin/cps" > /dev/null; then
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

# Run cps as the window's own command rather than typing it into an
# interactive shell with send-keys. send-keys races the shell's startup
# and any rc-file prompt (oh-my-zsh's update prompt, for one) eats the
# first characters, leaving cps unlaunched. Handing the command straight
# to tmux means no shell and no prompt to race.
#
# cps's output is not captured anywhere. CalibreWeb writes its own
# application log to $CALIBRE_WEB_CONFIG and manages it itself; a second
# copy in $LOG_DIR was one log too many, and a fresh timestamped file per
# start meant the real log was the one nobody was reading. What reaches
# the pane here is the startup banner and anything cps prints before its
# own logging is up — visible with `tmux attach`, and gone when the
# session is killed, which is what it is worth.
#
# `exec` into a login shell afterwards so the window survives cps exiting
# and you can read the traceback instead of watching the pane disappear.
CPS_CMD="source \"$VENV_DIR/bin/activate\"; cps; echo; echo \"[cps exited — shell follows]\"; exec \"${SHELL:-/bin/zsh}\" -i"
tmux new-session -d -s "$SESSION" -n cps -c "$HOME" "/bin/bash -c '$CPS_CMD'"

# Second window: a normal interactive shell for poking around. The venv is
# activated after the rc files have loaded, so the venv's python takes
# precedence over anything .zshrc prepends to PATH.
tmux new-window -t "$SESSION" -n shell -c "$HOME"
tmux send-keys -t "$SESSION:shell" "source \"$VENV_DIR/bin/activate\"" Enter

tmux select-window -t "$SESSION:cps"

echo "✓ CalibreWeb started in tmux session '$SESSION'"
echo "  Attach with: tmux attach -t $SESSION"
echo "  Windows:     cps (CalibreWeb), shell (venv active)"
echo "  cps log:     $CALIBRE_WEB_CONFIG/calibre-web.log (written by CalibreWeb)"
echo "  Access at:   $CALIBRE_HOST"
