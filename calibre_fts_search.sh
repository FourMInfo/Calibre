#!/usr/bin/env bash
# calibre_fts_search.sh
# Runs a Calibre full-text search from the command line and writes the result
# out in three shapes:
#
#   <name>.ids          one book id per line — input for the other two scripts
#   <name>.snippets.txt the matched passages, for actually reading through
#   <name>.vl.txt       an "id:4 or id:1 or ..." Virtual Library expression
#
# The point of the .ids/.vl.txt files is that a full-text search result in the
# Calibre GUI is session state: it lives in the "marked" flag, which calibredb
# cannot see and which is gone the moment you quit. Anything you want to still
# have tomorrow has to be written down, which is what this does.
#
# Usage:
#   ./calibre_fts_search.sh [options] 'search query'
#
# Options:
#   --library PATH    Library to search       (default: LIBRARY from config.sh)
#   --out DIR         Where to write results  (default: REVIEW_DIR from config)
#   --name LABEL      Basename for the files  (default: fts_YYYYmmdd_HHMMSS)
#   --exact           Do not match related words. Off by default, so a search
#                     for "appear" also matches "appears" and "appearing".
#   --restrict EXPR   Search a subset only. Takes 'ids:1,2,3' or a metadata
#                     search as 'search:tag:foo'. Note that the ids: form works
#                     here even though it does NOT work in a normal search
#                     expression — see FULL_TEXT_SEARCH.md.
#   --reindex         Force the FTS index to complete before searching, and
#                     wait for it. Slow on a large library, but see below.
#
# Examples:
#   ./calibre_fts_search.sh 'quicksilver protocol'
#   ./calibre_fts_search.sh --exact --name marginalia 'marginalia'
#   ./calibre_fts_search.sh --restrict 'search:tag:history' 'annotation'
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
OUT_DIR=""
NAME=""
EXACT=0
RESTRICT=""
REINDEX=0
QUERY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --library)  ARG_LIBRARY="${2:-}"; shift 2 ;;
        --out)      OUT_DIR="${2:-}";     shift 2 ;;
        --name)     NAME="${2:-}";        shift 2 ;;
        --restrict) RESTRICT="${2:-}";    shift 2 ;;
        --exact)    EXACT=1;              shift ;;
        --reindex)  REINDEX=1;            shift ;;
        -h|--help)  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         echo "ERROR: unknown option: $1"; exit 1 ;;
        *)
            if [[ -n "$QUERY" ]]; then
                echo "ERROR: more than one search query given: '$QUERY' and '$1'"
                echo "  Quote the whole query if it contains spaces."
                exit 1
            fi
            QUERY="$1"; shift ;;
    esac
done

if [[ -z "$QUERY" ]]; then
    echo "Usage: $0 [options] 'search query'"
    echo "  Run with --help for the full option list."
    exit 1
fi

LIBRARY="${ARG_LIBRARY:-${LIBRARY:-}}"

if [[ -z "${LOG_DIR:-}" || -z "${KEEP_LOGS:-}" || -z "${CALIBREDB:-}" ]]; then
    echo "ERROR: config.sh is missing LOG_DIR, KEEP_LOGS and/or CALIBREDB."
    echo "  Compare your config.sh against config.sh.example and add them."
    exit 1
fi

# REVIEW_DIR was added to config.sh.example after the first config.sh files were
# already in circulation, and config.sh is gitignored and hand-carried between
# machines — so an older copy will not have it. Fall back rather than fail, and
# say where the files went, instead of making a hand-edit mandatory.
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="${REVIEW_DIR:-$LOG_DIR/reviews}"
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

[[ -n "$NAME" ]] || NAME="fts_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT_DIR"
mkdir -p "$LOG_DIR"
LOG_PREFIX="calibre_fts_search"
LOG_FILE="$LOG_DIR/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S).log"

IDS_FILE="$OUT_DIR/$NAME.ids"
SNIP_FILE="$OUT_DIR/$NAME.snippets.txt"
VL_FILE="$OUT_DIR/$NAME.vl.txt"

# Every calibre command-line tool prints plugin startup chatter on stdout, mixed
# in with the real output — on this install a third-party metadata plugin adds
# "Integration status: True" as the first line. Left in, it lands in the middle
# of the snippet file and, worse, breaks anything parsing the output. Strip it
# once, here, rather than in three places below.
strip_noise() {
    grep -v '^Integration status:' || true
}

