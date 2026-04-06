#!/usr/bin/env bash
# calibre_update_metadata.sh
# For each OPF file in a staging folder, finds the matching book
# in the Calibre library by title and updates its metadata.
#
# Usage:
#   ./calibre_update_metadata.sh /path/to/staging /path/to/library
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

CALIBREDB="/Applications/calibre.app/Contents/MacOS/calibredb"
STAGING="${1:-}"
LIBRARY="${2:-}"

if [[ -z "$STAGING" || -z "$LIBRARY" ]]; then
    echo "Usage: $0 /path/to/staging /path/to/library"
    exit 1
fi

if [[ ! -d "$STAGING" ]]; then
    echo "ERROR: Staging directory not found: $STAGING"
    exit 1
fi

if [[ ! -d "$LIBRARY" ]]; then
    echo "ERROR: Library directory not found: $LIBRARY"
    exit 1
fi

if [[ ! -x "$CALIBREDB" ]]; then
    echo "ERROR: calibredb not found at $CALIBREDB"
    exit 1
fi

LOG_FILE="$(pwd)/calibre_update_metadata_$(date +%Y%m%d_%H%M%S).log"

echo "=========================================="
echo "  Calibre Metadata Update from OPF"
echo "=========================================="
echo "  Staging : $STAGING"
echo "  Library : $LIBRARY"
echo "  Log     : $LOG_FILE"
echo "=========================================="
echo ""

echo "Calibre metadata update log - $(date)" > "$LOG_FILE"
echo "Staging: $STAGING" >> "$LOG_FILE"
echo "Library: $LIBRARY" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

updated=0
failed=0
not_found=0

while IFS= read -r -d '' opf_file; do

    # Extract title and decode HTML entities
    title=$(grep -o '<dc:title>[^<]*</dc:title>' "$opf_file" \
        | sed 's/<dc:title>//;s/<\/dc:title>//' \
        | sed 's/&amp;/\&/g;s/&lt;/</g;s/&gt;/>/g;s/&quot;/"/g;s/&#39;/'"'"'/g' \
        | head -1)

    if [[ -z "$title" ]]; then
        echo "  ⚠ Could not extract title from: $opf_file"
        echo "SKIPPED (no title): $opf_file" >> "$LOG_FILE"
        ((failed++)) || true
        continue
    fi

    echo "  Processing: $title"

    # Try exact match first, then loose match
    book_id=$("$CALIBREDB" search --with-library "$LIBRARY" "title:\"=$title\"" 2>/dev/null | tr -d ' ' | head -1) || true

    if [[ -z "$book_id" ]]; then
        book_id=$("$CALIBREDB" search --with-library "$LIBRARY" "title:\"$title\"" 2>/dev/null | tr -d ' ' | head -1) || true
    fi

    if [[ -z "$book_id" ]]; then
        echo "    ✗ Not found in library: $title"
        echo "NOT FOUND: $title | OPF: $opf_file" >> "$LOG_FILE"
        ((not_found++)) || true
        continue
    fi

    first_id=$(echo "$book_id" | cut -d',' -f1)

    if "$CALIBREDB" set_metadata --with-library "$LIBRARY" "$first_id" "$opf_file" &>/dev/null; then
        echo "    ✓ Updated (ID $first_id): $title"
        echo "UPDATED [$first_id]: $title | OPF: $opf_file" >> "$LOG_FILE"
        ((updated++)) || true
    else
        echo "    ✗ Failed to update: $title (ID $first_id)"
        echo "FAILED [$first_id]: $title | OPF: $opf_file" >> "$LOG_FILE"
        ((failed++)) || true
    fi

done < <(find "$STAGING" -name "*.opf" -print0)

echo ""
echo "=========================================="
echo "  Done."
echo "  Updated   : $updated"
echo "  Not found : $not_found"
echo "  Failed    : $failed"
echo "  Log       : $LOG_FILE"
echo "=========================================="
if [[ $not_found -gt 0 ]]; then
    echo ""
    echo "  Note: 'Not found' books may have slightly different titles"
    echo "  in the library. Check the log and update those manually."
fi
