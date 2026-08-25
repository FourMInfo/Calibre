# Full-Text Search and Saving a Selection

How to search the *contents* of every book in a Calibre library from the command
line, and — the harder half — how to keep the result once you have it.

Everything here was worked out against calibre 8.x on macOS and verified against
a live library. Where a command has a trap in it, the trap is written down next
to the command rather than in a footnote.

---

## The problem this solves

Calibre's full-text search works well in the GUI. What it does **not** do is
give you the result in a form that survives quitting the application.

A GUI full-text search leaves its results in the **marked** flag — an in-memory
session flag. It is invisible to `calibredb`, it is not stored in
`metadata.db`, and it is gone the moment calibre exits. So a search that took
twenty minutes to run across 8,500 books, and produced 300 books you intended to
work through, evaporates when you close the app.

Anything you want to still have tomorrow has to be **written down** — as a list
of ids, as a search expression, or as a tag. This document covers all the
routes, with the tradeoffs, and the three scripts in this repo that automate
them.

---

## Before you start — source `config.sh`

Every command in this document is written against `config.sh`, so source it
first:

```bash
cd ~/Code/FourM/Calibre
source config.sh
```

Two things come from it and neither has a sane fallback:

**`$CALIBREDB`** — the path to the `calibredb` binary. **There is no `calibredb`
on `PATH`.** Calibre's command-line tools live inside the application bundle, at
`/Applications/calibre.app/Contents/MacOS/calibredb`, and installing calibre
does not symlink them anywhere. Typing a bare `calibredb` gets you
`command not found`, which is the first thing that happens if you skip this
step.

**`$LIBRARY`** — the library to work on. Every example passes it explicitly with
`--with-library`, because otherwise `calibredb` uses whichever library it last
used — not something to leave to chance on a command that writes.

The three scripts in this repo source `config.sh` themselves and check both
values before doing anything, so `./calibre_fts_search.sh` works from a cold
shell. It is only the hand-typed commands below that need you to have sourced
it.

`config.sh` is gitignored. If you do not have one yet, copy `config.sh.example`
and fill in your own paths.

---

## Quick start

```bash
# Search, and write the result out in three usable shapes
./calibre_fts_search.sh 'quicksilver protocol'

# → REVIEW_DIR/fts_20260824_143210.ids           one book id per line
# → REVIEW_DIR/fts_20260824_143210.snippets.txt  the matched passages, to read
# → REVIEW_DIR/fts_20260824_143210.vl.txt        "id:4 or id:17 or ..." expression
```

Then either paste the `.vl.txt` expression into calibre's search bar and save it
as a Virtual Library, or — for a result too large for an expression — tag the
books:

```bash
./calibre_tag_ids.sh "$REVIEW_DIR/fts_20260824_143210.ids" review-20260824
# then in calibre, search:  tags:="review-20260824"
```

---

# Part 1 — The index

Full-text search does not read your books at search time. It searches an index
that calibre builds ahead of time and stores in the library folder. An
incomplete index fails in one of two ways depending on how incomplete it is,
and **neither of them looks like an error on stdout**:

- **Badly incomplete** (below `--indexing-threshold`, 90% by default) — the
  search refuses to run at all. Details below.
- **Slightly incomplete** (say 95% indexed) — the search runs perfectly
  happily and simply does not look at the missing 5%. A passage in an
  unindexed book reads as "not in your library".

Which is why the first thing to do is always check the index.

## Check the index first, always

```bash
"$CALIBREDB" --with-library "$LIBRARY" fts_index status
```

```
FTS Indexing is enabled
8231 of 8542 books files indexed
```

There are four possible states:

| Output | Meaning |
|--------|---------|
| `FTS Indexing is disabled` | Never turned on. Searches will refuse to run. |
| `N of M books files indexed`, N < 90% of M | Searches are refused — and the refusal goes to stderr. |
| `N of M books files indexed`, N between 90% and M | Searches run but silently under-report. |
| `N of N books files indexed` | Complete. Results are trustworthy. |

`fts_index` **requires** an action — bare `calibredb fts_index` is an error. The
actions are `enable`, `disable`, `status` and `reindex`.

## Enabling it

```bash
"$CALIBREDB" --with-library "$LIBRARY" fts_index enable
```

This starts indexing in the background. On a large library it is a long job —
hours, not minutes, because every book has to be converted to text.

## How indexing actually progresses — and why it seems stuck

Indexing is done by a worker process that calibre starts **inside** the
`calibredb` process and tears down when that process exits.

