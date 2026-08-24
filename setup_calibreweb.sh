#!/usr/bin/env bash
# setup_calibreweb.sh
# Sets up CalibreWeb in a Python 3.12 venv
#
# What this script does:
#   1. Creates the venv at the location config.sh gives for VENV_DIR
#   2. Installs calibreweb and optional features via pip
#   3. Configures port, library path and SSL certificates in app.db
#   4. Makes the repo's start/stop scripts executable
#
# Usage:
#   chmod +x setup_calibreweb.sh
#   ./setup_calibreweb.sh

set -euo pipefail

# ── Load local config ─────────────────────────────────────────────────────────
# SCRIPT_DIR has to be derived here because it is what locates config.sh.
# config.sh may override it; if it doesn't, this script's own directory wins.
_self_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$_self_dir/config.sh" ]]; then
    echo "ERROR: config.sh not found at $_self_dir/config.sh"
    echo "  Copy config.sh.example to config.sh and fill in your values."
    exit 1
fi
source "$_self_dir/config.sh"
SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"

# ── Validate config ───────────────────────────────────────────────────────────
# Under `set -u` a missing key would surface as a bare "unbound variable" part
# way through the install. Check up front and name what is actually missing.
missing_keys=""
for key in VENV_DIR CALIBRE_WEB_CONFIG LIBRARY PORT CERT_FILE KEY_FILE CALIBRE_HOST TMUX_SESSION; do
    if [[ -z "${!key:-}" ]]; then
        missing_keys="$missing_keys $key"
    fi
done
if [[ -n "$missing_keys" ]]; then
    echo "ERROR: config.sh is missing required key(s):$missing_keys"
    echo "  Compare your config.sh against config.sh.example and add them."
    exit 1
fi

# The venv's parent is wherever VENV_DIR points, so there is nothing extra to
# configure — one key, one source of truth.
VENV_PARENT="$(dirname "$VENV_DIR")"

# ── Python path (try common locations) ───────────────────────────────────────
PYTHON="/usr/local/bin/python3.12"

# ── Checks ────────────────────────────────────────────────────────────────────
echo "=========================================="
echo "  CalibreWeb Setup"
echo "=========================================="
echo ""

if [[ ! -f "$PYTHON" ]]; then
    # Try alternate common locations
    for p in /usr/bin/python3.12 /opt/homebrew/bin/python3.12 $(which python3.12 2>/dev/null); do
        if [[ -f "$p" ]]; then
            PYTHON="$p"
            break
        fi
    done
fi

if [[ ! -f "$PYTHON" ]]; then
    echo "ERROR: Python 3.12 not found. Install it first:"
    echo "  brew install python@3.12"
    exit 1
fi

echo "  Python   : $PYTHON ($($PYTHON --version))"
echo "  Venv     : $VENV_DIR"
echo "  Config   : $CALIBRE_WEB_CONFIG"
echo "  Library  : $LIBRARY"
echo "  Port     : $PORT"
echo "  Cert     : $CERT_FILE"
echo "  Key      : $KEY_FILE"
echo ""

if [[ ! -f "$CERT_FILE" ]]; then
    echo "WARNING: Certificate not found at $CERT_FILE"
    echo "  CalibreWeb will run without SSL until certificates are in place."
fi

if [[ ! -f "$KEY_FILE" ]]; then
    echo "WARNING: Key not found at $KEY_FILE"
fi

if [[ ! -d "$LIBRARY" ]]; then
    echo "WARNING: Library not found at $LIBRARY"
    echo "  You will need to set the library path manually in the CalibreWeb UI."
fi

echo ""
read -r -p "Proceed with installation? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Stop any running Calibre processes ───────────────────────────────────────
echo ""
echo "Stopping any running Calibre processes..."
killall calibre 2>/dev/null || true
pkill -TERM -f "cps" 2>/dev/null || true
sleep 3
echo "  ✓ Done"

# ── Create venv ───────────────────────────────────────────────────────────────
echo ""
echo "Creating venv..."

# Ensure parent directory exists
mkdir -p "$VENV_PARENT"

