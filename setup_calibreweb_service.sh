#!/usr/bin/env bash
# setup_calibreweb_service.sh
# Sets CalibreWeb up to run as its own macOS user, started by launchd, instead of
# in tmux as you.
#
# Why: CalibreWeb (cps) faces the internet. Run as you, a flaw in it could read
# everything you can: ssh keys, tokens, the shell secrets file. Run as a hidden
# user with no login, no home folder and no keys, it can reach only its own files
# and the Calibre library.
#
# Layout (CALIBRE_WEB_SERVICE_DIR, e.g. /usr/local/calibre-web):
#   venv/    the Python venv. Owned by you, so updates need no sudo; cps cannot
#            change its own code
#   config/  app.db, .key, gdrive.db and CalibreWeb's logs. Service user only
#   home/    the service user's HOME (CalibreWeb and Calibre's converter keep
#            settings and a cache there). Service user only
#   tls/     certificate and key. Readable by the service user, not writable
#
# The library stays yours. Access rules on it (ACLs, inherited by every new file
# and folder) let the service user and you both read and write it, whoever
# created a file: the desktop app as you, CalibreWeb as the service user.
#
# Usage (as yourself, not with sudo; it asks for your password when needed):
#   ./setup_calibreweb_service.sh [--dry-run] STEP [ARGS]
#
# Steps, in order. Each is safe to run again; it skips what is already done.
#   user                    create the service user and its group
#   venv                    create the folders and the venv from
#                           calibreweb-requirements.txt
#   import DIR CERT KEY     copy app.db (with .key and gdrive.db) from DIR, a copy
#                           of an existing CalibreWeb config folder, and the TLS
#                           certificate and key; then point app.db's paths at this Mac
#   library                 access rules on LIBRARY for the service user and you
#   daemon                  install the LaunchDaemon, and a sudo rule so
#                           start/stop_calibreweb.sh can load and unload it
#   check                   show what is in place. Changes nothing, needs no sudo
#
# --dry-run prints each command that would run as root instead of running it.
#
# Then start it with start_calibreweb.sh. config.sh needs the service keys set:
# see the "CalibreWeb as a service" block in config.sh.example.
#
# Compatible with bash 3.2 (default on macOS)

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# ── Load local config ─────────────────────────────────────────────────────────
# readlink -f: run through a ~/.local/bin link, $0 is the link; config.sh is beside the real file.
_self_dir="$(dirname "$(readlink -f "$0")")"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi
STEP="${1:-}"
[[ $# -gt 0 ]] && shift

usage() {
    sed -n '/^# Usage/,/^# Then start it/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}
[[ -z "$STEP" ]] && usage

if [[ "$(id -u)" == "0" ]]; then
    echo "ERROR: run this as yourself, not with sudo. It calls sudo where needed,"
    echo "  and it needs your own HOME to read config.sh's paths."
    exit 1
fi

# ── Validate config ───────────────────────────────────────────────────────────
missing_keys=""
for key in CALIBRE_WEB_SERVICE_LABEL CALIBRE_WEB_SERVICE_USER CALIBRE_WEB_SERVICE_DIR \
           VENV_DIR CALIBRE_WEB_CONFIG LIBRARY PORT CERT_FILE KEY_FILE CALIBREDB; do
    if [[ -z "${!key:-}" ]]; then
        missing_keys="$missing_keys $key"
    fi
done
if [[ -n "$missing_keys" ]]; then
    echo "ERROR: config.sh is missing required key(s):$missing_keys"
    echo "  See the \"CalibreWeb as a service\" block in config.sh.example."
    exit 1
fi

SVC_USER="$CALIBRE_WEB_SERVICE_USER"
SVC_DIR="$CALIBRE_WEB_SERVICE_DIR"
LABEL="$CALIBRE_WEB_SERVICE_LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUDOERS="/etc/sudoers.d/calibre-web"   # no dot in the name: sudo skips such files
HOME_DIR="$SVC_DIR/home"
TLS_DIR="$SVC_DIR/tls"
ME="$(id -un)"
MY_GROUP="$(id -gn)"

# The fixed layout is what the LaunchDaemon and these steps assume, so config.sh
# must agree with it rather than name other places.
layout_ok=true
for pair in "VENV_DIR:$SVC_DIR/venv" "CALIBRE_WEB_CONFIG:$SVC_DIR/config"; do
    key="${pair%%:*}"; want="${pair#*:}"
    if [[ "${!key}" != "$want" ]]; then
        echo "ERROR: in service mode $key must be $want (config.sh has ${!key})"
        layout_ok=false
    fi
done
for key in CERT_FILE KEY_FILE; do
    if [[ "$(dirname "${!key}")" != "$TLS_DIR" ]]; then
        echo "ERROR: in service mode $key must be inside $TLS_DIR (config.sh has ${!key})"
        layout_ok=false
    fi
done
[[ "$layout_ok" == "true" ]] || exit 1

# ── Helpers ───────────────────────────────────────────────────────────────────
as_root() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] sudo $*"
    else
        sudo "$@"
    fi
}

as_service() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] sudo -u $SVC_USER $*"
    else
        sudo -u "$SVC_USER" "$@"
    fi
}