A command-line `calibredb` invocation lives for a second or two. So each call
indexes one or two more books and then kills its own worker. Run
`fts_index status` in a loop and you will watch the count creep forward a book
at a time and conclude, reasonably but wrongly, that indexing is broken.

Two ways to actually finish it:

**1. Leave the calibre GUI open.** The desktop app is a long-lived process, so
its worker runs continuously. This is the path of least effort for a first index
of a big library: open calibre, leave it running, come back later.

**2. Hold a CLI process open with `--wait-for-completion`.**

```bash
yes reindex | "$CALIBREDB" --with-library "$LIBRARY" \
    fts_index reindex --wait-for-completion
```

That `yes reindex` is not decoration. `reindex` asks for confirmation, and:

- **`yes |`** pipes the word `y`, which the prompt treats as "anything other
  than reindex" and **aborts**.
- **No stdin at all** (e.g. under launchd, or `< /dev/null`) dies with an
  `EOFError`.
- **`yes reindex`** types the literal word it is asking for, which is the only
  thing that works unattended.

One more wrinkle: when `calibredb` exits, `yes` is still writing and dies of
`SIGPIPE`. Under `set -o pipefail` that fails the whole pipeline even on a
completely successful run, so in a script append `|| true`:

```bash
yes reindex | "$CALIBREDB" --with-library "$LIBRARY" \
    fts_index reindex --wait-for-completion || true
```

`calibre_fts_search.sh --reindex` does exactly this.

Note that `reindex` **rebuilds from scratch**. It is the fix for a corrupt or
stale index, and it is a sledgehammer for merely finishing an incomplete one —
but on the CLI it is the only thing that offers `--wait-for-completion`, so it
is what you use.

## The 90% threshold

`fts_search` refuses to run until 90% of the library is indexed. When it
refuses, it does all three of these at once:

- prints **nothing at all on stdout**
- writes `N files out of M are not yet indexed, searching is disabled` to
  **stderr**
- exits **1**

That combination is the trap. A script that redirects stderr away —
`fts_search 'query' 2>/dev/null` — sees an empty stdout and a nonzero exit,
which is *exactly* what a genuine no-match looks like. It will report "nothing
found" for a search that was never run. Capture stderr and look for
`searching is disabled` before believing an empty result.

(`calibre_fts_search.sh` does this, and stops with an error quoting calibre's
own message. It was written the wrong way first, which is how this was found.)

Above the threshold there is no refusal and no warning at all: at 95% indexed
calibre searches quite happily and simply does not look at the remaining 5%.
`calibre_fts_search.sh` prints its own WARNING in that case, since calibre
will not.

```bash
"$CALIBREDB" --with-library "$LIBRARY" fts_search --indexing-threshold=50 'query'
```

Lowering the threshold lets you search a half-built index. Do this only when you
know what you are doing: a hit is still a real hit, but the absence of a hit
means nothing at all. `--indexing-threshold=0` searches whatever exists.

Raising it above 100 does **not** work as a way to force the refusal for
testing — a fully indexed library still returns results at
`--indexing-threshold=101`. Reproducing the refusal needs a genuinely
under-indexed library.

---

# Part 2 — Searching

```bash
"$CALIBREDB" --with-library "$LIBRARY" fts_search 'quicksilver'
```

```
delta by Unknown
Book id: 4 Formats: TXT
────────────────────────────────────────────────────────────────────────
alpha by Unknown
Book id: 1 Formats: TXT
```

## Every option, and what it is actually for

| Option | Effect |
|--------|--------|
| `--include-snippets` | Show the surrounding text of each match. Calibre's own help warns it "makes searching much slower" — so run the fast pass first to see how many hits you have, and only ask for snippets when you mean to read them. |
| `--match-start-marker=` `--match-end-marker=` | What wraps the matched word inside a snippet. **The default is a raw ANSI colour escape** (`\e[31m`…`\e[m`) — fine in a terminal, garbage in a file. Set both to something plain (`'>>>'` / `'<<<'`) whenever you are redirecting to a file. |
| `--do-not-match-on-related-words` | Turn **off** stemming. See below. |
| `--restrict-to=` | Search a subset. Takes `ids:1,2,3` or `search:tag:foo`. See below. |
| `--output-format=` | `text` (default) or `json`. |
| `--indexing-threshold=` | Percentage of the library that must be indexed before searching is allowed. Default 90. |

## Stemming is on by default

Searching for `appear` also matches *appears*, *appearing*, *appeared*. This is
usually what you want and occasionally very much not.

```bash
# 2 books — includes "appears"
"$CALIBREDB" --with-library "$LIBRARY" fts_search 'appear'

# 1 book — the literal word only
"$CALIBREDB" --with-library "$LIBRARY" fts_search --do-not-match-on-related-words 'appear'
```

