#!/usr/bin/env bash
# calibre_ids_to_search.sh
# Turns a list of Calibre book ids into a search expression you can paste into
# the search bar, or save as a Virtual Library:
#
#   1                       id:1 or id:3 or id:4
#   3          ────────►
#   4
#
# Input can be a plain list of ids (one per line, or comma/space separated), or
# a catalog CSV exported from Calibre — the id column is picked out
# automatically. Use "-" to read from stdin.
#
# Why an expression and not a list of ids: calibredb's search grammar does not
# accept "id:1,3" (ParseException) and silently matches nothing for "ids:1,3",
# so an explicit "or" chain between single ids is the only form that works in
# the GUI search bar. See FULL_TEXT_SEARCH.md.
#
# Usage:
#   ./calibre_ids_to_search.sh [options] FILE
#   ./calibre_ids_to_search.sh --copy ~/reviews/marginalia.ids
#   calibredb list -s 'tag:history' --for-machine | ./calibre_ids_to_search.sh -
#
# Options:
#   --copy        Also put the expression on the clipboard, ready to paste
#   --field NAME  Search field to build the expression from (default: id)
#   --out FILE    Write the expression to FILE as well as stdout
#   --force       Emit the expression even if it is past the 491-term limit
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

# Add both Intel and Apple Silicon brew paths for portability
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# This script does not need a library, a log or any path from config.sh — it is
# pure text transformation. It is deliberately left standalone so it can be
# dropped into a pipe anywhere, including on a machine with no config.sh.

# calibre's search parser recurses once per "or" term and raises RecursionError
# at 492. 491 is the largest expression that parses.
VL_MAX=491

COPY=0
FIELD="id"
OUT_FILE=""
FORCE=0
IN_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copy)   COPY=1;             shift ;;
        --force)  FORCE=1;            shift ;;
        --field)  FIELD="${2:-}";     shift 2 ;;
        --out)    OUT_FILE="${2:-}";  shift 2 ;;
        -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -)        IN_FILE="-";        shift ;;
        -*)       echo "ERROR: unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -n "$IN_FILE" ]]; then
                echo "ERROR: more than one input file given." >&2
                exit 1
            fi
            IN_FILE="$1"; shift ;;
    esac
done

if [[ -z "$IN_FILE" ]]; then
    echo "Usage: $0 [options] FILE   (or - for stdin)" >&2
    echo "  Run with --help for the full option list." >&2
    exit 1
fi

if [[ "$IN_FILE" != "-" && ! -f "$IN_FILE" ]]; then
    echo "ERROR: input file not found: $IN_FILE" >&2
    exit 1
fi

if [[ -z "$FIELD" ]]; then
    echo "ERROR: --field cannot be empty." >&2
    exit 1
fi

# Read the whole input up front. It has to be examined twice — once to work out
# what shape it is, once to extract from it — and stdin can only be read once.
if [[ "$IN_FILE" == "-" ]]; then
    raw="$(cat)"
else
    raw="$(cat "$IN_FILE")"
fi

if [[ -z "${raw//[[:space:]]/}" ]]; then
    echo "ERROR: input is empty." >&2
    exit 1
fi

# Calibre writes its catalog CSV with a UTF-8 byte-order mark, so the first
# column is not "id" but "<BOM>id" and every name test against it fails. Strip
# it before anything looks at the header.
raw="${raw#$'\xef\xbb\xbf'}"

# ── Work out what we were handed ──────────────────────────────────────────────
# Three shapes turn up in practice:
#   1. a catalog CSV, which has a header row naming an "id" column
#   2. JSON from calibredb, where ids appear as "id": 123 from `list
#      --for-machine` but as "book_id": 123 from `fts_search --output-format=json`
#   3. a bare list of numbers, from calibre_fts_search.sh or typed by hand
#
# The CSV test is deliberately "header row with commas and letters in it",
# not "has an id column". A catalog exported without id would otherwise fall
# through to the plain branch and quietly harvest any digits it found in the
# titles, which is a wrong answer rather than an error.
first_line="$(printf '%s\n' "$raw" | head -1)"

if printf '%s' "$raw" | grep -q '"\(book_\)\{0,1\}id"[[:space:]]*:'; then
    shape="json"
elif printf '%s' "$first_line" | grep -q ',' && printf '%s' "$first_line" | grep -q '[A-Za-z]'; then
    shape="csv"