as_me() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

user_exists() { dscl . -read "/Users/$SVC_USER" > /dev/null 2>&1; }

cps_running() { pgrep -f "$VENV_DIR/bin/cps" > /dev/null; }

# SQL string literal: double any single quote.
sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }

# The Python to build the venv with: 3.14 first (tested with CalibreWeb 0.6.27
# on 2026-11-12 and 2026-11-18), 3.12 as the older fallback.
find_python() {
    local p
    for p in /opt/homebrew/bin/python3.14 /usr/local/bin/python3.14 \
             /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# First id in 450-499 used by no user and no group (the range macOS leaves for
# role accounts like this one).
free_id() {
    local used n
    used="$( { dscl . -list /Users UniqueID; dscl . -list /Groups PrimaryGroupID; } | awk '{print $2}')"
    for n in $(seq 450 499); do
        if ! echo "$used" | grep -qx "$n"; then
            echo "$n"
            return 0
        fi
    done
    return 1
}

# ── Steps ─────────────────────────────────────────────────────────────────────
step_user() {
    echo "Service user $SVC_USER"
    if user_exists; then
        echo "  ✓ already exists: $(id "$SVC_USER")"
        return 0
    fi
    local n
    n="$(free_id)" || { echo "ERROR: no free id in 450-499"; exit 1; }
    echo "  Creating it with id $n (hidden, no login shell, no home folder)..."
    as_root dscl . -create "/Groups/$SVC_USER"
    as_root dscl . -create "/Groups/$SVC_USER" PrimaryGroupID "$n"
    as_root dscl . -create "/Groups/$SVC_USER" RealName "CalibreWeb service"
    as_root dscl . -create "/Groups/$SVC_USER" Password "*"
    as_root dscl . -create "/Users/$SVC_USER"
    as_root dscl . -create "/Users/$SVC_USER" UniqueID "$n"
    as_root dscl . -create "/Users/$SVC_USER" PrimaryGroupID "$n"
    as_root dscl . -create "/Users/$SVC_USER" UserShell /usr/bin/false
    as_root dscl . -create "/Users/$SVC_USER" NFSHomeDirectory /var/empty
    as_root dscl . -create "/Users/$SVC_USER" RealName "CalibreWeb service"
    as_root dscl . -create "/Users/$SVC_USER" Password "*"
    as_root dscl . -create "/Users/$SVC_USER" IsHidden 1
    [[ "$DRY_RUN" == "true" ]] && return 0

    # Its only group must be its own. In staff (every normal account's group) it
    # could read the many group-readable files in your home folder.
    local groups
    groups="$(id -Gn "$SVC_USER")"
    echo "  ✓ created: $(id "$SVC_USER")"
    if [[ " $groups " == *" staff "* ]]; then
        echo "  ✗ WARNING: $SVC_USER is in group staff. Remove it:"
        echo "      sudo dseditgroup -o edit -d $SVC_USER -t user staff"
    fi
}

step_venv() {
    user_exists || [[ "$DRY_RUN" == "true" ]] || { echo "ERROR: run the user step first"; exit 1; }
    local py
    py="$(find_python)" || { echo "ERROR: no python3.14 or python3.12 found (brew install python@3.14)"; exit 1; }
    echo "Service folder $SVC_DIR, venv with $py ($("$py" --version))"

    as_root mkdir -p "$SVC_DIR"
    as_root chown root:wheel "$SVC_DIR"
    as_root chmod 755 "$SVC_DIR"

    as_root mkdir -p "$VENV_DIR"
    as_root chown "$ME:$MY_GROUP" "$VENV_DIR"
    as_root chmod 755 "$VENV_DIR"

    local d
    for d in "$CALIBRE_WEB_CONFIG" "$HOME_DIR" "$HOME_DIR/cache"; do
        as_root mkdir -p "$d"
        as_root chown "$SVC_USER:$SVC_USER" "$d"
        as_root chmod 700 "$d"
    done
    as_root mkdir -p "$TLS_DIR"
    as_root chown "root:$SVC_USER" "$TLS_DIR"
    as_root chmod 750 "$TLS_DIR"

    if [[ -x "$VENV_DIR/bin/python" ]]; then
        echo "  venv exists: $("$VENV_DIR/bin/python" --version)"
    else
        as_me "$py" -m venv "$VENV_DIR"
    fi
    if cps_running; then
        echo "  ✗ CalibreWeb is running from this venv: stop it first (stop_calibreweb.sh)"
        exit 1
    fi
    as_me "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    as_me "$VENV_DIR/bin/pip" install --quiet -r "$SCRIPT_DIR/calibreweb-requirements.txt"
    as_me "$VENV_DIR/bin/pip" check
    [[ "$DRY_RUN" == "true" ]] || echo "  ✓ venv ready: calibreweb $("$VENV_DIR/bin/pip" show calibreweb | awk '/^Version:/ {print $2}')"
}

step_import() {
    local src="${1:-}" cert="${2:-}" key="${3:-}"
    if [[ -z "$src" || -z "$cert" || -z "$key" ]]; then
        echo "Usage: $0 import DIR CERT KEY"
        echo "  DIR   a copy of the old CalibreWeb config folder (with app.db)"
        echo "  CERT  the TLS certificate file, KEY its private key"
        exit 1
    fi
    [[ -f "$src/app.db" ]] || { echo "ERROR: no app.db in $src"; exit 1; }
    [[ -f "$cert" ]] || { echo "ERROR: no certificate at $cert"; exit 1; }
    [[ -f "$key" ]]  || { echo "ERROR: no key at $key"; exit 1; }
    if cps_running; then
        echo "ERROR: CalibreWeb is running; stop it first (stop_calibreweb.sh)"
        exit 1
    fi

    echo "Importing $src into $CALIBRE_WEB_CONFIG"
    local f
    for f in app.db .key gdrive.db; do
        if [[ -f "$src/$f" ]]; then
            as_root install -o "$SVC_USER" -g "$SVC_USER" -m 600 "$src/$f" "$CALIBRE_WEB_CONFIG/$f"
            echo "  ✓ $f"
        fi
    done
    as_root install -o root -g "$SVC_USER" -m 640 "$cert" "$CERT_FILE"
    as_root install -o root -g "$SVC_USER" -m 640 "$key" "$KEY_FILE"
    echo "  ✓ certificate and key into $TLS_DIR"

    # Paths in app.db that name the old machine. CalibreWeb wants the binaries
    # and kepubify as folders (trailing slash), the converter as a file.
    local bin_dir kepubify_dir unrar_path
    bin_dir="$(dirname "$CALIBREDB")/"
    kepubify_dir=""
    command -v kepubify > /dev/null && kepubify_dir="$(dirname "$(command -v kepubify)")/"
    unrar_path=""
    command -v unrar > /dev/null && unrar_path="$(command -v unrar)"

    local sql
    sql="UPDATE settings SET
        config_calibre_dir    = $(sql_quote "$LIBRARY"),
        config_port           = $PORT,
        config_certfile       = $(sql_quote "$CERT_FILE"),
        config_keyfile        = $(sql_quote "$KEY_FILE"),
        config_binariesdir    = $(sql_quote "$bin_dir"),
        config_converterpath  = $(sql_quote "${bin_dir}ebook-convert"),
        config_kepubifypath   = $(sql_quote "$kepubify_dir"),
        config_rarfile_location = $(sql_quote "$unrar_path"),
        config_logfile        = '',
        config_access_logfile = '';"
    local show="SELECT config_calibre_dir, config_port, config_certfile, config_keyfile,
        config_binariesdir, config_converterpath, config_kepubifypath,
        config_rarfile_location FROM settings;"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] sudo -u $SVC_USER sqlite3 $CALIBRE_WEB_CONFIG/app.db \"$sql\""
        return 0
    fi
    echo "  app.db paths before:"
    as_service sqlite3 -line "$CALIBRE_WEB_CONFIG/app.db" "$show" | sed 's/^/    /'
    as_service sqlite3 "$CALIBRE_WEB_CONFIG/app.db" "$sql"
    echo "  app.db paths now:"
    as_service sqlite3 -line "$CALIBRE_WEB_CONFIG/app.db" "$show" | sed 's/^/    /'
    [[ -z "$unrar_path" ]] && echo "  (no unrar on this Mac: .cbr comics stay unreadable, as before)"
    return 0
}

step_library() {
    user_exists || [[ "$DRY_RUN" == "true" ]] || { echo "ERROR: run the user step first"; exit 1; }
    echo "Access rules on $LIBRARY for $SVC_USER and $ME"
    if [[ ! -d "$LIBRARY" ]]; then
        as_me mkdir -p "$LIBRARY"
    fi
    # Folders: list, add, delete inside, inherited by new folders and files.
    # Files: read and write. Both for the service group and for you, so a file
    # CalibreWeb creates stays yours to change, and the other way round.
    # chmod +a does not add an entry that is already there, so this can rerun.
    local dir_acl="allow list,add_file,search,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"
    local file_acl="allow read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity"
    local who
    for who in "group:$SVC_USER" "user:$ME"; do
        as_root find "$LIBRARY" -type d -exec chmod +a "$who $dir_acl" {} +
        as_root find "$LIBRARY" -type f -exec chmod +a "$who $file_acl" {} +
    done
    [[ "$DRY_RUN" == "true" ]] || { echo "  ✓ done; the library folder now shows:"; ls -led "$LIBRARY" | sed 's/^/    /'; }
}

step_daemon() {
    echo "LaunchDaemon $PLIST and sudo rule $SUDOERS"
    local tmp
    tmp="$(mktemp -d -t calibre-web-daemon)"
    local p="$tmp/$LABEL.plist"

    # Built with plutil, so paths need no XML escaping.
    plutil -create xml1 "$p"
    plutil -insert Label -string "$LABEL" "$p"
    plutil -insert UserName -string "$SVC_USER" "$p"
    plutil -insert GroupName -string "$SVC_USER" "$p"
    plutil -insert ProgramArguments -array "$p"
    plutil -insert ProgramArguments -string "$VENV_DIR/bin/cps" -append "$p"
    plutil -insert EnvironmentVariables -dictionary "$p"
    plutil -insert EnvironmentVariables.HOME -string "$HOME_DIR" "$p"
    plutil -insert EnvironmentVariables.CALIBRE_DBPATH -string "$CALIBRE_WEB_CONFIG" "$p"
    plutil -insert EnvironmentVariables.CACHE_DIRECTORY -string "$HOME_DIR/cache" "$p"
    plutil -insert EnvironmentVariables.PATH -string "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$p"
    plutil -insert EnvironmentVariables.LANG -string "en_US.UTF-8" "$p"
    plutil -insert WorkingDirectory -string "$HOME_DIR" "$p"
    plutil -insert RunAtLoad -bool true "$p"
    # Restart after a crash, not after a clean stop (the admin page's Shutdown).
    plutil -insert KeepAlive -dictionary "$p"
    plutil -insert KeepAlive.SuccessfulExit -bool false "$p"
    plutil -insert ThrottleInterval -integer 30 "$p"
    plutil -insert Umask -integer 18 "$p"   # 022
    plutil -insert StandardOutPath -string "$CALIBRE_WEB_CONFIG/launchd.log" "$p"
    plutil -insert StandardErrorPath -string "$CALIBRE_WEB_CONFIG/launchd.log" "$p"
    plutil -lint "$p" > /dev/null

    # Exactly two commands, with these arguments and no others.
    local s="$tmp/sudoers"
    {
        echo "# Installed by Calibre/setup_calibreweb_service.sh: lets start/stop_calibreweb.sh"
        echo "# (and the nightly backup, which calls them) load and unload CalibreWeb."
        echo "$ME ALL=(root) NOPASSWD: /bin/launchctl bootout system/$LABEL, /bin/launchctl bootstrap system $PLIST"
    } > "$s"
    visudo -cf "$s" > /dev/null || { echo "ERROR: the sudo rule did not parse"; cat "$s"; exit 1; }

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  The LaunchDaemon:"
        plutil -p "$p" | sed 's/^/    /'
        echo "  The sudo rule:"
        sed 's/^/    /' "$s"
    fi

    as_root install -o root -g wheel -m 644 "$p" "$PLIST"
    as_root install -o root -g wheel -m 440 "$s" "$SUDOERS"
    rm -rf "$tmp"
    echo "  ✓ installed. Not started: run start_calibreweb.sh"
}

step_check() {
    local ok="✓" bad="✗"
    echo "Service user : $(id "$SVC_USER" 2>/dev/null || echo "$bad missing")"
    local d
    for d in "$SVC_DIR" "$VENV_DIR" "$CALIBRE_WEB_CONFIG" "$HOME_DIR" "$TLS_DIR"; do
        if [[ -d "$d" ]]; then
            echo "Folder       : $ok $(ls -ld "$d" | awk '{print $1, $3, $4}') $d"
        else
            echo "Folder       : $bad missing $d"
        fi
    done
    if [[ -x "$VENV_DIR/bin/pip" ]]; then
        echo "venv         : $ok $("$VENV_DIR/bin/python" --version), calibreweb $("$VENV_DIR/bin/pip" show calibreweb 2>/dev/null | awk '/^Version:/ {print $2}')"
    else
        echo "venv         : $bad missing"
    fi
    if [[ -d "$LIBRARY" ]] && ls -led "$LIBRARY" | grep -q "group:$SVC_USER"; then
        echo "Library      : $ok access rule for $SVC_USER on $LIBRARY"
    else
        echo "Library      : $bad no access rule for $SVC_USER on $LIBRARY"
    fi
    [[ -f "$PLIST" ]] && echo "LaunchDaemon : $ok $PLIST" || echo "LaunchDaemon : $bad missing $PLIST"
    [[ -f "$SUDOERS" ]] && echo "sudo rule    : $ok $SUDOERS" || echo "sudo rule    : $bad missing $SUDOERS"
    if launchctl print "system/$LABEL" > /dev/null 2>&1; then
        echo "Loaded       : $ok $(launchctl print "system/$LABEL" | awk -F' = ' '/^\tstate/ {print "state", $2} /^\tpid/ {print "pid", $2}' | tr '\n' ' ')"
    else
        echo "Loaded       : not loaded"
    fi
    if cps_running; then
        # PID once, then its user: two pgrep calls can see different processes.
        local cps_pid
        cps_pid="$(pgrep -f "$VENV_DIR/bin/cps" | head -1 || true)"
        echo "cps          : $ok running as $(ps -o user= -p "${cps_pid:-0}" 2>/dev/null | tr -d ' ' || true) (pid ${cps_pid:-gone})"
        local code
        code="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/login" || true)"
        echo "Login page   : https://127.0.0.1:$PORT/login answers $code"
    else
        echo "cps          : not running"
    fi
}

case "$STEP" in
    user)    step_user ;;
    venv)    step_venv ;;
    import)  step_import "$@" ;;
    library) step_library ;;
    daemon)  step_daemon ;;
    check)   step_check ;;
    *)       usage ;;
esac