# Create the calibre-web-env inside it if it doesn't exist
if [[ -d "$VENV_DIR" && -f "$VENV_DIR/bin/activate" ]]; then
    echo "  Venv already exists at $VENV_DIR — reusing."
else
    echo "  Creating calibre-web-env in $VENV_PARENT..."
    "$PYTHON" -m venv "$VENV_DIR"
    echo "  ✓ Created venv at $VENV_DIR"
fi

# Activate venv
source "$VENV_DIR/bin/activate"

# Upgrade pip
echo "  Upgrading pip..."
pip install --upgrade pip --quiet
echo "  ✓ pip upgraded"

# ── Install CalibreWeb ────────────────────────────────────────────────────────
echo ""
echo "Installing CalibreWeb..."
pip install calibreweb --quiet
echo "  ✓ CalibreWeb installed"

# ── Install optional features ─────────────────────────────────────────────────
echo ""
echo "Installing optional features from optional-requirements.txt..."
OPTIONAL_REQ_URL="https://raw.githubusercontent.com/janeczku/calibre-web/master/optional-requirements.txt"
OPTIONAL_REQ_FILE=$(mktemp)
if curl -fsSL "$OPTIONAL_REQ_URL" -o "$OPTIONAL_REQ_FILE" 2>/dev/null; then
    # Install only the packages relevant to comics, goodreads and metadata
    # Filter out ldap, gdrive and other heavy optional deps not needed
    grep -E "comicapi|goodreads|rarfile|natsort|Pillow|lxml|flask-wtf|google-api|PyDrive" "$OPTIONAL_REQ_FILE"         | pip install -r /dev/stdin --quiet 2>/dev/null || true
    rm -f "$OPTIONAL_REQ_FILE"
    echo "  ✓ Optional features installed"
else
    echo "  ⚠ Could not fetch optional-requirements.txt — skipping optional features"
    echo "    Install manually later with: pip install comicapi goodreads"
    rm -f "$OPTIONAL_REQ_FILE"
fi

# ── Configure app.db ─────────────────────────────────────────────────────────
echo ""
echo "Configuring CalibreWeb..."

configure_appdb() {
    local db="$CALIBRE_WEB_CONFIG/app.db"
    local is_fresh="${1:-false}"

    # Helper: prompt for a setting, update if confirmed
    update_setting() {
        local label="$1"
        local column="$2"
        local default_val="$3"
        local current_val

        current_val=$(sqlite3 "$db" "SELECT $column FROM settings LIMIT 1;" 2>/dev/null || echo "")

        if [[ "$is_fresh" == "true" ]]; then
            # Fresh install — just apply defaults silently
            sqlite3 "$db" "UPDATE settings SET $column='$default_val' WHERE 1;"
        else
            echo ""
            echo "  $label"
            echo "    Current : ${current_val:-<not set>}"
            echo "    Default : $default_val"
            read -r -p "    Update? (yes/no) [no]: " choice
            if [[ "$choice" == "yes" ]]; then
                read -r -p "    New value [$default_val]: " new_val
                new_val="${new_val:-$default_val}"
                sqlite3 "$db" "UPDATE settings SET $column='$new_val' WHERE 1;"
                echo "    ✓ Updated to: $new_val"
            else
                echo "    → Keeping: ${current_val:-<not set>}"
            fi
        fi
    }

    update_setting "Port" "config_port" "$PORT"
    update_setting "Calibre library path" "config_calibre_dir" "$LIBRARY"
    update_setting "SSL certificate file" "config_certfile" "$CERT_FILE"
    update_setting "SSL key file" "config_keyfile" "$KEY_FILE"

}

