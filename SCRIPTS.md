# Script Documentation

Detailed documentation for each script in this repository.

---

## `config.sh.example`

Template for local machine configuration. Copy to `config.sh` (gitignored) and fill in your values before running any scripts.

```bash
cp config.sh.example config.sh
```

**Every** script sources `config.sh`, using the same three lines at the top:

```bash
_self_dir="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$_self_dir/config.sh" ]] || { echo "ERROR: config.sh not found"; exit 1; }
source "$_self_dir/config.sh"
```

`_self_dir` is derived rather than configured because it is what *finds* `config.sh` — it cannot come from the file it locates. Scripts that need a script directory afterwards do `SCRIPT_DIR="${SCRIPT_DIR:-$_self_dir}"`, so a `SCRIPT_DIR` set in `config.sh` wins and the script's own directory is the fallback.

The utility scripts (`calibre_sync.sh`, `calibre_check_integrity.sh`, `calibre_update_metadata.sh`) used to take every path as an argument and skip `config.sh` entirely. They now require it like everything else, and their arguments fall back to config values where a sensible default exists. Arguments still win when supplied, which is what the scripts that call each other rely on. If you are running one of these from a bare clone, copy `config.sh.example` to `config.sh` first even if you intend to pass all paths explicitly.

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
5. rsyncs library to external drive with `--link-dest` hard-link deduplication
6. rclone syncs library to iCloud with `--backup-dir` versioning
7. Rotates external drive snapshots: 7 dailies, 4 weeklies, 2 monthlies, 1 yearly
8. Prunes iCloud versions: keeps last 7 daily version folders
9. Restarts CalibreWeb (via `start_calibreweb.sh`)
10. Copies the snapshots to the backup hub (via `calibre_backup_to_hub.sh`), if `HUB_SSH_HOST` is set and tonight's snapshot succeeded. This runs after the restart, so a long copy never keeps CalibreWeb down.

### Why two different tools for two destinations

The external drive uses `rsync --link-dest` because it is a proper POSIX filesystem that supports hard links. Each snapshot is a full point-in-time copy of the library but costs only ~1GB incremental per day via hard-link deduplication.

iCloud does not support hard links. Testing showed that `rsync --link-dest` on iCloud produces broken snapshots — all versions share inodes and mutate together, so every snapshot ends up reflecting the latest state rather than the state at creation time. `rclone` with `--backup-dir` avoids this: before each sync it moves changed and deleted files into a dated versions folder, giving genuine per-file recovery without relying on hard links.

### iCloud backup structure

```
~/Documents/Backups/Calibre/
    current/                    ← rolling mirror, always reflects last backup
    versions/
        daily.20260415_020000/  ← files changed or deleted on Apr 15
        daily.20260414_020000/  ← files changed or deleted on Apr 14
        ...                     (7 kept, older pruned)
```

`current/` is a complete copy of the library as of the last backup. Use this for a full iCloud restore.

`versions/` folders contain only the files that changed or were deleted on that specific night — not full snapshots. Use these to recover a specific file that was good a few nights ago but has since been corrupted or deleted. To restore a specific file: find it in the appropriate version folder and copy it back manually.

### External drive rotation policy

| Type | Count | Promoted from | When |
|------|-------|---------------|------|
| Daily | 7 | — | Every night |
| Weekly | 4 | Latest daily | Every Sunday |
| Monthly | 2 | Latest weekly | 1st of month |
| Yearly | 1 | Latest monthly | Jan 1st |

A monthly is a copy of the latest weekly, so when the 1st is not a Sunday it can be up to six days older than that night's daily. Likewise a yearly is the January monthly.

Tonight's rsync links against the newest **daily** (`--link-dest`), falling back to the newest weekly, monthly, then yearly only if there is no daily. Weeklies and the rest are copies of a daily, so the newest daily always holds the newest content. Until November 2026 one sort over all the names chose the snapshot, and since `weekly.*` sorts after `daily.*` it linked against the latest weekly, storing up to six days of changes again instead of linking them.

Weekly/monthly/yearly rotation is not done for iCloud because rclone version folders contain only deltas, not full snapshots — promoting a delta folder as a weekly would be misleading.

### Logs
Timestamped logs written to `$LOG_DIR/calibre_backup_YYYYMMDD_HHMMSS.log`. Last `$KEEP_LOGS` logs kept, older ones pruned automatically.

Two extra marker logs may be written *alongside* the main log, so a glance at `ls $LOG_DIR` tells you the outcome without opening anything:

| File | Meaning |
|------|---------|
| `..._WARNING.log` | External drive was not mounted — the iCloud backup still ran |
| `..._FAILED.log` | One or more steps failed; the file names which ones |

The warning log is written *before* the main log is even opened, because `$LOG_DIR` could itself have been on the missing drive. The failure log is written last and the script exits 1.

A failing step records itself via `note_failure` and the script carries on, so a broken rsync does not cost you the iCloud sync or the restart of CalibreWeb — the partial backup is still worth having. Rotation runs *before* the failure marker is written, so today's `_FAILED.log` is never the file that gets pruned. Note that all three names match the `calibre_backup_*.log` glob, so a `_WARNING.log` or `_FAILED.log` counts against `$KEEP_LOGS` like any other.

### Mount detection

Whether the external drive is present is decided with:

```bash
mount | grep -qF " on $HOST_DRIVE ("
```

not with `[[ -d "$HOST_DRIVE" ]]`. On a clean unmount `diskarbitrationd` removes the mountpoint directory, so the directory test usually works — but after an unclean ejection an empty `/Volumes/Extreme` can be left behind on the internal disk, and the directory test would then happily rsync 190GB of library into it. `grep -F` keeps the pattern literal so a drive name containing regex characters is safe, and the trailing `(` stops `/Volumes/Extreme` from matching `/Volumes/Extreme2`.

`HOST_DRIVE` is derived from `HOST_BACKUP` rather than configured separately, so there is no way for the two to disagree.

Two separate flags are tracked: `HOST_MOUNTED` (is the drive there at all) and `HOST_BACKUP_OK` (did the rsync actually succeed). Snapshot rotation is gated on the second, so a failed rsync can never cause a half-written snapshot to be promoted to weekly and a known-good one to be pruned.

### Snapshots that come back, and free space

Two checks write to the `_FAILED.log` (and raise a notification) without stopping the run:

