#!/usr/bin/env bash
# calibre_check_integrity.sh
# Checks the integrity of PDF and EPUB files in a Calibre library folder.
# Requires: python3 (for epub check), pdfinfo (install via: brew install poppler)
#
# Usage:
#   ./calibre_check_integrity.sh [/path/to/calibre/library] [/path/to/log/dir]
#
# Both arguments are optional and fall back to LIBRARY and LOG_DIR in config.sh.
# Callers that check something other than the live library — the nightly backup
# and the restore preview — pass their own paths and those always win.
#
# A dated log is always written, whether or not anything is wrong, and a one
# line summary goes to the terminal.
# Always exits 0 — corrupt files are reported in the log only.
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ── Load local config ─────────────────────────────────────────────────────────
# SCRIPT_DIR has to be derived here because it is what locates config.sh.
_self_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"

# ── Arguments (fall back to config) ───────────────────────────────────────────
# Arguments still take precedence: calibre_nightly_backup.sh passes the live
# library and calibre_restore_preview.sh passes a preview folder, so neither
# can be left to the config default.
LIBRARY="${1:-${LIBRARY:-}}"
LOG_DIR="${2:-${LOG_DIR:-}}"
LOG_PREFIX="calibre_integrity"

if [[ -z "$LIBRARY" ]]; then
    echo "Usage: $0 [/path/to/calibre/library] [/path/to/log/dir]"
    echo "  With no arguments, uses LIBRARY and LOG_DIR from config.sh."
    exit 1
fi

if [[ -z "$LOG_DIR" || -z "${KEEP_LOGS:-}" ]]; then
    echo "ERROR: config.sh is missing LOG_DIR and/or KEEP_LOGS."
    echo "  Compare your config.sh against config.sh.example and add them."
    exit 1
fi

if [[ ! -d "$LIBRARY" ]]; then
    echo "ERROR: Directory not found: $LIBRARY"
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S).log"

# ── Check dependencies ────────────────────────────────────────────────────────
HAS_PDFINFO=true
HAS_PYTHON=true

if ! command -v pdfinfo &>/dev/null; then
    echo "WARNING: pdfinfo not found. Install with: brew install poppler. PDF checking skipped."
    HAS_PDFINFO=false
fi

if ! command -v python3 &>/dev/null; then
    echo "WARNING: python3 not found. EPUB checking skipped."
    HAS_PYTHON=false
fi

echo ""
echo "=========================================="
echo "  Calibre File Integrity Check"
echo "=========================================="
echo "  Library : $LIBRARY"
echo "  Log     : $LOG_FILE"
echo "=========================================="
echo ""

echo "Calibre integrity check - $(date)" > "$LOG_FILE"

# Keep a handle on the real terminal before redirecting. Everything below this
# goes to the log, but the closing summary still needs somewhere visible to
# land — otherwise a clean run and a run that never happened leave the caller
# looking at exactly the same thing.
exec 3>&1

# Redirect all subsequent output to log only — not terminal
exec >> "$LOG_FILE" 2>&1

echo "Library: $LIBRARY"
echo ""

total_pdf=0
total_epub=0
corrupt_pdf=0
corrupt_epub=0

# ── Write python checker to temp file to avoid heredoc exit code issues ───────
PYCHECK=$(mktemp /tmp/calibre_epubcheck_XXXXXX.py)
trap 'rm -f "$PYCHECK"' EXIT

cat > "$PYCHECK" << 'PYEOF'
import sys
import zipfile

filepath = sys.argv[1]
try:
    with zipfile.ZipFile(filepath, 'r') as z:
        bad = z.testzip()
        if bad:
            print("BAD_FILE:" + str(bad))
            sys.exit(0)
        names = z.namelist()
        if 'mimetype' not in names:
            print("MISSING:mimetype")
            sys.exit(0)
        if not any(n.endswith('.opf') for n in names):
            print("MISSING:opf")
            sys.exit(0)
        print("OK")
except zipfile.BadZipFile as e:
    print("BAD_ZIP:" + str(e))
except Exception as e:
    print("ERROR:" + str(e))
PYEOF

# ── PDF integrity check ───────────────────────────────────────────────────────
check_pdf() {
    local filepath="$1"
    ((total_pdf++)) || true

    if [[ "$HAS_PDFINFO" == "false" ]]; then
        return
    fi

    if pdfinfo "$filepath" &>/dev/null; then
        echo "  ✓ PDF OK : $(basename "$filepath")"
    else
        echo "  ✗ PDF CORRUPT : $filepath"
        echo "CORRUPT PDF: $filepath"
        ((corrupt_pdf++)) || true
    fi
}

# ── EPUB integrity check ──────────────────────────────────────────────────────
check_epub() {
    local filepath="$1"
    ((total_epub++)) || true

    if [[ "$HAS_PYTHON" == "false" ]]; then
        return
    fi

    # Python always exits 0 now — result is in stdout
    local result
    result=$(python3 "$PYCHECK" "$filepath" 2>/dev/null) || result="ERROR:python_failed"

    if [[ "$result" == "OK" ]]; then
        echo "  ✓ EPUB OK : $(basename "$filepath")"
    else
        echo "  ✗ EPUB CORRUPT ($result) : $filepath"
        echo "CORRUPT EPUB [$result]: $filepath"
        ((corrupt_epub++)) || true
    fi
}

# ── Scan library ──────────────────────────────────────────────────────────────
echo "Scanning library files..."
echo ""

while IFS= read -r -d '' filepath; do
    ext="${filepath##*.}"
    ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')
    case "$ext_lower" in
        pdf)  check_pdf "$filepath" ;;
        epub) check_epub "$filepath" ;;
    esac
done < <(find "$LIBRARY" -type f \( -iname "*.pdf" -o -iname "*.epub" \) -print0)

# ── Summary ───────────────────────────────────────────────────────────────────
total_corrupt=$((corrupt_pdf + corrupt_epub))

echo ""
echo "=========================================="
echo "  Results"
echo "=========================================="
echo "  PDFs checked  : $total_pdf  (corrupt: $corrupt_pdf)"
echo "  EPUBs checked : $total_epub  (corrupt: $corrupt_epub)"
echo ""

if [[ $total_corrupt -eq 0 ]]; then
    echo "  ✓ All files passed integrity checks."
else
    echo "  ✗ $total_corrupt corrupt file(s) found — see above for details."
fi
echo "=========================================="

# The log is kept either way now. It used to be deleted on a clean run, which
# meant a library that passed and a check that never ran left the same trace:
# nothing at all. Every run leaves a dated log, and this line goes back out to
# the terminal (fd 3, saved before the redirect above) so whoever called the
# script sees the outcome without having to open it.
echo "Integrity check: $total_pdf PDF(s), $total_epub EPUB(s), $total_corrupt corrupt — log: $LOG_FILE" >&3

# ── Log rotation ──────────────────────────────────────────────────────────────
# `ls` exits nonzero when the glob matches nothing, and under `pipefail` that
# would fail the assignment and abort the script, so run it in a brace group
# that swallows the status. `|| echo "0"` would be worse than useless here:
# `tr` has already emitted its own "0", so the two concatenate into "00".
log_count=$( { ls -1 "$LOG_DIR"/${LOG_PREFIX}_*.log 2>/dev/null || true; } | wc -l | tr -d ' \n')
if [[ "$log_count" -gt "$KEEP_LOGS" ]]; then
    to_delete=$(( log_count - KEEP_LOGS ))
    ls -1 "$LOG_DIR"/${LOG_PREFIX}_*.log | sort | head -"$to_delete" | xargs rm -f
fi

exit 0
