#!/usr/bin/env bash
# update_calibreweb.sh
# Keeps CalibreWeb's venv patched without guessing: the live venv only ever gets
# a pinned set of versions that was built and checked somewhere else first.
#
# Usage:
#   ./update_calibreweb.sh check     read-only: known vulnerabilities (pip-audit)
#                                    and newer versions, for the live venv
#   ./update_calibreweb.sh propose   build a throwaway venv from
#                                    calibreweb-requirements.in with the newest
#                                    versions allowed; pip check and pip-audit it;
#                                    write the result to calibreweb-requirements.txt
#                                    in this repo. CalibreWeb is not touched.
#                                    Review the diff, commit it on a branch, PR.
#   ./update_calibreweb.sh install   apply calibreweb-requirements.txt to the live
#                                    venv: save a rollback list, stop CalibreWeb
#                                    (and the Calibre app), install, pip check,
#                                    start it, check the login page. Puts the old
#                                    versions back if pip check fails.
#
# Why three steps: calibreweb caps some of its dependencies, and the optional
# packages beside it have caps of their own. In October 2026 an eager upgrade
# straight into the live venv broke two of them (comicapi needs pycountry<23),
# and only pip check, read after the fact, showed it. Here pip check runs
# before anything reaches the live venv.
#
# pip-audit runs through uvx (uv), so it is never installed into CalibreWeb's venv.
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"

# ── Load local config ─────────────────────────────────────────────────────────
_self_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"

REQ_IN="$SCRIPT_DIR/calibreweb-requirements.in"
REQ_TXT="$SCRIPT_DIR/calibreweb-requirements.txt"

for key in VENV_DIR LOG_DIR PORT; do
    if [[ -z "${!key:-}" ]]; then
        echo "ERROR: config.sh is missing $key"
        exit 1
    fi
done
[[ -x "$VENV_DIR/bin/pip" ]] || { echo "ERROR: no venv at $VENV_DIR"; exit 1; }

audit() {
    # $1: a pinned requirements file. --no-deps: the file already lists every package.
    if ! command -v uvx > /dev/null; then
        echo "  (pip-audit skipped: uvx not found; install uv)"
        return 0
    fi
    uvx pip-audit -r "$1" --no-deps --disable-pip --progress-spinner off 2>/dev/null \
        || true
}

live_freeze() {
    "$VENV_DIR/bin/pip" freeze --all --exclude pip --exclude setuptools
}

cmd_check() {
    local tmp
    tmp="$(mktemp -t calibreweb-freeze)"
    live_freeze > "$tmp"
    echo "Live venv: $VENV_DIR ($("$VENV_DIR/bin/python" --version))"
    echo ""
    echo "Known vulnerabilities:"
    audit "$tmp"
    echo ""
    echo "Newer versions available (some may be held back by calibreweb's own limits):"
    "$VENV_DIR/bin/pip" list --outdated 2>/dev/null || true
    rm -f "$tmp"
}

cmd_propose() {
    local base tmp
    # Build with the same Python the live venv uses.
    base="$("$VENV_DIR/bin/python" -c 'import sys; print(sys._base_executable)')"
    tmp="$(mktemp -d -t calibreweb-propose)"
    echo "Building a throwaway venv with $base ($("$base" --version))..."
    "$base" -m venv "$tmp/venv"
    "$tmp/venv/bin/pip" install --quiet --upgrade pip
    "$tmp/venv/bin/pip" install --quiet --upgrade -r "$REQ_IN"
    echo ""
    echo "pip check:"
    if ! "$tmp/venv/bin/pip" check; then
        echo ""
        echo "✗ The newest versions conflict. Nothing written. Add an upper limit for"
        echo "  the package that conflicts to $REQ_IN (e.g. pycountry<23), then rerun."
        rm -rf "$tmp"
        exit 1
    fi

    "$tmp/venv/bin/pip" freeze --all --exclude pip | LC_ALL=C sort -f > "$tmp/pinned.txt"
    {
        # Keep the explanatory header of the existing file, then today's note.
        sed -n '/^#/p' "$REQ_TXT" | sed '/^# [0-9]\{4\}-[0-9][0-9]-[0-9][0-9]:/,$d'
        echo "# $(date +%F): resolved by update_calibreweb.sh propose on $("$base" --version | awk '{print "Python", $2}')."
        echo "# pip check clean. pip-audit at the time: see the PR."
        cat "$tmp/pinned.txt"
    } > "$tmp/new.txt"

    echo ""
    echo "Known vulnerabilities in the proposed set:"
    audit "$tmp/pinned.txt"
    echo ""
    echo "Changes against the current pinned set:"
    diff <(grep -v '^#' "$REQ_TXT") <(grep -v '^#' "$tmp/new.txt") || true
    cp "$tmp/new.txt" "$REQ_TXT"
    rm -rf "$tmp"
    echo ""
    echo "Written to $REQ_TXT. Review it with git diff, commit it on a branch,"
    echo "then run: ./update_calibreweb.sh install"
}

cmd_install() {
    local stamp rollback
    stamp="$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$LOG_DIR"
    rollback="$LOG_DIR/calibreweb-freeze-$stamp.txt"
    live_freeze > "$rollback"
    echo "Rollback list: $rollback"

    echo ""
    echo "Stopping CalibreWeb (this also quits the Calibre app)..."
    bash "$SCRIPT_DIR/stop_calibreweb.sh"

    echo ""
    echo "Installing $REQ_TXT..."
    # Either failure leaves CalibreWeb stopped unless handled here: pip's resolver
    # refusing the set outright, or pip check finding a conflict afterwards.
    if ! "$VENV_DIR/bin/pip" install --quiet -r "$REQ_TXT" || ! "$VENV_DIR/bin/pip" check; then
        echo ""
        echo "✗ The install or pip check failed. Putting the previous versions back..."
        "$VENV_DIR/bin/pip" install --quiet -r "$rollback"
        "$VENV_DIR/bin/pip" check || true
        bash "$SCRIPT_DIR/start_calibreweb.sh" || true
        exit 1
    fi

    echo ""
    bash "$SCRIPT_DIR/start_calibreweb.sh"
    local code="" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        code="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/login" || true)"
        [[ "$code" == "200" ]] && break
        sleep 2
    done
    if [[ "$code" == "200" ]]; then
        echo "✓ Login page answers 200. CalibreWeb $("$VENV_DIR/bin/pip" show calibreweb | awk '/^Version:/ {print $2}') is up."
    else
        echo "✗ Login page answers '$code' after 30 seconds. Check the logs; to go back:"
        echo "    $VENV_DIR/bin/pip install -r $rollback   (with CalibreWeb stopped)"
        exit 1
    fi
}

case "${1:-}" in
    check)   cmd_check ;;
    propose) cmd_propose ;;
    install) cmd_install ;;
    *)       sed -n '/^# Usage/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
