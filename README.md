# Calibre Library Management Scripts

A collection of bash scripts for managing, backing up, and restoring a large [Calibre](https://calibre-ebook.com) ebook library on macOS, with automated nightly backups and a self-hosted [CalibreWeb](https://github.com/janeczku/calibre-web) instance.

These scripts were written under the FourM identity namespace and are designed to run on a headless Mac Mini serving as a home server.

---

## Background

This toolset was born out of a library corruption event that threatened 900+ hours of curation work across 8,500+ books. The recovery process exposed several weaknesses in Calibre's built-in backup/restore mechanism and led to building a more robust, transparent backup architecture based on `rsync` with hard-link deduplication.

See [SCRIPTS.md](SCRIPTS.md) for detailed documentation of each script including design decisions and known issues encountered during development.

---

## Architecture

```
Live library: ~/Calibre Library (internal disk)
     │
     ├── Nightly rsync snapshots ──► /Volumes/Extreme/CalibreBackups/
     │   7 dailies, 4 weeklies, 2 monthlies, 1 yearly
     │   Hard-link deduplication via --link-dest
     │   ~1GB per day incremental on a 190GB library
     │
     ├── Nightly rsync snapshots ──► ~/Documents/Backups/Calibre/ (iCloud)
     │   Same rotation policy
     │   Syncs to iCloud automatically
     │
     └── Syncthing live mirror ────► local backup machine internal disk
         Continuous, best-effort, same-day recovery
              │
              └── Sync.com client ──► Cloud storage
```

**Recovery options in order of speed:**
1. Local backup machine (Syncthing) — same-day work preserved
2. Last nightly on external drive — known good, previous night
3. iCloud snapshots — offsite, same rotation
4. Sync.com cloud — ultimate offsite fallback

---

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `config.sh.example` | Template for local machine configuration (copy to `config.sh`) |
| `calibre_nightly_backup.sh` | Automated nightly backup with rotation |
| `calibre_check_integrity.sh` | Scan library for corrupt PDF/EPUB files |
| `calibre_sync.sh` | Copy missing books between two library folders |
| `calibre_update_metadata.sh` | Update book metadata from OPF files |
| `calibre_restore_preview.sh` | Preview a backup snapshot before restoring |
| `calibre_restore_finalize.sh` | Finalize a restore after preview approval |
| `setup_calibreweb.sh` | Install or reinstall CalibreWeb |
| `start_calibreweb.sh` | Start CalibreWeb in a tmux session |
| `stop_calibreweb.sh` | Stop CalibreWeb, Calibre app and worker processes |
| `install_calibre_backup_launchd.sh` | Install nightly backup as a launchd agent |
| `info.fourm.calibre-backup.plist` | launchd plist for 2am nightly schedule |

---

## Requirements

- macOS (tested on Intel Mac Mini running macOS 15)
- bash 3.2+ (macOS default — all scripts are bash 3.2 compatible)
- Python 3.12 (for CalibreWeb)
- `poppler` for PDF integrity checking: `brew install poppler`
- `tmux` for CalibreWeb session management: `brew install tmux`
- `rsync` (included with macOS)
- Calibre desktop app installed at `/Applications/calibre.app`

---

## Quick Start

### First time setup

```bash
cp config.sh.example config.sh
# Edit config.sh with your paths and settings
nano config.sh
```

### Setting up CalibreWeb

```bash
chmod +x setup_calibreweb.sh
./setup_calibreweb.sh
```

Then start it:

```bash
./start_calibreweb.sh
# Attach to session: tmux attach -t calibreweb
```

### Setting up nightly backups

Edit the config section at the top of `calibre_nightly_backup.sh` to set your paths, then install the launchd agent:

```bash
chmod +x install_calibre_backup_launchd.sh
./install_calibre_backup_launchd.sh
```

Verify it loaded:

```bash
launchctl list | grep calibre
# Should show: -  0  info.fourm.calibre-backup
```

### Running a manual backup

```bash
./calibre_nightly_backup.sh
```

Logs are written to `~/Code/FourM/Logs/calibre_backup_YYYYMMDD_HHMMSS.log`.

---

## macOS Permissions

The backup script requires **Full Disk Access** for `/usr/bin/rsync` and `/bin/bash` to write to external drives when run via launchd:

**System Settings → Privacy & Security → Full Disk Access → Add `/usr/bin/rsync` and `/bin/bash`**

Without this, launchd jobs will fail with `Operation not permitted` on external volumes.

---

## Key Design Decisions

**Hard-link deduplication** — `rsync --link-dest` creates snapshots where unchanged files are hard links to the previous snapshot rather than copies. A 190GB library with daily changes costs ~1GB per additional snapshot rather than 190GB. Deleting an old snapshot only frees space for files that exist exclusively in that snapshot.

**No compression** — snapshots are raw files in Calibre's native folder structure. Any file can be dragged out of a snapshot in Finder or restored with a simple `cp -R`. No special tools needed.

**Bash 3.2 compatibility** — macOS ships with bash 3.2 (due to GPL licensing). All scripts avoid bash 4+ features: no `declare -A`, no `${var,,}` lowercase, no `mapfile`. Associative arrays are replaced with sorted temp files and `grep`.

**Always exit 0** — the integrity check script always exits 0 so corrupt files are logged but never abort the backup. The backup script itself handles external drive absence gracefully rather than dying under `set -euo pipefail`.

---

## Configuration

All machine-specific values live in `config.sh` which is gitignored and never committed. Copy `config.sh.example` to `config.sh` and fill in your values:

```bash
cp config.sh.example config.sh
```

Key values to set:

```bash
HOST_BACKUP="/Volumes/YOUR_EXTERNAL_DRIVE/CalibreBackups"
ICLOUD_BACKUP="$HOME/Documents/Backups/Calibre"
CALIBRE_HOST="https://your-calibre-domain:YOUR_PORT"
PORT=YOUR_PORT
CERT_FILE="$HOME/path/to/your_cert.pem"
KEY_FILE="$HOME/path/to/your_key.key"
```

Paths that use `$HOME` (library location, venv, scripts dir, log dir) are derived automatically and don't need to be in `config.sh`.

---

## License

MIT