echo "=========================================="
echo "  Calibre Full-Text Search"
echo "=========================================="
echo "  Query   : $QUERY"
echo "  Library : $LIBRARY"
echo "  Output  : $OUT_DIR/$NAME.*"
echo "  Log     : $LOG_FILE"
echo "=========================================="
echo ""

{
    echo "Calibre FTS search log - $(date)"
    echo "Query    : $QUERY"
    echo "Library  : $LIBRARY"
    echo "Restrict : ${RESTRICT:-<none>}"
    echo "Exact    : $EXACT"
    echo ""
} > "$LOG_FILE"

# ── Index state ───────────────────────────────────────────────────────────────
# fts_search refuses to run until 90% of the library is indexed, and reports
# "searching is disabled" rather than returning nothing, which is easy to
# mistake for "no matches". Check first so the message is unambiguous.
#
# Indexing is done by a background worker that calibre starts inside the
# calibredb process and tears down when it exits, so a short-lived CLI call only
# ever indexes a few more books before dying. Repeated runs creep forwards a
# book or two at a time. --reindex is the way out: it holds the process open
# until the index is actually complete.
index_status="$("$CALIBREDB" --with-library "$LIBRARY" fts_index status 2>/dev/null | strip_noise || true)"
echo "Index: $(echo "$index_status" | tr '\n' ' ')"
echo "Index: $(echo "$index_status" | tr '\n' ' ')" >> "$LOG_FILE"

if echo "$index_status" | grep -qi 'disabled'; then
    echo ""
    echo "ERROR: full-text indexing is disabled for this library."
    echo "  Turn it on with:"
    echo "    \"$CALIBREDB\" --with-library \"$LIBRARY\" fts_index enable"
    echo "  then re-run this script with --reindex."
    exit 1
fi

# "N of M books files indexed". Any shortfall means the search below can only
# under-report, so say so — at 95% indexed calibre searches quite happily and
# simply does not look at the missing 5%, which reads as "no such passage".
indexed_n="$(echo "$index_status" | sed -n 's/^\([0-9][0-9]*\) of [0-9].*/\1/p' | head -1)"
indexed_m="$(echo "$index_status" | sed -n 's/^[0-9][0-9]* of \([0-9][0-9]*\).*/\1/p' | head -1)"
if [[ -n "$indexed_n" && -n "$indexed_m" && "$indexed_n" -lt "$indexed_m" ]]; then
    echo "  WARNING: $(( indexed_m - indexed_n )) book(s) are not yet indexed."
    echo "  Results below cover only the indexed ones. Re-run with --reindex"
    echo "  for a complete answer."
    echo "Index incomplete: $indexed_n of $indexed_m" >> "$LOG_FILE"
fi

if [[ $REINDEX -eq 1 ]]; then
    echo ""
    echo "Reindexing (this can take a long time on a large library)..."
    # The confirmation prompt wants the literal word "reindex" typed at it —
    # a plain `yes |` answers "y", which it treats as "anything else" and
    # aborts. With no stdin at all it dies on EOFError.
    #
    # `|| true` because `yes` is still writing when calibredb exits and dies of
    # SIGPIPE, which fails the pipeline under `pipefail` even on success.
    yes reindex \
        | "$CALIBREDB" --with-library "$LIBRARY" fts_index reindex --wait-for-completion 2>&1 \
        | strip_noise \
        | tail -2 || true
    echo ""
fi

# ── Search ────────────────────────────────────────────────────────────────────
# Two passes over the same query. The first is plain text output, used only to
# harvest the ids; the second adds --include-snippets, which calibre's own help
# warns "makes searching much slower", so it is kept out of the id pass.
set -- --with-library "$LIBRARY"
[[ $EXACT -eq 1 ]]     && set -- "$@" --do-not-match-on-related-words
[[ -n "$RESTRICT" ]]   && set -- "$@" --restrict-to "$RESTRICT"

echo "Searching..."