`calibre_fts_search.sh --exact` is this flag.

## Restricting the search

`--restrict-to` takes two forms:

```bash
# by id
"$CALIBREDB" --with-library "$LIBRARY" fts_search --restrict-to='ids:1,2,3' 'query'

# by metadata search
"$CALIBREDB" --with-library "$LIBRARY" fts_search --restrict-to='search:tag:history' 'query'
```

**The `ids:1,2,3` form works here and nowhere else.** In a normal calibre search
expression it silently matches nothing (see [Comma-separated ids do not
work](#comma-separated-ids-do-not-work-in-a-search-expression) below). It is a
`--restrict-to`-only convenience.

This is the efficient way to search *within* a previous result: keep the `.ids`
file, and feed it back in.

```bash
./calibre_fts_search.sh --restrict "ids:$(tr '\n' ',' < old.ids | sed 's/,$//')" 'narrower query'
```

## JSON output

```bash
"$CALIBREDB" --with-library "$LIBRARY" fts_search --output-format=json 'quicksilver'
```

```json
[ { "authors": ["Unknown"], "book_id": 4, "format": "TXT", "title": "delta" } ]
```

The key is **`book_id`**, not `id`. `calibredb list --for-machine` uses `id`.
The two calibre JSON outputs disagree with each other; anything parsing both
has to accept both. (`calibre_ids_to_search.sh` does.)

## Exit codes

`fts_search` **exits nonzero when nothing matches.** That is not an error
condition, but under `set -e` it will kill your script. Guard it:

```bash
out="$("$CALIBREDB" --with-library "$LIBRARY" fts_search 'query' || true)"
```

---

# Part 3 — Keeping the result

This is the part that matters. Six routes, in ascending order of durability.

| Route | Survives quitting calibre? | Size limit | Effort | Modifies library? |
|-------|---------------------------|-----------|--------|-------------------|
| `marked:true` (GUI search) | ❌ No | none | none | no |
| Snippets text file | ✅ Yes (as prose) | none | trivial | no |
| `.ids` file | ✅ Yes | none | trivial | no |
| CSV catalog | ✅ Yes | none | small | no |
| `id:N or id:M …` expression + Virtual Library | ✅ Yes | **491 terms** | small | no |
| Tag + `tags:="name"` Virtual Library | ✅ Yes | none | small | **yes** |

## Route 1 — `marked:` (the trap)

After a GUI full-text search, calibre marks the matching books and you can
narrow to them with:

```
marked:true
```

It works, it is instant, and it is **session state only**. `calibredb` cannot
see it, it is not in `metadata.db`, and quitting calibre destroys it. Fine for
the next five minutes. Useless tomorrow.

Everything below exists because of this.

## Route 2 — the snippets file

Not a selection, but often the actual goal: the matched passages themselves, to
read through.

```bash
"$CALIBREDB" --with-library "$LIBRARY" fts_search --include-snippets \
    --match-start-marker='>>>' --match-end-marker='<<<' \
    'quicksilver' > "$REVIEW_DIR/quicksilver.txt"
```

Set the markers, or the file is full of ANSI escapes.

## Route 3 — the `.ids` file

The lowest-common-denominator format and the input to everything else:

```
1
2
4
```

```bash
"$CALIBREDB" --with-library "$LIBRARY" fts_search 'query' \
    | grep -o 'Book id: [0-9]*' | sed 's/Book id: //' | sort -n -u > result.ids
```

`calibre_fts_search.sh` writes this automatically. Note `grep -o` also exits 1
on no match, so under `pipefail` it needs `|| true`.

## Route 4 — a CSV catalog

Richer than a bare id list: titles, authors, tags, whatever columns you ask for.
Good for a record you will read as a human, or hand to a spreadsheet.

```bash
"$CALIBREDB" catalog "$REVIEW_DIR/result.csv" \
    --fields id,title,authors,tags \
    --search 'tag:history' \
    --with-library "$LIBRARY"
```

Or, straight from a saved id list:

```bash
"$CALIBREDB" catalog "$REVIEW_DIR/result.csv" \
    --fields id,title,authors,tags \
    -i "$(tr '\n' ',' < result.ids | sed 's/,$//')" \
    --with-library "$LIBRARY"
```

Two traps, both nasty:

**The output filename must come before every option — including the global
`--with-library`.** Get the order wrong and calibre prints

```
Must specify the catalog output filename before any options
```

**and exits 0**, so a script checking `$?` sails straight past having produced
no file at all.

**The CSV has a UTF-8 byte-order mark.** The first column header is not `id` but
`<BOM>id`, so any name comparison against it fails. Strip it before parsing:

```bash
raw="${raw#$'\xef\xbb\xbf'}"
```

Formats other than CSV are available by extension — `.csv`, `.xml`, `.epub`,
`.mobi`, `.azw3`. The ebook formats generate a browsable catalog *as a book*,
which is a different tool for a different job. `--help` after the filename shows
the per-format options, since they differ.

## Route 5 — an `id:` expression and a Virtual Library

This is the good one for results up to a few hundred books, because it changes
nothing in your library.

```
id:1 or id:2 or id:4
```

Paste that into calibre's search bar and it selects exactly those books. Save it
as a Virtual Library — **Virtual Library → Create Virtual Library**, paste, name
it — and it becomes a permanent named view, because a Virtual Library is a
stored search expression held in the library itself. It survives quitting.

```bash
./calibre_ids_to_search.sh result.ids           # prints the expression
./calibre_ids_to_search.sh --copy result.ids    # ...and puts it on the clipboard
```

### The 491-term ceiling

Calibre's search parser recurses once per `or` term, and dies past a fixed
depth:

- **491 terms — works.**
- **492 terms — `RecursionError`**, raised in
  `calibre/utils/search_query_parser.py`.

This is a hard wall, not a slowdown. A 600-book search result simply has no
usable `id:` expression. Both `calibre_fts_search.sh` and
`calibre_ids_to_search.sh` know the limit, refuse to emit an oversized
expression, and point you at the tag route instead.

### Comma-separated ids do not work in a search expression

Three ways to try it, two of which fail, one of which fails **silently**:

| Expression | Result |
|------------|--------|
| `id:1 or id:3` | ✅ works |
| `id:1,3` | ❌ `ParseException` — at least it tells you |
| `ids:1,3` | ⚠️ **matches nothing, no error** |

`ids:` is not a search field. Calibre parses it as a field it does not know and
returns an empty set. The only place `ids:1,2,3` is meaningful is
`--restrict-to`, which is a different parser entirely.

## Route 6 — tag the books

The route with no ceiling, and the only one that works for large results. It is
also the only one that **writes to your library**, so it is last.

```bash
./calibre_tag_ids.sh --dry-run result.ids review-20260824   # look first
./calibre_tag_ids.sh result.ids review-20260824             # then do it
```

Then in calibre, as a search or a Virtual Library:

```
tags:="review-20260824"
```

The `=` means exact match. Without it, `tags:"review-2026"` would also pick up
`review-20260901`, `review-20260815` and anything else containing that string.

### Why not just use `calibredb set_metadata`

Because this **destroys your existing tags**:

```bash
# DO NOT DO THIS on a book that already has tags
"$CALIBREDB" --with-library "$LIBRARY" set_metadata 42 --field 'tags:review-20260824'
```

`--field tags:X` **replaces the entire tag list**. Run it against a book tagged
`history, reference, to read` and you are left with a book tagged
`review-20260824` and no way back short of a restore. Across 300 books that is a
curation-destroying event, and it is completely silent.

The safe pattern is read-modify-write, per book:

1. `show_metadata` the book
2. parse its current tags
3. append the new one
4. write the whole list back

and — critically — **if the read fails, skip the book rather than writing.** A
failed read looks exactly like "this book has no tags", and writing on that
assumption is precisely how a tag list gets wiped.

`calibre_tag_ids.sh` does all of this. The relevant `show_metadata` semantics,
verified:

- exits **1** for a book id that does not exist
- **omits the `Tags` line entirely** when a book has no tags — so an absent line
  is not by itself evidence of anything
- always prints a `Title` line — which is therefore usable as proof that the
  read returned real metadata before you believe "no tags"
- multi-tag format is `Tags                : history, reference, to read`

### Removing the tag afterwards

```bash
./calibre_tag_ids.sh --remove result.ids review-20260824
```

Or in the GUI: select the books, **Edit metadata in bulk** (`Ctrl/Cmd+E`), and
put the tag in the **"&Remove tags:"** field. Leave the *add* field empty. This
is the one bulk-edit field that does not replace the list.

---

# Part 4 — Recommended workflow

For a result **under ~490 books**, keep the library clean:

```bash
./calibre_fts_search.sh --name marginalia 'marginalia'
cat "$REVIEW_DIR/marginalia.vl.txt"        # id:4 or id:17 or ...
```

Paste into calibre → **Virtual Library → Create**. Nothing in the library
changes; the VL is a stored expression you can delete any time.

For a result **over 490 books**, or one you want to work through over weeks:

```bash
./calibre_fts_search.sh --name marginalia 'marginalia'
./calibre_tag_ids.sh --dry-run "$REVIEW_DIR/marginalia.ids" review-20260824
./calibre_tag_ids.sh "$REVIEW_DIR/marginalia.ids" review-20260824
```

Then a Virtual Library on `tags:="review-20260824"`. When you are done:

```bash
./calibre_tag_ids.sh --remove "$REVIEW_DIR/marginalia.ids" review-20260824
```

Keep the `.ids` file either way. It is the thing that lets you re-tag, re-narrow
with `--restrict`, or rebuild the expression months later.

---

# Part 5 — Gotchas reference

Everything that cost time, in one place.

### `Integration status: True` appears in the output

Calibre CLI tools print plugin startup chatter **on stdout**, mixed in with real
output. On an install with the Comicvine metadata plugin it emits
`Integration status: True` — and for `list --for-machine` it is glued to the
front of the JSON with no newline, so the JSON will not parse.

```bash
"$CALIBREDB" ... | grep -v '^Integration status:'
```

Plugin `SyntaxWarning`s go to stderr and can be dropped with `2>/dev/null`, but
this one cannot — it is on stdout.

### A refused search is indistinguishable from a no-match if you drop stderr

The most expensive mistake in this document. Below the threshold `fts_search`
prints **nothing on stdout**, writes
`N files out of M are not yet indexed, searching is disabled` to **stderr**,
and exits 1 — the same empty-stdout-plus-nonzero-exit signature as a real
no-match. `2>/dev/null` turns "the search was refused" into "nothing found".

Capture stderr and grep it, and **always check `fts_index status` before
believing a zero-result search.**

### `fts_search` exits nonzero on no matches

Not an error. Guard with `|| true` under `set -e`.

### `grep -o` exits 1 on no match

Kills a `set -euo pipefail` script mid-pipeline — and if you were redirecting to
a file, the redirect has *already created it*, so you are left with a stale
empty file and no error. Append `|| true`.

### `yes` dies of SIGPIPE

When its consumer exits first. Fails the pipeline under `pipefail` even on
success. Append `|| true`.

### BSD `sed` reads `\a` in a pattern as the letter "a"

The tempting one-liner for joining lines —

```bash
tr '\n' '\a' | sed 's/\a/ or /g'          # WRONG on macOS
```

— inserts no separator at all on macOS, and if your replacement text contains an
"a" it corrupts that too. This produces a *silently wrong* string, not an error.
Join in a bash loop instead.

(BSD sed *does* support the `I` case-insensitive flag, contrary to a common
assumption — but `[iI][dD]` is still the safer form if the script might travel.)

### `calibredb catalog` exits 0 when it does nothing

If the filename is not first. Check for the output file's existence, not `$?`.

### Calibre's catalog CSV has a BOM

First header reads as `<BOM>id`. Strip it.

### `set_metadata --field 'tags:X'` replaces all tags

The data-loss hazard. Read-modify-write, and abort on a failed read.

### bash 3.2

macOS ships bash 3.2 for licensing reasons. No `declare -A`, no `${var,,}`, no
`mapfile`. All scripts here are 3.2-compatible.

---

# The scripts

| Script | What it does |
|--------|--------------|
| `calibre_fts_search.sh` | Runs the search; writes `.ids`, `.snippets.txt` and `.vl.txt` |
| `calibre_ids_to_search.sh` | Turns ids (plain / JSON / CSV) into an `id:N or …` expression |
| `calibre_tag_ids.sh` | Adds or removes one tag across a list of ids, non-destructively |

See [SCRIPTS.md](SCRIPTS.md) for full documentation of each. All three accept
`--help`.

They chain:

```bash
./calibre_fts_search.sh --name review 'query'
./calibre_tag_ids.sh "$REVIEW_DIR/review.ids" review-20260824
```

and `calibre_ids_to_search.sh` reads stdin, so it drops into any pipe:

```bash
"$CALIBREDB" --with-library "$LIBRARY" list -s 'tag:history' --for-machine \
    | grep -v '^Integration status:' \
    | ./calibre_ids_to_search.sh --copy -
```

---

## Where the output goes

`calibre_fts_search.sh` writes to `REVIEW_DIR` from `config.sh`. If your
`config.sh` predates that key it falls back to `$LOG_DIR/reviews` and tells you
where the files went — these are working files you come back to, not logs, so
they are never rotated away.

```bash
REVIEW_DIR="$HOME/Code/FourM/Reviews"
```

Keep it outside the repo. `.snippets.txt` holds passages copied out of your
books and this repo is public, and since you choose the path, no committed
`.gitignore` can know what to exclude.
