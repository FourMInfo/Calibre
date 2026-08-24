#!/usr/bin/env bash
# calibre_tag_ids.sh
# Adds or removes one tag across a list of book ids, without disturbing the
# other tags on those books.
#
# This exists because `calibredb set_metadata --field 'tags:foo'` REPLACES the
# whole tag list. Run that against a book tagged "history, reference" and you
# are left with a book tagged "foo" and no way back short of a restore. So
# every book here is read first, the new tag list is composed from what is
# already there, and only then written back — and if the read fails for any
# reason, that book is skipped rather than written.
#
# The usual reason to want this is a full-text search result too large for an
# "id:1 or id:2 or ..." expression (calibre's parser gives up at 491 terms). A
# tag has no such ceiling, so tagging the result and building the Virtual
# Library on tags:="the-tag" is the route that always works.
#
# Usage:
#   ./calibre_tag_ids.sh [options] IDS_FILE TAG
#
#   IDS_FILE   file with one book id per line, e.g. from calibre_fts_search.sh
#              use - to read ids from stdin
#   TAG        the tag to add (or, with --remove, to take away)
#
# Options:
#   --library PATH   Library to modify (default: LIBRARY from config.sh)
#   --remove         Remove the tag instead of adding it
#   --dry-run        Print what would change and write nothing
#   --yes            Skip the confirmation prompt (for use in other scripts)
#
# Examples:
#   ./calibre_tag_ids.sh --dry-run ~/reviews/marginalia.ids review-2026-08-24
#   ./calibre_tag_ids.sh ~/reviews/marginalia.ids review-2026-08-24
#   ./calibre_tag_ids.sh --remove ~/reviews/marginalia.ids review-2026-08-24
#
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

# ── Arguments ─────────────────────────────────────────────────────────────────
ARG_LIBRARY=""
REMOVE=0
DRY_RUN=0
ASSUME_YES=0
IDS_FILE=""
TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --library)  ARG_LIBRARY="${2:-}"; shift 2 ;;
        --remove)   REMOVE=1;             shift ;;
        --dry-run)  DRY_RUN=1;            shift ;;
        --yes|-y)   ASSUME_YES=1;         shift ;;
        -h|--help)  sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -)          IDS_FILE="-";         shift ;;
        -*)         echo "ERROR: unknown option: $1"; exit 1 ;;
        *)
            if [[ -z "$IDS_FILE" ]]; then
                IDS_FILE="$1"
            elif [[ -z "$TAG" ]]; then
                TAG="$1"
            else
                echo "ERROR: unexpected extra argument: $1"
                echo "  Quote the tag if it contains spaces."
                exit 1
            fi
            shift ;;
    esac
done

if [[ -z "$IDS_FILE" || -z "$TAG" ]]; then
    echo "Usage: $0 [options] IDS_FILE TAG"
    echo "  Run with --help for the full option list."
    exit 1
fi

# A comma in a tag would be read back as two tags, quietly corrupting the list
# on the next run. Calibre's own UI rejects them for the same reason.
if [[ "$TAG" == *,* ]]; then
    echo "ERROR: a tag cannot contain a comma — calibre uses it as the separator."
    exit 1
fi

LIBRARY="${ARG_LIBRARY:-${LIBRARY:-}}"

if [[ -z "${LOG_DIR:-}" || -z "${KEEP_LOGS:-}" || -z "${CALIBREDB:-}" ]]; then
    echo "ERROR: config.sh is missing LOG_DIR, KEEP_LOGS and/or CALIBREDB."
    echo "  Compare your config.sh against config.sh.example and add them."
    exit 1
fi

if [[ -z "$LIBRARY" ]]; then
    echo "ERROR: no library given and LIBRARY is not set in config.sh."
    exit 1
fi

if [[ ! -d "$LIBRARY" ]]; then
    echo "ERROR: Library directory not found: $LIBRARY"
    exit 1
fi

if [[ ! -x "$CALIBREDB" ]]; then
    echo "ERROR: calibredb not found at $CALIBREDB"
    echo "  Set CALIBREDB in config.sh to wherever calibre.app is installed."
    exit 1
fi

if [[ "$IDS_FILE" != "-" && ! -f "$IDS_FILE" ]]; then
    echo "ERROR: ids file not found: $IDS_FILE"
    exit 1
fi

# Accept the same loose formats calibre_ids_to_search.sh does, so a file can be
# handed to either script without reformatting.
if [[ "$IDS_FILE" == "-" ]]; then
    raw="$(cat)"
else
    raw="$(cat "$IDS_FILE")"
fi
IDS="$(printf '%s\n' "$raw" | tr ', ' '\n\n' | sed 's/^id://I' | grep -E '^[0-9]+$' | sort -n -u || true)"
total=$(printf '%s\n' "$IDS" | grep -c '^[0-9]' || true)

if [[ "$total" -eq 0 ]]; then
    echo "ERROR: no book ids found in $IDS_FILE"
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG_PREFIX="calibre_tag_ids"
LOG_FILE="$LOG_DIR/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S).log"

if [[ $REMOVE -eq 1 ]]; then ACTION="Remove"; else ACTION="Add"; fi

echo "=========================================="
echo "  Calibre Tag Update"
echo "=========================================="
echo "  Action  : $ACTION tag \"$TAG\""
echo "  Books   : $total"
echo "  Library : $LIBRARY"
echo "  Log     : $LOG_FILE"
[[ $DRY_RUN -eq 1 ]] && echo "  Mode    : DRY RUN — nothing will be written"
echo "=========================================="
echo ""