# stderr is captured rather than discarded. When the index is below
# --indexing-threshold (90% by default) calibre writes
#   "N files out of M are not yet indexed, searching is disabled"
# to *stderr* and exits 1, printing nothing at all on stdout. Thrown away, that
# is indistinguishable from a genuine no-match, and the script would cheerfully
# report "No matches" for a search that never ran.
err_file="$(mktemp "${TMPDIR:-/tmp}/calibre_fts_err.XXXXXX")"
trap 'rm -f "$err_file"' EXIT

# fts_search exits nonzero when nothing matches, which is not an error here.
search_out="$("$CALIBREDB" "$@" fts_search "$QUERY" 2>"$err_file" | strip_noise || true)"

if grep -q 'searching is disabled' "$err_file" 2>/dev/null; then
    echo ""
    echo "ERROR: the search did not run — the index is too incomplete."
    echo "  calibre said:"
    echo "    $(grep 'searching is disabled' "$err_file" | head -1)"
    echo ""
    echo "  Finish the index and try again:"
    echo "    $0 --reindex ${QUERY:+'$QUERY'}"
    echo "  or leave the calibre desktop app open for a while — its indexing"
    echo "  worker is long-lived, unlike a command-line one."
    echo "Search refused: index below threshold" >> "$LOG_FILE"
    exit 1
fi

# `grep -o` also exits 1 on no match, which under `pipefail` would abort the
# script before it could report "no matches" — and would leave a stale empty
# .ids file behind, because the redirect has already created it.
echo "$search_out" | grep -o 'Book id: [0-9]*' | sed 's/Book id: //' | sort -n -u > "$IDS_FILE" || true
count=$(wc -l < "$IDS_FILE" | tr -d ' ')

if [[ "$count" -eq 0 ]]; then
    echo ""
    echo "No matches."
    echo "  If you expected some, check the index line above — a partially"
    echo "  indexed library reports no results rather than an error. Re-run"
    echo "  with --reindex."
    echo "No matches." >> "$LOG_FILE"
    rm -f "$IDS_FILE"
    exit 0
fi

# The markers replace calibre's default, which is a raw ANSI colour escape.
# That is fine on a terminal and unreadable in a file.
{
    echo "Calibre full-text search"
    echo "Query   : $QUERY"
    echo "Library : $LIBRARY"
    echo "Date    : $(date)"
    echo "Matches : $count"
    echo ""
} > "$SNIP_FILE"

"$CALIBREDB" "$@" fts_search --include-snippets \
    --match-start-marker='>>>' --match-end-marker='<<<' \
    "$QUERY" 2>/dev/null | strip_noise >> "$SNIP_FILE" || true

# ── Virtual Library expression ────────────────────────────────────────────────
# calibre's search parser recurses once per "or", and dies at 492 terms with
# RecursionError. 491 is the last size that works; anything longer has to go
# the tag route instead. See FULL_TEXT_SEARCH.md.
VL_MAX=491
if [[ "$count" -le "$VL_MAX" ]]; then
    tr '\n' ' ' < "$IDS_FILE" \
        | sed 's/ $//; s/\([0-9][0-9]*\)/id:\1/g; s/ / or /g' > "$VL_FILE"
    echo "" >> "$VL_FILE"
else
    {
        echo "# $count matches is over the $VL_MAX-term limit of calibre's search parser."
        echo "# An id: expression this long fails with RecursionError, so there is no"
        echo "# usable expression for this result set. Tag the books instead:"
        echo "#"
        echo "#   ./calibre_tag_ids.sh --library \"$LIBRARY\" $IDS_FILE review-$(date +%Y%m%d)"
        echo "#"
        echo "# then use this as the Virtual Library expression:"
        echo "#"
        echo "#   tags:=\"review-$(date +%Y%m%d)\""
    } > "$VL_FILE"
fi

echo ""
echo "=========================================="
echo "  Done."
echo "  Matches   : $count"
echo "  Ids       : $IDS_FILE"
echo "  Snippets  : $SNIP_FILE"
echo "  VL search : $VL_FILE"
echo "=========================================="

{
    echo "Matches: $count"
    echo "Ids    : $IDS_FILE"
} >> "$LOG_FILE"

if [[ "$count" -gt "$VL_MAX" ]]; then
    echo ""
    echo "  Note: $count matches is past the $VL_MAX-term search parser limit,"
    echo "  so no id: expression was written. Use calibre_tag_ids.sh — see the"
    echo "  note in $VL_FILE."
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
