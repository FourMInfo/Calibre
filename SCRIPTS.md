# Script Documentation

Detailed documentation for each script in this repository.

---

## `config.sh.example`

Template for local machine configuration. Copy to `config.sh` (gitignored) and fill in your values before running any scripts.

```bash
cp config.sh.example config.sh
```

Scripts that need machine-specific values source `config.sh` automatically via:
```bash
source "$(dirname "$0")/config.sh"
```

The utility scripts (`calibre_sync.sh`, `calibre_check_integrity.sh`, `calibre_update_metadata.sh`) take all paths as arguments so they don't require `config.sh`.

---

## `calibre_nightly_backup.sh`

Automated nightly backup of the Calibre library with snapshot rotation.

### Usage
```bash
./calibre_nightly_backup.sh
```

Normally run automatically via launchd at 2am. Can be run manually at any time.

### What it does

1. Stops CalibreWeb and Calibre (via `stop_calibreweb.sh`)
2. Waits 60 seconds for clean database shutdown
3. Verifies library exists and `metadata.db` is present
4. Runs integrity check — results logged, never aborts backup
5. rsyncs library to external drive with `--link-dest` deduplication
6. rsyncs library to iCloud Documents with `--link-dest` deduplication
7. Rotates snapshots: 7 dailies, 4 weeklies, 2 monthlies, 1 yearly
8. Restarts CalibreWeb (via `start_calibreweb.sh`)

### Rotation policy

| Type | Count | Promoted from | When |
|------|-------|---------------|------|
| Daily | 7 | — | Every night |
| Weekly | 4 | Latest daily | Every Sunday |
| Monthly | 2 | Latest weekly | 1st of month |
| Yearly | 1 | Latest monthly | Jan 1st |

### Logs
Timestamped logs written to `$LOG_DIR/calibre_backup_YYYYMMDD_HHMMSS.log`. Last 30 logs kept, older ones pruned automatically. If the external drive is not mounted, a `_WARNING.log` file is written instead.

### Dependencies
- `stop_calibreweb.sh` and `start_calibreweb.sh` must be in `$SCRIPTS_DIR`
- `calibre_check_integrity.sh` must be in `$SCRIPTS_DIR`
- `/usr/bin/rsync` must have Full Disk Access in System Settings
- `/bin/bash` must have Full Disk Access in System Settings

---

## `calibre_check_integrity.sh`

Scans a Calibre library for corrupt PDF and EPUB files.

### Usage
```bash
./calibre_check_integrity.sh /path/to/library [/path/to/log/dir]
```

If log directory is omitted, logs are written to the current directory.

### What it checks

- **PDFs**: runs `pdfinfo` — requires `brew install poppler`
- **EPUBs**: checks zip integrity and required EPUB structure (`mimetype` file, `.opf` file)

### Output
- Prints OK/CORRUPT status for each file to stdout
- Writes a `calibre_integrity_YYYYMMDD_HHMMSS.log` only if corrupt files are found
- If all files pass, no log file is created
- Always exits 0 — corrupt files are reported but never abort a calling script

### Notes
- Python checker code is written to a temp file rather than a heredoc to avoid `set -e` being triggered by Python's non-zero exit on corrupt files
- Last 30 integrity logs kept, older ones pruned automatically

---

## `calibre_sync.sh`

Compares two Calibre library folders and copies book folders present in the source but missing from the destination into a staging folder.

### Usage
```bash
./calibre_sync.sh /path/to/source /path/to/destination [/path/to/staging]
```

- **SOURCE**: old or damaged library (read-only, never modified)
- **DEST**: restored library (used for comparison)
- **STAGING**: optional folder to copy missing books into (recommended)

If staging is omitted, missing books are copied directly into the destination preserving Calibre's Author/Title folder structure.

### What it does
1. Scans destination for existing book files
2. Scans source for book files not present in destination
3. Shows dry-run list and asks for confirmation
4. Copies missing book folders (including OPF metadata) to staging

### Notes
- Copies entire book folders, not just files, so OPF metadata travels with the books
- After copying, use Calibre's `Add books from folders` on the staging folder to import
- Uses `find` with proper `-o` grouping rather than `ls` with multiple globs (safe under `set -e`)
- Bash 3.2 compatible — uses sorted temp file instead of associative array

---

## `calibre_update_metadata.sh`

For each OPF file in a staging folder, finds the matching book in the Calibre library by title and updates its metadata using `calibredb set_metadata`.