{
    echo "Calibre tag update - $(date)"
    echo "Action  : $ACTION \"$TAG\""
    echo "Library : $LIBRARY"
    echo "Ids from: $IDS_FILE"
    echo "Books   : $total"
    echo "Dry run : $DRY_RUN"
    echo ""
} > "$LOG_FILE"

# This rewrites book metadata, which is not something to do by accident on a
# four-figure library — it touches last_modified, shows up in the Tag browser
# and lands in the next backup.
if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
    printf "%s the tag \"%s\" on %s book(s)? [y/N] " "$ACTION" "$TAG" "$total"
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
    echo ""
fi

tag_lower="$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]')"

changed=0
skipped=0
failed=0

for id in $IDS; do
    # ── Read ──────────────────────────────────────────────────────────────────
    # Everything downstream depends on this being a real, complete read. A
    # partial read that looked like "no tags" is exactly how a tag list gets
    # wiped, so treat any doubt as a failure and leave the book alone.
    if ! meta="$("$CALIBREDB" --with-library "$LIBRARY" show_metadata "$id" 2>/dev/null)"; then
        echo "  ! id $id: could not read metadata — SKIPPED (not modified)"
        echo "id $id: read failed, skipped" >> "$LOG_FILE"
        failed=$(( failed + 1 ))
        continue
    fi

    # show_metadata omits the Tags line entirely when a book has no tags, so an
    # absent line is indistinguishable from a truncated read on its own. Every
    # book has a Title, so use that as proof the read actually returned
    # metadata before believing "no tags".
    if ! printf '%s\n' "$meta" | grep -q '^Title  *:'; then
        echo "  ! id $id: metadata read looks incomplete — SKIPPED (not modified)"
        echo "id $id: incomplete read, skipped" >> "$LOG_FILE"
        failed=$(( failed + 1 ))
        continue
    fi

    existing="$(printf '%s\n' "$meta" | sed -n 's/^Tags  *: *//p' | head -1)"

    # ── Modify ────────────────────────────────────────────────────────────────
    new_tags=""
    found=0
    old_IFS="$IFS"
    IFS=','
    for t in $existing; do
        # Strip the space calibre puts after each comma.
        t="$(printf '%s' "$t" | sed 's/^ *//; s/ *$//')"
        [[ -z "$t" ]] && continue
        t_lower="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
        if [[ "$t_lower" == "$tag_lower" ]]; then
            found=1
            # On --remove, drop it by not carrying it over. On add, keep the
            # spelling already in the library rather than imposing this one.
            [[ $REMOVE -eq 1 ]] && continue
        fi
        if [[ -z "$new_tags" ]]; then new_tags="$t"; else new_tags="$new_tags, $t"; fi
    done
    IFS="$old_IFS"

    if [[ $REMOVE -eq 1 ]]; then
        if [[ $found -eq 0 ]]; then
            skipped=$(( skipped + 1 ))
            echo "id $id: tag not present, unchanged" >> "$LOG_FILE"
            continue
        fi
    else
        if [[ $found -eq 1 ]]; then
            skipped=$(( skipped + 1 ))
            echo "id $id: tag already present, unchanged" >> "$LOG_FILE"
            continue
        fi
        if [[ -z "$new_tags" ]]; then new_tags="$TAG"; else new_tags="$new_tags, $TAG"; fi
    fi

    # ── Write ─────────────────────────────────────────────────────────────────
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  id $id: [${existing:-<none>}] -> [${new_tags:-<none>}]"
        echo "id $id: DRY RUN [${existing:-<none>}] -> [${new_tags:-<none>}]" >> "$LOG_FILE"
        changed=$(( changed + 1 ))
        continue
    fi

    # An empty value clears the field, which is what removing the last tag
    # should do — calibre accepts "tags:" for that.
    if "$CALIBREDB" --with-library "$LIBRARY" set_metadata "$id" \
            --field "tags:$new_tags" > /dev/null 2>&1; then
        changed=$(( changed + 1 ))
        echo "id $id: [${existing:-<none>}] -> [${new_tags:-<none>}]" >> "$LOG_FILE"
    else
        echo "  ! id $id: write failed"
        echo "id $id: WRITE FAILED" >> "$LOG_FILE"
        failed=$(( failed + 1 ))
    fi
done

echo ""
echo "=========================================="
if [[ $DRY_RUN -eq 1 ]]; then
    echo "  Dry run complete — nothing written."
    echo "  Would change : $changed"
else
    echo "  Done."
    echo "  Changed      : $changed"
fi
echo "  Unchanged    : $skipped"
echo "  Failed       : $failed"
echo "=========================================="

if [[ $DRY_RUN -eq 0 && $REMOVE -eq 0 && $changed -gt 0 ]]; then
    echo ""
    echo "  Virtual Library search expression:"
    echo "    tags:=\"$TAG\""
    echo "  In calibre: Virtual Library -> Create, paste that in."
    echo "  The = makes it an exact match, so it will not also pick up"
    echo "  a tag that merely contains this one as a substring."
fi

{
    echo ""
    echo "Changed  : $changed"
    echo "Unchanged: $skipped"
    echo "Failed   : $failed"
} >> "$LOG_FILE"

if [[ $failed -gt 0 ]]; then
    echo ""
    echo "  WARNING: $failed book(s) were not modified. See $LOG_FILE."
fi

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

[[ $failed -gt 0 ]] && exit 1
exit 0