if [[ -f "$CALIBRE_WEB_CONFIG/app.db" ]]; then
    # Back up existing app.db before making any changes
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_DB="$CALIBRE_WEB_CONFIG/app.db.$TIMESTAMP"
    cp "$CALIBRE_WEB_CONFIG/app.db" "$BACKUP_DB"
    echo "  ✓ Backed up existing app.db to app.db.$TIMESTAMP"
    echo ""
    echo "  Existing app.db found. You can update individual settings below."
    echo "  Press enter or type 'no' to keep current values."
    configure_appdb "false"

    # ── Validate SSL paths after configuration ────────────────────────────────
    echo ""
    echo "  Validating configured paths..."
    DB="$CALIBRE_WEB_CONFIG/app.db"
    CONFIGURED_CERT=$(sqlite3 "$DB" "SELECT config_certfile FROM settings LIMIT 1;" 2>/dev/null || true)
    CONFIGURED_KEY=$(sqlite3 "$DB" "SELECT config_keyfile FROM settings LIMIT 1;" 2>/dev/null || true)
    CONFIGURED_LIB=$(sqlite3 "$DB" "SELECT config_calibre_dir FROM settings LIMIT 1;" 2>/dev/null || true)

    if [[ -n "$CONFIGURED_CERT" && ! -f "$CONFIGURED_CERT" ]]; then
        echo "  ⚠ WARNING: SSL certificate not found at: $CONFIGURED_CERT"
        echo "    CalibreWeb will fail to start with SSL. Update via the UI or re-run this script."
    else
        echo "  ✓ SSL certificate: $CONFIGURED_CERT"
    fi

    if [[ -n "$CONFIGURED_KEY" && ! -f "$CONFIGURED_KEY" ]]; then
        echo "  ⚠ WARNING: SSL key not found at: $CONFIGURED_KEY"
        echo "    CalibreWeb will fail to start with SSL. Update via the UI or re-run this script."
    else
        echo "  ✓ SSL key: $CONFIGURED_KEY"
    fi

    if [[ -n "$CONFIGURED_LIB" && ! -d "$CONFIGURED_LIB" ]]; then
        echo "  ⚠ WARNING: Calibre library not found at: $CONFIGURED_LIB"
        echo "    CalibreWeb will not find your books. Update via the UI or re-run this script."
    else
        echo "  ✓ Library path: $CONFIGURED_LIB"
    fi
else
    mkdir -p "$CALIBRE_WEB_CONFIG"
    echo "  No app.db found — fresh installation, generating initial app.db..."
    "$VENV_DIR/bin/cps" &
    CPS_PID=$!
    sleep 8
    kill $CPS_PID 2>/dev/null || true
    wait $CPS_PID 2>/dev/null || true

    if [[ -f "$CALIBRE_WEB_CONFIG/app.db" ]]; then
        configure_appdb "true"
        echo "  ✓ app.db created and configured"
        echo "  ⚠ Default credentials: admin / admin123 — change immediately after first login"
    else
        echo "  ⚠ app.db not created — configure port, library and SSL manually in the UI"
    fi
fi

# ── Start/stop scripts ────────────────────────────────────────────────────────
# These used to be written out here from heredocs. They are not any more:
# start_calibreweb.sh and stop_calibreweb.sh are maintained files in this repo,
# and generating them meant a second copy that silently drifted from the real
# one — and running setup on an existing install would overwrite the good
# version with the stale embedded one. Now setup just makes sure they are
# present and executable.
echo ""
echo "Checking start/stop scripts..."

missing_scripts=""
for s in start_calibreweb.sh stop_calibreweb.sh; do
    if [[ -f "$SCRIPT_DIR/$s" ]]; then
        chmod +x "$SCRIPT_DIR/$s"
        echo "  ✓ $s"
    else
        missing_scripts="$missing_scripts $s"
    fi
done

if [[ -n "$missing_scripts" ]]; then
    echo "  ⚠ Missing from $SCRIPT_DIR:$missing_scripts"
    echo "    These ship with the repo — check your clone is complete."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Setup complete."
echo "=========================================="
echo ""
echo "  Start CalibreWeb : $SCRIPT_DIR/start_calibreweb.sh"
echo "  Stop CalibreWeb  : $SCRIPT_DIR/stop_calibreweb.sh"
echo "  Attach to tmux   : tmux attach -t $TMUX_SESSION"
echo ""
echo "  On first run, log in at $CALIBRE_HOST"
echo "  Default credentials: admin / admin123"
echo "  Change password immediately after first login."
echo ""
echo "  If library path or SSL need adjustment, use the CalibreWeb admin UI."
echo "=========================================="
