#!/usr/bin/env bash
# calibre_library_manifest.sh
# Writes a manifest of a Calibre library folder: one line per file, sorted, so two
# copies of a library (the live one and a restore, or the same library on two Macs)
# can be compared with diff.
#
# Usage:
#   ./calibre_library_manifest.sh [--md5] [LIBRARY_DIR] > manifest.txt
#
#   Without --md5 each line is  path <TAB> size in bytes <TAB> modification time
#   (seconds since 1970), which takes seconds to produce and catches missing,
#   extra, resized and re-dated files. With --md5 each line is  path <TAB> md5,
#   which reads every byte (minutes for a large library) and also catches files
#   whose content differs at the same size and date.
#
#   LIBRARY_DIR defaults to LIBRARY in config.sh. Paths in the manifest are
#   relative to it, so manifests of libraries in different places compare cleanly.
#
# Left out, because the backups leave them out (rclone's --exclude in the nightly
# backup) and they say nothing about the library: .DS_Store files, and Syncthing's
# .stfolder marker.
#
# Example, a restore on this Mac against the live library on another:
#   ./calibre_library_manifest.sh "/Users/Shared/Calibre Library" > here.txt
#   ssh OtherMac 'bash -s -- ~/"Calibre Library"' < calibre_library_manifest.sh > there.txt
#   diff here.txt there.txt && echo identical
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

md5=false
if [[ "${1:-}" == "--md5" ]]; then
    md5=true
    shift
fi

if [[ -n "${1:-}" ]]; then
    library="$1"
else
    # Only needed when no folder is named, so the script also runs where there is
    # no config.sh, for example piped over ssh as in the example above.
    # readlink -f: run through a ~/.local/bin link, $0 is the link.
    _self_dir="$(dirname "$(readlink -f "$0")")"
    if [[ ! -f "$_self_dir/config.sh" ]]; then
        echo "ERROR: no library folder given and no config.sh at $_self_dir" >&2
        exit 1
    fi
    source "$_self_dir/config.sh"
    library="${LIBRARY:?config.sh has no LIBRARY}"
fi

if [[ ! -d "$library" ]]; then
    echo "ERROR: not a folder: $library" >&2
    exit 1
fi

tab=$'\t'
cd "$library"

# -print0 and xargs -0: book titles contain spaces, quotes and other characters
# that would break a newline- or space-separated list.
if [[ "$md5" == "true" ]]; then
    # md5 -r prints "hash path"; turn it into "path<TAB>hash" to match the other form.
    find . -type f ! -name .DS_Store ! -path './.stfolder/*' -print0 \
        | xargs -0 md5 -r \
        | sed "s/^\([0-9a-f]\{32\}\) \(.*\)\$/\2$tab\1/"
else
    find . -type f ! -name .DS_Store ! -path './.stfolder/*' -print0 \
        | xargs -0 stat -f "%N$tab%z$tab%m"
fi | LC_ALL=C sort