else
    shape="plain"
fi

case "$shape" in
    csv)
        # Find which column is called id. Calibre's catalog puts it first, but
        # the column set is user-configurable, so do not assume.
        col=$(printf '%s' "$first_line" \
            | tr ',' '\n' \
            | tr -d '"' \
            | grep -n -i -x -e 'id' \
            | head -1 \
            | cut -d: -f1 || true)
        if [[ -z "$col" ]]; then
            echo "ERROR: this looks like a CSV but has no 'id' column." >&2
            echo "  Re-export the catalog with id included, or hand this script" >&2
            echo "  a plain list of ids instead." >&2
            exit 1
        fi
        # Quoted fields containing commas would break a cut -d, here. The id
        # column is numeric and calibre puts it first, so in practice cut is
        # safe for column 1; guard the general case rather than silently
        # mangling a shifted column.
        if [[ "$col" -ne 1 ]]; then
            echo "WARNING: 'id' is column $col, not the first column. If any" >&2
            echo "  earlier column contains a comma inside quotes, the ids" >&2
            echo "  extracted below will be wrong — check them." >&2
        fi
        ids="$(printf '%s\n' "$raw" | tail -n +2 | cut -d, -f"$col" | tr -d '"')"
        ;;
    json)
        # `list --for-machine` says "id", `fts_search --output-format=json` says
        # "book_id". Accept both, and match the key exactly so a field like
        # "series_id" or "uuid" can never be mistaken for the book id.
        ids="$(printf '%s\n' "$raw" \
            | grep -o '"\(book_\)\{0,1\}id"[[:space:]]*:[[:space:]]*[0-9]*' \
            | grep -o '[0-9]*$')"
        ;;
    plain)
        # Accept commas, spaces or newlines as separators, and tolerate an
        # "id:" prefix so an expression can be fed back in and re-normalised.
        # `[iI][dD]:` rather than sed's `I` flag, which is a GNU extension BSD
        # sed does not have.
        ids="$(printf '%s\n' "$raw" | tr ',' '\n' | tr ' ' '\n' | sed 's/^[iI][dD]://')"
        ;;
esac

# Keep only bare integers, drop blanks and duplicates, sort numerically so the
# expression is stable between runs and diffable.
ids="$(printf '%s\n' "$ids" | grep -E '^[0-9]+$' | sort -n -u || true)"

count=$(printf '%s\n' "$ids" | grep -c '^[0-9]' || true)

if [[ "$count" -eq 0 ]]; then
    echo "ERROR: no ids found in $IN_FILE (read as: $shape)." >&2
    exit 1
fi

if [[ "$count" -gt "$VL_MAX" && $FORCE -eq 0 ]]; then
    {
        echo "ERROR: $count ids is past calibre's $VL_MAX-term search limit."
        echo "  An expression this long fails to parse with RecursionError."
        echo ""
        echo "  Tag the books and search on the tag instead:"
        echo "    ./calibre_tag_ids.sh $IN_FILE review-$(date +%Y%m%d)"
        echo "    then search:  tags:=\"review-$(date +%Y%m%d)\""
        echo ""
        echo "  Or pass --force to emit it anyway (calibre will reject it)."
    } >&2
    exit 1
fi

# Joined in a loop rather than with sed. The obvious one-liner —
# `tr '\n' '\a' | sed 's/\a/ or /g'` — silently does the wrong thing on BSD
# sed, which reads `\a` in a pattern as a plain letter "a": no separator is
# inserted, and with --field author_sort every "a" in the field name is
# replaced instead. 491 terms is small enough that the loop costs nothing.
expr=""
for i in $ids; do
    if [[ -z "$expr" ]]; then
        expr="$FIELD:$i"
    else
        expr="$expr or $FIELD:$i"
    fi
done

printf '%s\n' "$expr"

if [[ -n "$OUT_FILE" ]]; then
    printf '%s\n' "$expr" > "$OUT_FILE"
    echo "Written to $OUT_FILE ($count ids)" >&2
fi

if [[ $COPY -eq 1 ]]; then
    if command -v pbcopy > /dev/null 2>&1; then
        printf '%s' "$expr" | pbcopy
        echo "Copied to clipboard ($count ids)" >&2
    else
        echo "WARNING: pbcopy not found, nothing copied." >&2
    fi
fi