### Usage
```bash
./calibre_update_metadata.sh /path/to/opf/folder /path/to/library
```

### What it does
1. Finds all `.opf` files in the staging folder
2. Extracts title from each OPF
3. Searches the library for a matching book by title
4. Updates metadata via `calibredb set_metadata`

### Notes
- Decodes HTML entities in titles (`&amp;` → `&`) before searching — Calibre stores some titles with HTML entities in OPF files
- Two-pass search: exact match first, then loose match
- Make sure Calibre app and `calibre-parallel` processes are NOT running before using this — same threading issue applies to `calibredb` as to the GUI
- Logs updated, not-found, and failed books separately

---

## `calibre_restore_preview.sh`

Lists available backup snapshots from all locations and rsyncs the chosen snapshot to a timestamped preview folder for manual review. Does **not** touch the live library.

### Usage
```bash
./calibre_restore_preview.sh
```

### What it does
1. Lists all available snapshots from external drive, iCloud, and local backup machine external
2. Stops CalibreWeb and Calibre
3. Waits 60 seconds for clean shutdown
4. rsyncs chosen snapshot to `/Volumes/Extreme/CalibreRestore/preview_<timestamp>_<snapshot>`
5. Runs integrity check on the preview
6. Leaves CalibreWeb stopped so you can switch library in Calibre app for manual review
7. Saves preview path to `$LOG_DIR/.calibre_restore_preview_path` for use by finalize script

### After running
1. Open Calibre app
2. Switch library to the preview folder
3. Review that everything looks correct
4. If satisfied, run `calibre_restore_finalize.sh`
5. If not satisfied, run `start_calibreweb.sh` to return to normal without any changes

---

## `calibre_restore_finalize.sh`

Finalizes a restore after manual review of the preview library. Run only after `calibre_restore_preview.sh` and manual verification.

### Usage
```bash
./calibre_restore_finalize.sh
```

### What it does
1. Reads preview path from `$LOG_DIR/.calibre_restore_preview_path`
2. Asks for double confirmation
3. Ensures CalibreWeb and Calibre are stopped
4. `cp -R` current live library to external drive with timestamp (safety copy)
5. `rm -rf` live library
6. `cp -R` preview folder to live library location
7. Restarts CalibreWeb

### Warning
This is a destructive operation. A safety copy of the current library is made before deletion, but make absolutely sure you have reviewed the preview first.

---

## Testing a Restore

Before you need to do a real restore, it is worth testing the process so you are confident it works. Here is the recommended testing strategy:

**Step 1 — Run the preview:**
```bash
./calibre_restore_preview.sh
```
Choose a recent snapshot. The script will rsync it to a preview folder and run an integrity check.

**Step 2 — Compare preview to live library:**
```bash
diff -rq "/Users/YOUR_USERNAME/Calibre Library" "/Volumes/YOUR_EXTERNAL_DRIVE/CalibreRestore/preview_TIMESTAMP_SNAPSHOT" 2>/dev/null | head -30
```
For a same-day snapshot you should see only minor differences like `.DS_Store` files or books added since the snapshot was taken. Any missing books will show as `Only in` lines on the live library side.

**Step 3 — Open Calibre and switch library:**
In Calibre: Preferences → Libraries → switch to the preview folder. Browse around, check metadata, verify books open correctly.

**Step 4 — If satisfied, abort the test restore:**
Simply run `start_calibreweb.sh` to restart CalibreWeb without running `calibre_restore_finalize.sh`. The live library is untouched.

**Step 5 — In a real restore scenario:**
If you also have a damaged library with metadata added since the backup, run `calibre_update_metadata.sh` after `calibre_restore_finalize.sh` to recover any metadata from OPF files in the damaged library. See `calibre_update_metadata.sh` documentation above for details.

---

## `setup_calibreweb.sh`

Sets up a fresh CalibreWeb installation or reinstalls into an existing venv while preserving configuration.

### Usage
```bash
chmod +x setup_calibreweb.sh
./setup_calibreweb.sh
```