- **Free space**, before the rsync: below `MIN_FREE_GB` (default 50) on the external drive. A normal night adds about 1 GB, so low space means something else is writing to the drive.
- **Surplus snapshots**, before the prune: more than `KEEP_DAILY + 1` dailies (tonight's is already written), or more than `KEEP_*` of the other kinds. The oldest ones, which are the ones that should not be there, are named.

Why these exist: in November 2026 the snapshots sat inside the Sync.com client's sync folder, and after Sync was reinstalled it kept restoring pruned snapshots from its cloud copy, as full copies without hard links (up to 209 GB each). Rotation deleted them each night and they came back, until the drive was full. Pruning cannot fix that, so the run reports it instead. The fix is on the sync side: delete the restored snapshots from the cloud copy first, then locally.

### Dependencies
- `stop_calibreweb.sh` and `start_calibreweb.sh` must be in `$SCRIPT_DIR`
- `calibre_check_integrity.sh` must be in `$SCRIPT_DIR`
- `rclone` must be installed: `brew install rclone`
- `/usr/bin/rsync` must have Full Disk Access in System Settings
- `/bin/bash` must have Full Disk Access in System Settings
- On a new Mac, and after anything replaces rclone, run `calibre_backup_permissions.sh` once (below)

---

## `calibre_backup_to_hub.sh`

Copies every snapshot on the external drive (`HOST_BACKUP`) to another Mac, the backup hub, over ssh, keeping the hard links. The hub can then take them off-site; in this setup its Sync.com client uploads them.

### Usage
```bash
./calibre_backup_to_hub.sh                   # copy
./calibre_backup_to_hub.sh --dry-run         # show what would be sent and deleted; change nothing
./calibre_backup_to_hub.sh --allow-deletes   # copy even if many snapshots would be deleted on the hub
```

`calibre_nightly_backup.sh` runs it as its last step when `HUB_SSH_HOST` is set in `config.sh`. It can also be run by hand. The first run sends the whole library (about 256 GB in November 2026), and later runs send about a night's changes.

### How it copies

One `rsync -aH --delete` of the whole snapshot folder. `-H` keeps the hard links between the snapshots, and links a new snapshot's unchanged files to the copies the hub already has, so nothing unchanged is sent twice. Snapshots pruned on the drive are pruned on the hub, so the hub always holds the same set. The script copies snapshots; it never rotates anything itself.

Syncthing is not used for this: it does not keep hard links, so each snapshot would arrive as a full copy of the library (14 snapshots of a 256 GB library would need about 3.5 TB).

Apple's `/usr/bin/rsync` (openrsync) on both Macs is enough; it supports `-H` and `--delete`.

**A dry run overstates the size.** With `--dry-run`, openrsync counts every hard-linked path as a transfer, so 14 snapshots show as 14 full libraries (3.56 TB and 393,660 files in November 2026). A real copy sends each file once and links the rest (tested: a file linked into two snapshots was sent once, and both paths share one inode on the hub). What a first copy really sends is `du -sh "$HOST_BACKUP"`, which counts each file once: 439 GB then.

### Checks before anything is sent

The run stops, and the nightly's `_FAILED.log` names it, if:

- the external drive is not mounted (the same `mount` test as the nightly);
- the drive has no daily snapshot. With `--delete`, mirroring an emptied folder would empty the hub;
- the hub does not answer over ssh. The key must work without a passphrase or an agent, since launchd runs the nightly;
- the hub's drive is not mounted. Otherwise rsync would fill the hub's internal disk under `/Volumes`;
- more than `MAX_HUB_SNAPSHOT_DELETES` (default 3) snapshots would be deleted on the hub. A normal night deletes one or two; more means the drive lost snapshots. Check it, then run once with `--allow-deletes`;
- another copy is still running (a lock in `~/.local/state/calibre-hub/`; a lock left by a run that died is taken over).

---

## `calibre_backup_now.sh`

By hand, after a day of metadata or tagging work you do not want to lose before the 02:00 nightly: stops CalibreWeb, mirrors the live library (`LIBRARY`) to `HUB_LIBRARY_COPY` on the backup hub over ssh, and starts CalibreWeb again.

### Usage
```bash
calibre_backup_now.sh             # copy (quit Calibre first)
calibre_backup_now.sh --dry-run   # list what would be sent and deleted; change nothing, CalibreWeb keeps running
```

It runs by name from anywhere through a link in `~/.local/bin` (Dotfiles.Private `Files/links.txt`), and resolves that link to find `config.sh`, `stop_calibreweb.sh` and `start_calibreweb.sh`.

### How it copies

One `rsync -a --delete`, excluding `.DS_Store` and `full-text-search.db`. The full-text index is about 18 GB and is rewritten whenever books are added, so it would keep CalibreWeb down for most of each run; the nightly snapshots carry it. The copy is a mirror, not a snapshot: it holds the library as of the last run, and the snapshots keep the history. The first copy was seeded on the hub from a snapshot, so a run sends about a day's changes.

### Checks

It stops before anything is changed if the Calibre app is open (quit it: unlike the nightly, it does not kill Calibre), if the nightly or a snapshot copy to the hub is running, if `LIBRARY` has no `metadata.db` (with `--delete`, an empty source would empty the copy), or if the hub or its drive is missing. After the copy, `metadata.db`'s md5 and the number of files must be the same on both ends. CalibreWeb is started again also when a step fails; the log (`calibre_now_*` in `LOG_DIR`) says if that did not work.

### Checks after the copy

- The hub holds exactly the drive's snapshots.
- A file in the newest daily on the hub has more than one link. If none has, the snapshots arrived as full copies.

### Logs

`$LOG_DIR/calibre_hub_YYYYMMDD_HHMMSS.log`, last `$KEEP_LOGS` kept. When the nightly runs it, its own log only says whether the copy succeeded.

### Config

`HUB_SSH_HOST` (a Host in `~/.ssh/config`; empty = skipped), `HUB_BACKUP` (the folder on the hub; its parent must exist), `MAX_HUB_SNAPSHOT_DELETES` (optional, 3).

---

## `calibre_backup_permissions.sh`

Checks that the nightly backup will be allowed to read the iCloud backup folder and the external drive, before a night run finds out.

### Usage
```bash
./calibre_backup_permissions.sh               # waits up to 300 seconds
./calibre_backup_permissions.sh --timeout 60
```

Exit status: `0` every probe passed, `1` one failed, `2` no answer in time.

### Why it exists

macOS asks once per program before it may touch `~/Documents` (where the iCloud backup lives) or a removable drive. The nightly backup runs at 2am from launchd, so nobody answers: the job waits, with Calibre and CalibreWeb stopped, until someone clicks the dialog. It happens on a new Mac, and again when an upgrade replaces rclone (2026-11-08: an 8-hour stall after brew upgraded rclone).

### What it does

It starts a one-off launchd job in your login session, the way the nightly job runs, which calls the same script with `--probe`. The probe runs read-only versions of what the backup does:

- `rclone lsd "$ICLOUD_BACKUP"`
- `rsync --list-only "$HOST_BACKUP/"` (skipped when the drive is not mounted)

If a dialog appears on the Mac's screen meanwhile, click **Allow**, and the probe finishes. On a timeout the job is left loaded so the dialog stays answerable; the next run clears it.

Running the probes straight from a terminal would prove nothing: macOS would credit the access to the terminal app, not to what launchd runs at night.

---

## `calibre_library_manifest.sh`

Writes a sorted manifest of a library folder, one line per file, so two copies of a library can be compared with `diff`.

### Usage
```bash
./calibre_library_manifest.sh [--md5] [LIBRARY_DIR] > manifest.txt
```

- Without `--md5`: `path<TAB>size<TAB>modification time`. Takes seconds; catches missing, extra, resized and re-dated files.
- With `--md5`: `path<TAB>md5`. Reads every byte (minutes for a large library); also catches changed content.

`LIBRARY_DIR` defaults to `LIBRARY` in `config.sh`. Paths are relative to the library, so libraries in different places compare cleanly. `.DS_Store` files and Syncthing's `.stfolder` are left out, as the iCloud backup leaves them out.

### Comparing a restore with the live library on another Mac

```bash
./calibre_library_manifest.sh --md5 "/Users/Shared/Calibre Library" > here.txt
ssh OtherMac 'bash -s -- --md5 ~/"Calibre Library"' < calibre_library_manifest.sh > there.txt
diff here.txt there.txt && echo identical
```

When a folder is named, the script needs no `config.sh`, which is what lets it run piped over ssh.

---

## `calibre_check_integrity.sh`

Scans a Calibre library for corrupt PDF and EPUB files.

### Usage
```bash
./calibre_check_integrity.sh [/path/to/library] [/path/to/log/dir]
```

Both arguments are optional and fall back to `LIBRARY` and `LOG_DIR` in `config.sh`. Arguments still win when given, which is what the two callers depend on: `calibre_nightly_backup.sh` passes the live library and `calibre_restore_preview.sh` passes a preview folder.

### What it checks

- **PDFs**: runs `pdfinfo` — requires `brew install poppler`
- **EPUBs**: checks zip integrity and required EPUB structure (`mimetype` file, `.opf` file)

### Output
- Writes a `calibre_integrity_YYYYMMDD_HHMMSS.log` on **every** run, clean or not, with per-file OK/CORRUPT detail
- Prints one summary line to the terminal — files checked, files corrupt, and the log path
- Always exits 0 — corrupt files are reported but never abort a calling script

The log used to be deleted when nothing was wrong. That made a library that passed and a check that never ran leave exactly the same trace — nothing at all — so there was no way to tell "clean" from "didn't happen". The log is now always kept and rotation prunes it, and the summary line goes back out to the terminal through a file descriptor saved before the log redirect, so the outcome is visible without opening anything.

### Notes
- Python checker code is written to a temp file rather than a heredoc to avoid `set -e` being triggered by Python's non-zero exit on corrupt files
- Last `$KEEP_LOGS` integrity logs kept, older ones pruned automatically

### Useful commands

Extract just filenames from an integrity log and sort for comparison between two logs (strips path differences so only book names are compared):

```bash
# Compare two integrity logs by filename only (ignoring path differences)
grep -o '[^/]*\.epub\|[^/]*\.pdf' log1.log | sort > /tmp/live.txt
grep -o '[^/]*\.epub\|[^/]*\.pdf' log2.log | sort > /tmp/backup.txt
diff /tmp/live.txt /tmp/backup.txt
```

---

## `calibre_sync.sh`

Compares two Calibre library folders and copies book folders present in the source but missing from the destination into a staging folder.

### Usage
```bash
./calibre_sync.sh /path/to/source [/path/to/destination] [/path/to/staging]
```

- **SOURCE**: old or damaged library (read-only, never modified). Required — there is no sensible default for "whichever broken library you are recovering from".
- **DEST**: restored library (used for comparison). Defaults to `LIBRARY` in `config.sh`.
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
- Logs to `$LOG_DIR/calibre_sync_YYYYMMDD_HHMMSS.log`, last `$KEEP_LOGS` kept. The log used to be written into whatever directory you happened to be standing in, which scattered logs around and left them accumulating forever with nothing to rotate them out.
- The log is only created once you confirm the copy. Answering `no` at the dry-run prompt leaves no log behind, which is accurate — nothing was done.

---

## `calibre_update_metadata.sh`

For each OPF file in a staging folder, finds the matching book in the Calibre library by title and updates its metadata using `calibredb set_metadata`.

### Usage
```bash
./calibre_update_metadata.sh /path/to/opf/folder [/path/to/library]
```

STAGING is required — it is the folder of recovered books you have just built. LIBRARY defaults to `LIBRARY` in `config.sh`.

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
- `calibredb` is located via `CALIBREDB` in `config.sh` rather than a hardcoded `/Applications` path, and the script checks it is executable before doing anything
- Logs to `$LOG_DIR/calibre_update_metadata_YYYYMMDD_HHMMSS.log`, last `$KEEP_LOGS` kept

---

## `calibre_restore_preview.sh`

Lists available backup snapshots from all locations and copies the chosen snapshot to a timestamped preview folder for manual review. Does **not** touch the live library.

### Usage
```bash
./calibre_restore_preview.sh
```

### What it does
1. Lists all available snapshots: external drive snapshots, iCloud current, and iCloud version folders
2. Stops CalibreWeb and Calibre
3. Waits 60 seconds for clean shutdown
4. Copies chosen snapshot to `/Volumes/Extreme/CalibreRestore/preview_<timestamp>_<snapshot>` (rsync for external drive snapshots, rclone for iCloud)
5. Runs integrity check on the preview
6. Leaves CalibreWeb stopped so you can switch library in Calibre app for manual review
7. Saves preview path to `$LOG_DIR/.calibre_restore_preview_path` for use by finalize script

### Snapshot types and when to use them

| Source | Type | Use for |
|--------|------|---------|
| External drive daily/weekly/monthly/yearly | Full point-in-time snapshot | Primary restore option — complete library as of that date |
| iCloud current | Full rolling mirror | Full restore from iCloud — complete library as of last backup |
| iCloud versions/daily.* | Delta only | Per-file recovery only — NOT a full library snapshot |

iCloud version folders contain only files that changed or were deleted on that specific night. Selecting one as a restore source will produce an incomplete preview containing only those delta files. The script warns you before proceeding if you select a version folder.

### After running
1. Open Calibre app
2. Switch library to the preview folder
3. Review that everything looks correct
4. If satisfied, run `calibre_restore_finalize.sh`
5. If not satisfied, choose another snapshot to recover from

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

### Follow up steps
Assuming you are restoring because you have a damaged library with metadata added since the backup, run `calibre_update_metadata.sh` after `calibre_restore_finalize.sh` to recover any metadata from OPF files in the damaged library. See `calibre_update_metadata.sh` documentation above for details. Also check the integrity log from the previous step to see what might be damaged in the restore that needs recovery.

---

## Testing a Restore

Regular restore testing is essential — an untested backup is a hypothesis, not a guarantee. Recommended schedule: full restore test quarterly or after any significant event (hardware change, OS update, Calibre upgrade, external drive incident). Monthly spot-check of a small subset (10-20 random books) is low-effort and catches snapshot-level problems early.

**Step 1 — Run the preview:**
```bash
./calibre_restore_preview.sh
```
Choose the most recent external drive snapshot (in general the test should be run the morning after the nightly). The script will copy it to a preview folder and run an integrity check.

**Step 2 — Clean up DS_Store files before comparing**

macOS creates `.DS_Store` files in every folder you browse in Finder. These will show up as noise in the diff. The nightly backup excludes them going forward, but existing ones in the preview need to be cleaned up first.

Do NOT manually delete `.DS_Store` from the live library — use Calibre's built-in tool instead: **Calibre → Check Library → Fix** which will remove them cleanly.

For the preview folder, delete manually:
```bash
source ./config.sh
find "$(cat "$LOG_DIR/.calibre_restore_preview_path")" -name ".DS_Store" -delete
```

**Step 3 — Compare preview to live library with full log:**
```bash
source ./config.sh
PREVIEW="$(cat "$LOG_DIR/.calibre_restore_preview_path")"
LOG="$LOG_DIR/restore_diff_$(date +%Y%m%d).log"

diff -rq "$LIBRARY" "$PREVIEW" > "$LOG" 2>&1
echo "Exit code: $?"
echo "Non-DS_Store differences:"
grep -v ".DS_Store" "$LOG" | head -50
```

Writing to a log is important — with 8500+ books the output is too large for the terminal. The exit code `0` means identical, `1` means differences found. Check the log for any non-DS_Store differences — those are the ones that matter.

For a same-day snapshot you should see no real differences. Any `Only in live library` lines indicate books added since the snapshot was taken, which is expected.

**Step 4 — Compare integrity checks:**
Since the integrity check ran the night before should be identical to the integrity check run on the preview, an additional test which compares the integrity checks is useful. Note we need to remove the path and only look at the book name, otherwise there will always be a difference.
```bash
source ./config.sh
grep -o '[^/]*\.epub\|[^/]*\.pdf' "$LOG_DIR/calibre_integrity_RESTORE_TIMESTAMP.log" | sort > /tmp/live_files.txt
grep -o '[^/]*\.epub\|[^/]*\.pdf' "$LOG_DIR/calibre_integrity_LAST_BACKUP_TIMESTAMP.log" | sort > /tmp/backup_files.txt
diff /tmp/live_files.txt /tmp/backup_files.txt
```

**Step 5 — If satisfied, restart:**
Simply run `start_calibreweb.sh` to restart CalibreWeb without running `calibre_restore_finalize.sh`. The live library is untouched.

**Step 6 — Troubleshooting**
As noted in next section you might find missing files or have other issues, so be sure to fix those before the next backup. If there are more significant issues you should consider doing an immediate Calibre UI backup so you have at least one reliable option. You can then test to see if other backups are in good shape. In any case a thorough investigation should be done to solve the source of the issue.

### Known limitation: rsync and external drive corruption

rsync can occasionally produce corrupt files when writing to external drives, particularly on files that were being written at the moment of a brief disconnection or power fluctuation. This is rare but worth knowing:

- A file may be clean in the live library but corrupt in the external drive snapshot
- The integrity check in the nightly backup catches this — corrupt files are logged
- The iCloud snapshot is a separate rclone operation and may be clean where the external drive snapshot is corrupt
- If you find a corrupt file in a restore preview, check `iCloud current` before concluding it is unrecoverable
- This is exactly why we maintain two independent backup destinations

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
3. Creates the venv at `$VENV_DIR` if it doesn't exist
4. Installs CalibreWeb via pip
5. Installs optional features (comics, goodreads, metadata, gdrive) from `optional-requirements.txt`
6. **Reinstall mode** (existing `app.db`): backs up `app.db` with timestamp, prompts for each setting individually, validates SSL cert/key/library paths exist after configuration
7. **Fresh install mode** (no `app.db`): starts `cps` briefly to generate `app.db`, configures port/library/SSL via sqlite3
8. Verifies `start_calibreweb.sh` and `stop_calibreweb.sh` are present next to it and makes them executable

### Why it no longer generates the start/stop scripts

It used to write `start_calibreweb.sh` and `stop_calibreweb.sh` out from heredocs. That meant two copies of each script existed — the one in the repo and the one setup would overwrite it with — and the heredoc copy was the one that actually ran. Every fix to the repo copy was silently discarded the next time anyone ran setup. The repo copies are now the only copies; setup checks they exist and `chmod +x`es them.

### Path validation
After configuration the script validates that the SSL certificate, SSL key, and library path all exist on disk, warning immediately if any are missing. This catches the common mistake of answering "no" to updating a path that has since moved.

### Notes
- Uses `export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"` for Intel/Apple Silicon portability
- `VENV_DIR` points at the CalibreWeb environment itself, not at a directory of environments. Give it its own folder — something like `.../venv/calibre-web-env` — rather than a shared `venv` parent, or a reinstall will churn whatever else lives alongside it.

---

## `start_calibreweb.sh`

Starts CalibreWeb inside a named tmux session with two windows.

### Usage
```bash
./start_calibreweb.sh
# Attach to session:
tmux attach -t calibreweb
```

### Session layout

| Window | Contents |
|--------|----------|
| `cps` | CalibreWeb itself |
| `shell` | An interactive shell with the venv already activated, for debugging |

`cps` is selected on attach. The old single-window session ran `cps` in the foreground of an interactive shell, so the first thing you had to do on every attach was background it before you could type anything. Now `cps` has a window of its own and the second window is already sitting at a prompt with the venv active.

### How `cps` is launched

The command is handed straight to `tmux new-session` rather than typed in with `send-keys`:

```bash
tmux new-session -d -s "$SESSION" -n cps -c "$HOME" "/bin/bash -c '$CPS_CMD'"
```

`send-keys` races the shell's own startup. If an rc file prints a prompt first — oh-my-zsh's "Would you like to update? [Y/n]" being the one that actually bit — the prompt swallows the leading characters and `cps` never launches, silently. Passing the command to `new-session` means tmux runs it via `/bin/sh -c` with no interactive shell and no rc files, so there is nothing to race. (See the oh-my-zsh note in `Dotfiles.Mac`, which fixes the same bug from the other end.) `$CPS_CMD` must contain no single quotes, since it is embedded in a single-quoted string.

After `cps` exits, the window `exec`s into a login shell rather than closing, so a traceback stays on screen instead of vanishing with the pane.

### Where CalibreWeb logs

**CalibreWeb writes its own application log and this script does not interfere
with it.** It goes to `config_logfile` — `~/.calibre-web/calibre-web.log` by
default — and CalibreWeb appends to it, rotates it and decides its level itself.
The level and path are set in CalibreWeb's own Admin → Basic Configuration →
Logfile Configuration, stored in `app.db`, not in `config.sh`. Nothing in this
repo writes to that file, truncates it, or deletes it.

#### A one-line `calibre-web.log` is normal

CalibreWeb logs through a `RotatingFileHandler`. When `calibre-web.log` reaches
roughly 100 KB it is renamed to `calibre-web.log.1`, the previous `.1` becomes
`.2`, and a fresh empty `calibre-web.log` is started. Two backups are kept; the
old `.2` is discarded on each rotation.

So `calibre-web.log` holding a single line does not mean logging is broken. It
means a rotation happened recently and that line is everything written since.
Check before assuming a bug:

```bash
ls -la ~/.calibre-web/
wc -l ~/.calibre-web/calibre-web.log*
```

Read the history in order, oldest first:

```bash
cat ~/.calibre-web/calibre-web.log.2 \
    ~/.calibre-web/calibre-web.log.1 \
    ~/.calibre-web/calibre-web.log
```

At about 100 KB per file and two backups, this retains on the order of three
days. That ceiling is CalibreWeb's, not this repo's — nothing here rotates or
prunes it.

#### The removed `$LOG_DIR` copy

Earlier versions of this script also teed `cps`'s stdout and stderr to
`$LOG_DIR/calibre_web_YYYYMMDD_HHMMSS.log`, on the dated-and-pruned convention
every other log in the repo follows. That was wrong here, and worse than
redundant.

The tee put `cps`'s stdout on a **pipe**. Python block-buffers stdout when it is
not a terminal, holding several KB before writing anything, and
`stop_calibreweb.sh` stops `cps` with `pkill -TERM` — which by default
terminates the process without flushing stdio. Everything still sitting in the
buffer was destroyed on every stop. Python keeps stderr line-buffered even off a
terminal, so stderr lines survived; the surviving `Calibre-Web: server started
on :NNNN` is one of those. That is why the teed file was near-empty: not because
`cps` prints little, but because the pipe swallowed what it printed.

Before the tee existed, `cps` was launched via `send-keys` and its stdout was
the tmux pty — line-buffered, nothing lost. The tee introduced the pipe and the
data loss with it.

The tee, the timestamped file and its rotation are gone. `cps`'s stdout and
stderr now go to the tmux pane and nowhere else: the startup banner, plus
anything printed before logging is initialised or after it fails. Read it with
`tmux attach -t calibreweb`. It does not survive the session being killed, which
is the right lifetime for it.

If `$LOG_DIR` still holds `calibre_web_*.log` files, they are residue from the
old behaviour and can be deleted.

### Notes
- Checks for an actual `cps` process, not just tmux session existence
- If a stale tmux session exists without `cps` running, kills the session before starting fresh
- Exports `PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"` for Intel/Apple Silicon portability
- Deliberately does **not** use `set -euo pipefail` — a failed `pgrep` or `tmux has-session` is a normal, expected outcome here, not an error worth aborting on

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

### Service mode (start and stop)

With `CALIBRE_WEB_SERVICE_LABEL` set in `config.sh`, `start_calibreweb.sh` and `stop_calibreweb.sh` no longer use tmux. They load and unload the LaunchDaemon:

```bash
sudo -n /bin/launchctl bootstrap system /Library/LaunchDaemons/<label>.plist   # start
sudo -n /bin/launchctl bootout system/<label>                                  # stop
```

Those two commands, with exactly those arguments, are what the sudo rule from `setup_calibreweb_service.sh daemon` allows without a password, so the nightly backup can stop and restart CalibreWeb at 2am. `bootout` rather than a kill: the daemon restarts `cps` after a crash, and a kill looks like one. If the unload fails, `stop_calibreweb.sh` exits 1, and the nightly backup records it in its `_FAILED` log.

Loading the daemon starts `cps` (`RunAtLoad`); the daemon is also loaded at every boot from `/Library/LaunchDaemons`, before anyone logs in.

---

## `setup_calibreweb_service.sh`

Sets CalibreWeb up to run as its own hidden macOS user under launchd.

### Why

CalibreWeb faces the internet. Run as you, a flaw in it could read everything you can: ssh keys, tokens, shell secrets. As a role account with no login shell, no home folder and no keys, it reaches only its own files and the library.

### Usage

Run as yourself, never with `sudo`; it asks for your password where root is needed. Each step skips what is done, so any can be rerun. `--dry-run` prints the root commands instead of running them (and, for `daemon`, the plist and sudo rule it would install).

```bash
./setup_calibreweb_service.sh [--dry-run] user | venv | import DIR CERT KEY | library | daemon | check
```

| Step | What it does |
|------|--------------|
| `user` | Creates the user and a group of the same name (`dscl`), first free id in 450–499, shell `/usr/bin/false`, home `/var/empty`, hidden. Warns if it ended up in `staff`, whose members can read group-readable files in your home |
| `venv` | Creates the service folder and the venv (Python 3.14, else 3.12), installs `calibreweb-requirements.txt`, runs `pip check` |
| `import DIR CERT KEY` | Copies `app.db`, `.key` and `gdrive.db` from a copy of an existing config folder, and the certificate and key; then rewrites the paths in `app.db` that name the old machine: library, port, certificate, key, Calibre's binaries folder and converter, kepubify, unrar (empty if none), log files (default) |
| `library` | Access rules (ACLs) on the library for the service group and for you, on every folder and file, inherited by new ones |
| `daemon` | Installs `/Library/LaunchDaemons/<label>.plist` and `/etc/sudoers.d/calibre-web`. Does not start it |
| `check` | Shows what is in place: user, folders and owners, venv, library rule, daemon, sudo rule, loaded state, `cps` user, login page answer. No sudo |

### Layout

| Path | Owner | Holds |
|------|-------|-------|
| `$CALIBRE_WEB_SERVICE_DIR` | root, 755 | the rest |
| `venv/` | you, 755 | the Python venv. Yours, so updates need no sudo; `cps` cannot change its own code |
| `config/` | service user, 700 | `app.db`, `.key`, `gdrive.db`, `calibre-web.log`, `access.log`, `launchd.log` |
| `home/` | service user, 700 | the service user's `HOME`: CalibreWeb's and Calibre's converter settings, the cache |
| `tls/` | root, group service user, 750 | certificate and key, 640: readable by `cps`, not writable |

The LaunchDaemon sets `HOME`, `CALIBRE_DBPATH` (where CalibreWeb finds `app.db`), `CACHE_DIRECTORY` and a `PATH` with Homebrew. `KeepAlive` restarts `cps` after a crash but not after a clean exit (the admin page's Shutdown).

### The library is shared, and stays yours

The Calibre desktop app writes as you, CalibreWeb as the service user. Plain Unix permissions would leave each unable to change the other's new files, so `library` adds ACL entries for both, with `file_inherit,directory_inherit`. Every new folder and file inherits them, whoever creates it. The library must be outside your home folder (e.g. `/Users/Shared/Calibre Library`): the service user cannot enter `/Users/<you>`, which is the point.

Files copied in with `rsync` or Syncthing inherit the rules like any new file. A file moved in with `mv` from elsewhere on the same disk keeps its old rules: rerun `library` after such a move.

---

## `update_calibreweb.sh`

Keeps CalibreWeb's venv patched without guessing: the live venv only gets a pinned set that was built and checked first.

### Usage
```bash
./update_calibreweb.sh check     # read-only: pip-audit and newer versions of the live venv
./update_calibreweb.sh propose   # newest allowed set, built in a throwaway venv, written to calibreweb-requirements.txt
./update_calibreweb.sh install   # apply calibreweb-requirements.txt to the live venv
```

### The two requirement files

- `calibreweb-requirements.in`: what is wanted: `calibreweb`, plus `comicapi`, `goodreads` and `rarfile`. Not pinned. Upper limits go here when a new version conflicts (e.g. `pycountry<23` if comicapi ever stops declaring it).
- `calibreweb-requirements.txt`: every package, pinned. Written by `propose`, installed by `install` and by `setup_calibreweb_service.sh venv`. Commit each change through a PR, so the history shows what ran when.

### Why three steps

In October 2026 an eager upgrade straight into the live venv broke two optional packages (comicapi needs `pycountry<23`), and only `pip check`, read afterwards, showed it. `propose` runs `pip check` in a throwaway venv before anything reaches CalibreWeb. `install` saves a rollback list (`$LOG_DIR/calibreweb-freeze-<time>.txt`) and puts it back if pip refuses the set or `pip check` fails, then starts CalibreWeb either way, and finally checks that the login page answers 200.

`install` stops CalibreWeb with `stop_calibreweb.sh`, which also quits the Calibre desktop app.

### Advisories held back by CalibreWeb itself

`pip-audit` (through `uvx`, never installed into CalibreWeb's venv) reports what is known. Some fixes are out of reach: calibreweb 0.6.27 caps `tornado<6.6`, `PyPDF<6.11`, `cryptography<48` and `certifi<2026.5.21`, so `propose` cannot go past them. Those wait for a CalibreWeb release that raises the caps.

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
- Appropriate for an always-on Mac Mini where the user is always logged in
- Boots out any existing job before reinstalling to ensure clean state
- Uses `launchctl bootout`/`bootstrap` rather than the legacy `unload`/`load`. Recent macOS versions are unreliable about the legacy pair, often failing with a generic I/O error when nothing is actually wrong.
- Substitutes the real script path into the plist before installing it (see below)

This is a one-time registration step. Once bootstrapped, launchd rescans `LaunchAgents` on every login and reloads the job itself — you only need to run this again when reinstalling on a new machine or changing the plist.

### To uninstall
```bash
launchctl bootout gui/$(id -u)/info.fourm.calibre-backup
rm ~/Library/LaunchAgents/info.fourm.calibre-backup.plist
```

---

## `info.fourm.calibre-backup.plist`

launchd property list that schedules `calibre_nightly_backup.sh` to run at 2:00am daily.

### Key settings
- `StartCalendarInterval`: Hour 2, Minute 0
- `RunAtLoad`: false — only runs at scheduled time, not on login
- stdout/stderr redirected to `/dev/null` — the backup script writes its own timestamped logs

### The `__BACKUP_SCRIPT__` placeholder

The committed plist does not contain a real path. It ships with:

```xml
<string>__BACKUP_SCRIPT__</string>
```

which `install_calibre_backup_launchd.sh` replaces with `$SCRIPT_DIR/calibre_nightly_backup.sh` as it writes the file into `~/Library/LaunchAgents`. A plist that hardcoded `~/Code/FourM/Calibre` would install cleanly on a machine that cloned the repo somewhere else and then quietly run nothing every night at 2am.

Substitution uses bash's own `${var//pattern/replacement}` rather than `sed`, so a path containing `/` or `&` needs no escaping.

Because the placeholder is only meaningful once substituted, **do not copy the committed plist into `LaunchAgents` by hand** — run the installer.

### Installation path
```
~/Library/LaunchAgents/info.fourm.calibre-backup.plist
```

---

## `calibre_fts_search.sh`

Runs a full-text search from the command line and writes the result out in three shapes so it survives quitting Calibre.

### Usage
```bash
./calibre_fts_search.sh 'quicksilver protocol'
./calibre_fts_search.sh --exact --name marginalia 'marginalia'
./calibre_fts_search.sh --restrict 'search:tag:history' 'annotation'
./calibre_fts_search.sh --reindex 'quicksilver'
```

### What it does
1. Checks `fts_index status` and stops with instructions if indexing is off
2. Warns if the index is incomplete but still searchable
3. Optionally reindexes and waits for it to finish (`--reindex`)
4. Searches, and refuses to guess if the search was refused (see below)
5. Writes `.ids`, `.snippets.txt` and `.vl.txt` into `REVIEW_DIR`

### The three output files

| File | Contents | What it is for |
|------|----------|----------------|
| `<name>.ids` | One book id per line | Input to `calibre_ids_to_search.sh` and `calibre_tag_ids.sh` |
| `<name>.snippets.txt` | The matched passages | Reading through the result away from Calibre |
| `<name>.vl.txt` | `id:4 or id:1 or ...` | Paste into the search bar, or save as a Virtual Library |

The point of writing anything down at all: a full-text search result in the Calibre GUI lives in the `marked` flag, which is session state. `calibredb` cannot see it and it is gone the moment you quit. A 300-book result from a twenty-minute search evaporates. See [FULL_TEXT_SEARCH.md](FULL_TEXT_SEARCH.md).

### Why stderr is captured, not discarded

When the index is below `--indexing-threshold` (90% by default) `fts_search` prints **nothing on stdout**, writes `N files out of M are not yet indexed, searching is disabled` to **stderr**, and exits 1. That is the same empty-stdout-and-nonzero-exit signature as a genuine no-match, so `2>/dev/null` converts "the search was refused" into "nothing found" — a wrong answer with no error attached.

The script captures stderr to a temp file, greps it for `searching is disabled`, and stops with an error quoting Calibre's own message. It was written the wrong way first and reported "No matches." for a search that never ran; that is how the behaviour was found.

Above the threshold there is no refusal and no warning from Calibre at all — at 95% indexed it searches happily and simply does not look at the other 5%. The script prints its own WARNING in that case, since Calibre will not.

### `--reindex` and the indexing worker

Calibre indexes in a background worker started *inside* the `calibredb` process and torn down when it exits, so a short-lived CLI call only indexes a few more books before dying. Repeated runs creep forward a book or two at a time — a fresh 12-book library observed going 0 → 1 → 3 → 6 → 7 → 9 across successive invocations.

`--reindex` is the way out. It holds the process open until the index is complete. The alternative is to leave the Calibre desktop app running, since its worker is long-lived.

The invocation looks odd for two reasons:
```bash
yes reindex | calibredb ... fts_index reindex --wait-for-completion 2>&1 | ... || true
```
The confirmation prompt wants the literal word `reindex` typed at it — a plain `yes |` answers "y", which the prompt treats as "anything else" and aborts, and with no stdin at all it dies on `EOFError`. And `yes` is still writing when `calibredb` exits, so it dies of SIGPIPE and fails the pipeline under `pipefail` even on success, hence `|| true`.

Note that `reindex` **rebuilds from scratch**. It is a sledgehammer for merely finishing an incomplete index, but it is the only CLI operation that offers `--wait-for-completion`.

### Notes
- `--exact` maps to `--do-not-match-on-related-words`. Stemming is on by default, so a search for "appear" also matches "appears" and "appearing"
- `--restrict` takes `ids:1,2,3` or `search:tag:foo`. The `ids:` form works **only** here — it silently matches nothing in a normal search expression
- Snippets are a second pass, because `--include-snippets` "makes searching much slower" by Calibre's own account and is not needed to harvest ids
- Snippet markers are set to `>>>`/`<<<`. Calibre's defaults are raw ANSI colour escapes: fine on a terminal, unreadable in a file
- Over 491 matches, no `id:` expression is written — Calibre's parser cannot hold one. The `.vl.txt` file instead contains the `calibre_tag_ids.sh` command to run
- Output goes to `REVIEW_DIR`, falling back to `$LOG_DIR/reviews` if an older `config.sh` does not define it

---

## `calibre_ids_to_search.sh`

Turns a list of book ids into a search expression you can paste into the search bar or save as a Virtual Library.

### Usage
```bash
./calibre_ids_to_search.sh "$REVIEW_DIR/marginalia.ids"
./calibre_ids_to_search.sh --copy "$REVIEW_DIR/marginalia.ids"
./calibre_ids_to_search.sh --field author_sort --out expr.txt ids.txt
calibredb list -s 'tag:history' --for-machine | ./calibre_ids_to_search.sh -
```

```
1
3   ────────►   id:1 or id:3 or id:4
4
```

### Why an "or" chain and not a list

Calibre's search grammar does not accept a comma-separated list of ids:

| Expression | Result |
|------------|--------|
| `id:1 or id:3` | Works |
| `id:1,3` | `ParseException` |
| `ids:1,3` | **Silently matches nothing** |

The `ids:` failure is the dangerous one — no error, just an empty result. An explicit `or` chain between single ids is the only form that works in the search bar.

### Input shapes

Detected automatically, in this order:

1. **JSON** from `calibredb`. Note that `list --for-machine` emits `"id"` while `fts_search --output-format=json` emits `"book_id"` — the two Calibre JSON outputs disagree, and both are accepted. The key is matched exactly so `series_id` or `uuid_id` can never be mistaken for the book id
2. **Catalog CSV**. The `id` column is located by name rather than assumed to be first, with a warning if it is not column 1 (a quoted comma in an earlier column would shift `cut`)
3. **Plain list** — newline, comma or space separated, with an optional `id:` prefix tolerated so an expression can be fed back in and re-normalised

The CSV test is deliberately "header row with commas and letters in it", not "has an id column". A catalog exported *without* id would otherwise fall through to the plain branch and quietly harvest any digits it found in the titles — a wrong answer rather than an error.

### Notes
- Deliberately standalone: it needs no library, no log and no path, so it does not source `config.sh` and can be dropped into a pipe on a machine that has none
- Strips the UTF-8 BOM Calibre writes at the head of its catalog CSV, without which the first column reads as `<BOM>id` and every name test against it fails
- Refuses over 491 ids and points at `calibre_tag_ids.sh` instead; `--force` overrides
- Joins with a bash loop, not `sed`. The obvious one-liner `tr '\n' '\a' | sed 's/\a/ or /g'` silently does nothing on BSD sed, which reads `\a` in a pattern as a plain letter "a" — and with `--field author_sort` replaces every "a" in the field name as well
- `--copy` needs `pbcopy`; warns rather than failing if it is absent

---

## `calibre_tag_ids.sh`

Adds or removes one tag across a list of book ids without disturbing the other tags on those books.

### Usage
```bash
./calibre_tag_ids.sh --dry-run "$REVIEW_DIR/marginalia.ids" review-2026-08-24
./calibre_tag_ids.sh "$REVIEW_DIR/marginalia.ids" review-2026-08-24
./calibre_tag_ids.sh --remove "$REVIEW_DIR/marginalia.ids" review-2026-08-24
```

### Why this exists

`calibredb set_metadata --field 'tags:foo'` **replaces the whole tag list**. Run that against a book tagged `history, reference` and you are left with a book tagged `foo` and no way back short of a restore.

So every book is read first, the new list composed from what is already there, and only then written back — and if the read fails for any reason, that book is skipped rather than written.

The usual reason to want this is a search result too large for an `id:` expression. A tag has no 491-term ceiling, so tagging the result and building the Virtual Library on `tags:="the-tag"` is the route that always works at any size. The script prints that expression when it finishes.

### The read-modify-write guard

`show_metadata` omits the `Tags` line entirely when a book has no tags, so an absent line is indistinguishable from a truncated read on its own — and "no tags" followed by a write is exactly how a tag list gets wiped. Every book has a `Title`, so the presence of `^Title  *:` is used as proof the read actually returned metadata before "no tags" is believed. Anything less and the book is counted as failed and left alone.

### Notes
- `--dry-run` prints `id N: [old] -> [new]` for every book and writes nothing
- Prompts for confirmation otherwise; `--yes` skips it for use inside other scripts
- Tag matching is case-insensitive, but on add the spelling already in the library wins rather than the one on the command line
- Rejects a tag containing a comma — Calibre uses it as the separator, so it would read back as two tags and quietly corrupt the list on the next run
- Books already carrying the tag (or, with `--remove`, not carrying it) are counted as unchanged, not rewritten
- Exits 1 if any book failed, so a caller can tell
- Removing the tag in the GUI instead: select the books, `Edit metadata` in bulk, and use the **&Remove tags:** field

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
source ./config.sh
sqlite3 "$CALIBRE_WEB_CONFIG/app.db" "SELECT config_certfile, config_keyfile FROM settings;"
```
Compare what comes back against `CERT_FILE` and `KEY_FILE` in `config.sh` — a mismatch between the two is the usual cause. Fix via the CalibreWeb admin UI at `$CALIBRE_HOST` or by re-running `setup_calibreweb.sh`.

### `tmux: command not found` from launchd
launchd has a minimal PATH that doesn't include Homebrew. The start/stop scripts export the full path themselves:
```bash
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
```
If you see this error, check that line is still at the top of `start_calibreweb.sh` and `stop_calibreweb.sh`. (Re-running `setup_calibreweb.sh` will *not* fix it — setup no longer generates these scripts, it only chmods the repo copies.)

### CalibreWeb doesn't start in tmux, session is there but empty
Almost always something in an rc file prompting for input and eating the launch command's first keystrokes. oh-my-zsh's update prompt is the known culprit; `zstyle ':omz:update' mode auto` in `Dotfiles.Mac` disables it. `start_calibreweb.sh` also passes `cps` directly to `tmux new-session` instead of using `send-keys`, so no interactive shell is involved on that path any more — but a `send-keys` in your own tooling will still hit this.

### iCloud backup interrupted (`Interrupted system call`)
iCloud Drive can briefly pause file access while syncing to cloud, causing rclone to fail mid-operation. The nightly backup records this as a failure and carries on with the remaining steps, so you will find it named in the `_FAILED.log`. Rerun the iCloud step manually:
```bash
source ./config.sh
rclone sync "$LIBRARY/" "$ICLOUD_BACKUP/current/" \
    --backup-dir "$ICLOUD_BACKUP/versions/daily.$(date +%Y%m%d_%H%M%S)" \
    --exclude='.DS_Store' \
    --exclude='.stfolder/**' \
    -v
```
This is safe to rerun — rclone will resume from where it left off and only transfer what is missing.

### Full-text search returns nothing when you know the passage is there

Three separate causes, in order of likelihood:

1. **The index is incomplete.** Check first, always:
   ```bash
   source ./config.sh
   "$CALIBREDB" --with-library "$LIBRARY" fts_index status
   ```
   Below 90% the search is refused outright; above it, the unindexed books are simply skipped with no warning at all. `calibre_fts_search.sh --reindex` fixes both.
2. **The search was refused and something threw the message away.** The refusal goes to **stderr**, with nothing on stdout and exit 1 — identical to a real no-match if stderr is discarded.
3. **You used `ids:` in a search expression.** It parses and matches nothing. Use `id:1 or id:2`, or `--restrict-to='ids:1,2'` where the other parser applies.

### `Integration status: True` in the middle of the output

Third-party metadata plugin chatter, printed on **stdout** by every Calibre CLI tool, so `2>/dev/null` will not remove it and it breaks anything parsing JSON. Filter it:
```bash
calibredb ... | grep -v '^Integration status:'
```
Plugin `SyntaxWarning`s are different — those *are* on stderr.

### `calibredb catalog` produced no file and reported success

The output filename must come before **all** options, including `--with-library`. Put it after and Calibre prints "Must specify the catalog output filename before any options" — and **exits 0**, so a script checking the exit status sees a success.
```bash
# Wrong — silently does nothing, exit 0
calibredb --with-library "$LIBRARY" catalog out.csv
# Right
calibredb catalog out.csv --with-library "$LIBRARY"
```

### A search expression fails with `RecursionError`

Calibre's search parser recurses once per `or`. 491 terms is the last size that parses; 492 raises `RecursionError` in `calibre/utils/search_query_parser.py`. There is no way to raise the ceiling — tag the books with `calibre_tag_ids.sh` and search `tags:="the-tag"` instead.

### A Virtual Library disappeared when Calibre restarted

You probably used `marked:`. The `marked` flag is GUI session state — `calibredb` cannot see it and it does not survive quitting. Virtual Libraries built on `id:`, `tags:` or any real metadata field are stored in the library and do survive. See [FULL_TEXT_SEARCH.md](FULL_TEXT_SEARCH.md).
