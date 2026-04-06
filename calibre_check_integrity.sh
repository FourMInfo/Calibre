#!/usr/bin/env bash
# calibre_check_integrity.sh
# Checks the integrity of PDF and EPUB files in a Calibre library folder.
# Requires: python3 (for epub check), pdfinfo (install via: brew install poppler)
#
# Usage:
#   ./calibre_check_integrity.sh /path/to/calibre/library [/path/to/log/dir]
#
# If log dir is provided, writes log there (for use by nightly backup script).
# If not provided, writes to current directory.
# Always exits 0 — corrupt files are reported in log only.
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ── Arguments ─────────────────────────────────────────────────────────────────
LIBRARY="${1:-}"
LOG_DIR="${2:-$(pwd)}"
KEEP_LOGS=30

if [[ -z "$LIBRARY" ]]; then
    echo "Usage: $0 /path/to/calibre/library [/path/to/log/dir]"
    exit 1
fi

if [[ ! -d "$LIBRARY" ]]; then
    echo "ERROR: Directory not found: $LIBRARY"
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/calibre_integrity_$(date +%Y%m%d_%H%M%S).log"

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
echo "Library: $LIBRARY"
echo ""

# Redirect all subsequent output to log only — not terminal
exec >> "$LOG_FILE" 2>&1

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
    echo "All files OK."
    rm -f "$LOG_FILE"
else
    echo "  ✗ $total_corrupt corrupt file(s) found — see log for details."
    echo "  Log: $LOG_FILE"
fi
echo "=========================================="

# ── Log rotation ──────────────────────────────────────────────────────────────
log_count=$(ls -1 "$LOG_DIR"/calibre_integrity_*.log 2>/dev/null | wc -l | tr -d ' ')
if [[ "$log_count" -gt "$KEEP_LOGS" ]]; then
    to_delete=$(( log_count - KEEP_LOGS ))
    ls -1 "$LOG_DIR"/calibre_integrity_*.log | sort | head -"$to_delete" | xargs rm -f
fi

exit 0