### What it does
1. Locates Python 3.12 (checks multiple common paths)
2. Kills any running Calibre/CalibreWeb processes
3. Creates venv at `~/Code/venv/calibre-web-env/` if it doesn't exist
4. Installs CalibreWeb via pip
5. Installs optional features (comics, goodreads, metadata, gdrive) from `optional-requirements.txt`
6. **Reinstall mode** (existing `app.db`): backs up `app.db` with timestamp, prompts for each setting individually, validates SSL cert/key/library paths exist after configuration
7. **Fresh install mode** (no `app.db`): starts `cps` briefly to generate `app.db`, configures port/library/SSL via sqlite3
8. Generates `start_calibreweb.sh` and `stop_calibreweb.sh` in Scripts directory

### Path validation
After configuration the script validates that the SSL certificate, SSL key, and library path all exist on disk, warning immediately if any are missing. This catches the common mistake of answering "no" to updating a path that has since moved.

### Notes
- Uses `export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"` for Intel/Apple Silicon portability
- The venv parent directory (`~/Code/venv/`) is a container for multiple environments — the CalibreWeb venv is specifically at `~/Code/venv/calibre-web-env/`

---

## `start_calibreweb.sh`

Starts CalibreWeb inside a named tmux session.

### Usage
```bash
./start_calibreweb.sh
# Attach to session:
tmux attach -t calibreweb
```

### Notes
- Checks for actual `cps` process, not just tmux session existence
- If a stale tmux session exists without `cps` running, kills the session before starting fresh
- Uses full path logic for tmux via `PATH` export covering both Intel (`/usr/local/bin`) and Apple Silicon (`/opt/homebrew/bin`)

---

## `stop_calibreweb.sh`

Gracefully stops CalibreWeb, kills the tmux session, and stops the Calibre app and worker processes.

### Usage
```bash
./stop_calibreweb.sh
```

### What it stops
1. `cps` process (SIGTERM, then SIGKILL if still running after 5 seconds)
2. tmux `calibreweb` session
3. `calibre` app
4. `calibre-parallel` worker processes

### Notes
- Stopping Calibre and its parallel workers is important before any database operation — `calibre-parallel` workers hold database connections that cause `apsw.ThreadingViolationError` if not killed first

---

## `install_calibre_backup_launchd.sh`

Installs the nightly backup script as a launchd agent running at 2am.

### Usage
```bash
chmod +x install_calibre_backup_launchd.sh
./install_calibre_backup_launchd.sh
```

### Notes
- Uses `~/Library/LaunchAgents` (user agent) — requires login session, not system-level
- Appropriate for a always-on Mac Mini where the user is always logged in
- Unloads existing job before reinstalling to ensure clean state

### To uninstall
```bash
launchctl unload ~/Library/LaunchAgents/info.fourm.calibre-backup.plist
rm ~/Library/LaunchAgents/info.fourm.calibre-backup.plist
```

---

## `info.fourm.calibre-backup.plist`

launchd property list that schedules `calibre_nightly_backup.sh` to run at 2:00am daily.

### Key settings
- `StartCalendarInterval`: Hour 2, Minute 0
- `RunAtLoad`: false — only runs at scheduled time, not on login
- stdout/stderr redirected to `/dev/null` — the backup script writes its own timestamped logs

### Installation path
```
~/Library/LaunchAgents/info.fourm.calibre-backup.plist
```

---

## Common Issues

### `apsw.ThreadingViolationError` during restore or metadata update
Calibre pre-spawns `calibre-parallel` worker processes that hold database connections. Kill them before any database operation:
```bash
killall calibre
killall calibre-parallel
```

### `Operation not permitted` on external drive from launchd
launchd agents don't inherit Full Disk Access from the user session. Add to FDA in System Settings:
- `/usr/bin/rsync`
- `/bin/bash`

### `Too many open files` during rsync
macOS default file descriptor limit (256) is too low for large libraries. The backup script sets `ulimit -n 65536` automatically, but if running rsync manually:
```bash
ulimit -n 65536
rsync ...
```

### CalibreWeb SSL error mid-session
CalibreWeb periodically re-reads its SSL certificate. If the certificate or key path in `app.db` no longer exists on disk, it will fail hours after startup. Verify with:
```bash
sqlite3 ~/.calibre-web/app.db "SELECT config_certfile, config_keyfile FROM settings;"
```
Fix via the CalibreWeb admin UI at `http://localhost:YOUR_PORT` or by re-running `setup_calibreweb.sh`.

### `tmux: command not found` from launchd
launchd has a minimal PATH that doesn't include Homebrew. The start/stop scripts export the full path:
```bash
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
```
If you see this error, re-run `setup_calibreweb.sh` to regenerate the start/stop scripts with the correct PATH.
