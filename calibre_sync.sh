#!/usr/bin/env bash
# calibre_sync.sh
# Compares two Calibre library folders and copies book folders
# (including OPF metadata) missing from the destination.
#
# Usage:
#   ./calibre_sync.sh /path/to/source /path/to/destination [/path/to/staging]
#
# SOURCE is read-only. Missing book folders are copied to STAGING if provided,
# otherwise directly into DEST preserving Calibre's Author/Title structure.
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ── Arguments ────────────────────────────────────────────────────────────────
SOURCE="${1:-}"
DEST="${2:-}"
STAGING="${3:-}"

if [[ -z "$SOURCE" || -z "$DEST" ]]; then
    echo "Usage: $0 /path/to/source /path/to/destination [/path/to/staging]"
    echo ""
    echo "  SOURCE:  your old/damaged library (read-only, never modified)"
    echo "  DEST:    your restored library (used for comparison)"
    echo "  STAGING: optional folder to copy missing book folders into"
    echo "           If omitted, copies directly into DEST."
    exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source directory not found: $SOURCE"
    exit 1
fi

if [[ ! -d "$DEST" ]]; then
    echo "ERROR: Destination directory not found: $DEST"
    exit 1
fi

if [[ -n "$STAGING" ]]; then
    mkdir -p "$STAGING"
    COPY_TARGET="$STAGING"
else
    COPY_TARGET="$DEST"
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
LOG_FILE="$(pwd)/calibre_sync_$(date +%Y%m%d_%H%M%S).log"
EXTENSIONS=("epub" "pdf" "mobi" "azw" "azw3" "djvu" "cbz" "cbr" "fb2" "txt" "html" "rtf" "lit" "lrf" "pdb" "zip")

echo "=========================================="
echo "  Calibre Library Sync"
echo "=========================================="
echo "  Source  : $SOURCE"
echo "  Dest    : $DEST"
if [[ -n "$STAGING" ]]; then
    echo "  Staging : $STAGING"
    echo "  Mode    : copy missing book folders to staging"
else
    echo "  Mode    : copy missing book folders into destination"
fi
echo "  Log     : $LOG_FILE"
echo "=========================================="
echo ""

# ── Build extension pattern for find ─────────────────────────────────────────
ext_pattern=""
for ext in "${EXTENSIONS[@]}"; do
    ext_pattern="$ext_pattern -o -iname \"*.$ext\""
done
ext_pattern="${ext_pattern:4}"

# ── Build list of book filenames already in DEST ──────────────────────────────
echo "Scanning destination library..."

DEST_LIST=$(mktemp)
trap 'rm -f "$DEST_LIST"' EXIT

eval "find \"$DEST\" -type f \( $ext_pattern \) -print0" \
    | while IFS= read -r -d '' filepath; do basename "$filepath"; done \
    | sort > "$DEST_LIST"

dest_count=$(wc -l < "$DEST_LIST" | tr -d ' ')
echo "Found $dest_count book files in destination."
echo ""

# ── Scan source and find missing book folders ─────────────────────────────────
echo "Scanning source library for missing books..."
echo ""

# missing_folders stores the book-level folder (Author/Title/) to copy
missing_folders=()
seen_folders=()

while IFS= read -r -d '' filepath; do
    filename=$(basename "$filepath")
    if ! grep -q -F -x -e "$filename" "$DEST_LIST"; then
        # Get the book folder (parent of the file)
        book_folder=$(dirname "$filepath")
        # Deduplicate — a book folder may have multiple formats
        already_seen=false
        for seen in "${seen_folders[@]:-}"; do
            if [[ "$seen" == "$book_folder" ]]; then
                already_seen=true
                break
            fi
        done
        if [[ "$already_seen" == false ]]; then
            missing_folders+=("$book_folder")
            seen_folders+=("$book_folder")
        fi
    fi
done < <(eval "find \"$SOURCE\" -type f \( $ext_pattern \) -print0")

if [[ ${#missing_folders[@]} -eq 0 ]]; then
    echo "✓ No missing books found. Your restored library appears complete."
    exit 0
fi

echo "Found ${#missing_folders[@]} book folder(s) in source missing from destination:"
echo ""
for folder in "${missing_folders[@]}"; do
    echo "  + $(basename "$folder")  [in: $(basename "$(dirname "$folder")")]"
done

echo ""
echo "=========================================="
echo "  DRY RUN complete. No files copied yet."
echo "=========================================="
echo ""
if [[ -n "$STAGING" ]]; then
    read -r -p "Copy these ${#missing_folders[@]} folder(s) into '$STAGING'? (yes/no): " confirm
else
    read -r -p "Copy these ${#missing_folders[@]} folder(s) into '$DEST'? (yes/no): " confirm
fi

if [[ "$confirm" != "yes" ]]; then
    echo "Aborted. Nothing was copied."
    exit 0
fi

# ── Copy missing book folders ─────────────────────────────────────────────────
echo ""
echo "Copying folders..."
echo "" | tee "$LOG_FILE"
echo "Calibre sync log - $(date)" >> "$LOG_FILE"
echo "Source:  $SOURCE" >> "$LOG_FILE"
echo "Target:  $COPY_TARGET" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

copied=0
failed=0

for book_folder in "${missing_folders[@]}"; do
    folder_name=$(basename "$book_folder")

    if [[ -n "$STAGING" ]]; then
        # Copy into staging preserving Author/Title structure
        relative="${book_folder#$SOURCE/}"
        dest_path="$STAGING/$relative"
    else
        relative="${book_folder#$SOURCE/}"
        dest_path="$DEST/$relative"
    fi

    parent_dir=$(dirname "$dest_path")

    if mkdir -p "$parent_dir" && cp -r "$book_folder" "$dest_path"; then
        echo "  ✓ Copied: $relative" | tee -a "$LOG_FILE"
        ((copied++)) || true
    else
        echo "  ✗ FAILED: $relative" | tee -a "$LOG_FILE"
        ((failed++)) || true
    fi
done

echo ""
echo "=========================================="
echo "  Done."
echo "  Copied : $copied folder(s)"
echo "  Failed : $failed folder(s)"
echo "  Log    : $LOG_FILE"
echo "=========================================="
echo ""
if [[ -n "$STAGING" ]]; then
    echo "Next step: In Calibre, use 'Add books from folders' pointing at"
    echo "'$STAGING' to import the recovered books with their metadata."
else
    echo "Next step: In Calibre, use 'Add books from folders' pointing at"
    echo "the newly copied folders to rebuild metadata entries."
fi
