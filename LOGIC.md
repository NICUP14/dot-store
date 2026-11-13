# dotsx — Logic Walkthrough

A complete walkthrough of [`dotsx.sh`](dotsx.sh) — the data model, the shared
helpers, then each command's exact flow and every check it performs.

## The data model

Four globals set the whole layout:

- `DOTSX_DIR` = `~/.dotsx/` — the top-level directory.
- `STORE` = `~/.dotsx/store/` — the canonical copies, in a tree that mirrors
  `/` (your git-able repo of tracked files, and *only* those).
- `BACKUPS` = `~/.dotsx/backups/` — prior versions, saved automatically before
  anything is overwritten.
- `DB` = `~/.dotsx/index.db` — the flat-file index (kept beside the store, not
  inside it, so the store stays a clean repo of just your files).

A fifth, `DOTSX_REAL`, is the physical location of `DOTSX_DIR` in db form
(empty before `init`); `valid_target` uses it to keep the store from tracking
itself.

Each DB line is `field_type:track_type:mode:path`:

- **field_type** — `f` (file) or `d` (directory)
- **track_type** — `l` (deployed as a symlink) or `c` (deployed as a plain copy)
- **mode** — octal permission bits to enforce (e.g. `600`); may be empty
- **path** — relative to `/`, no leading slash. The live file is `/<path>`
  and the store copy is `$STORE/<path>`.

So `f:l:600:home/me/.ssh/config` means "a file, symlinked, kept at mode 600,
living at `~/.dotsx/store/home/me/.ssh/config` ↔ `/home/me/.ssh/config`", and
`f:c:644:etc/systemd/system/foo.service` is a plain copy at
`/etc/systemd/system/foo.service`. Home files and system files are the same
kind of entry; nothing in the code treats `$HOME` specially beyond locating
`~/.dotsx`. The `track_type` field lets `sync`/`repair` know *how* to deploy
each entry; the `mode` field lets them *enforce* permissions (see below).
**`mode` is placed before `path`** so a path that itself contains a `:` still
parses correctly (path = everything after the third colon).

Why root-relative rather than absolute? Because the store path is just
`$STORE/<path>` and the live path is just `/<path>`, with no special-casing.
And `valid_target` can keep rejecting any absolute path found in the index
outright, which is one fewer way for a hand-edited line to go wrong.

Why a mode field when `cp -p` already preserves permissions on copy? Because the
store is meant to be a git repo, and git only records the executable bit — a
`git clone`/`checkout` normalizes a `600` key to `644`. Recording the intended
mode lets `sync`/`repair` restore it. For symlink (`l`) entries the mode is
enforced on the **store file**, which is what tools like `ssh` actually check
when following the symlink. Ownership is *not* recorded: `cp -p` carries the
owner across only where the running user is allowed to (i.e. as root).

Three terms used throughout: **src** = the store copy (`$STORE/path`),
**tgt**/**live_tgt** = the live location (`/path`), **dst** = where a new item
goes in the store.

**Copies are one-way (store → live).** Editing a `c`-tracked file in place
does not update the store; you re-run `copy` to push it. A stray `sync` would
overwrite the edit with the stored version — but because every overwrite is
backed up first (see `backup_path`), the edit is always recoverable from
`backups/`.

---

## Shared helpers

**`err`** / **`warn`** — one-line `printf` wrappers that prefix `Error: ` /
`Warning: ` and write to stderr. Every diagnostic in the script goes through one
of them, so normal output on stdout stays parseable.

**`link_target`** — `readlink` to read a symlink's destination. Used to decide
whether an existing symlink already points where it should.

**`file_mode`** — prints a path's octal permission bits (`stat -c '%a'`, with a
BSD `stat -f '%Lp'` fallback). Empty on failure, so the whole feature degrades
gracefully to "no mode tracking" if `stat` is unavailable.

**`sync_mode`** — enforces a recorded mode on a path: returns 0 if nothing's
needed (no mode, missing path, or already correct), 1 if it `chmod`-ed a change,
2 if the `chmod` failed. The 0/1/2 split lets `sync`/`repair` count a fixed mode
as an update and a failed `chmod` as an error.

**`backup_path`** — given a path, a relpath, and a kind tag (`store`|`live`),
copies the path's current content to `backups/<relpath>.<kind>.<timestamp>`
before the caller overwrites it. No-op if there's nothing there; returns nonzero
only if a backup was attempted and failed (so callers can refuse to proceed and
avoid a destructive overwrite they couldn't back up). Called before the store
copy is replaced in `link`/`copy`, and inside `deploy_copy` before a live copy
is overwritten. The timestamp has one-second resolution, so two overwrites of
the same path within the same second would otherwise collide and the later
backup would clobber the earlier one — the opposite of the guarantee. It never
overwrites an existing backup: if the timestamped name is taken it keeps the
timestamp and appends `.1`, `.2`, … until the name is free.

**`strip_slash`** (`:107`) — removes trailing slashes (keeping bare `/`). This is
why `copy config/nvim/` and `copy config/nvim` behave identically, and why
`${source##*/}` reliably yields the basename.

**Path → db form.** Three helpers turn what the user typed into the
root-relative db path:

- **`root_relative`** (`:121`) — the textual normalizer. Given an absolute path,
  it collapses `//`, drops `.` components (`/./`, a trailing `/.`), strips
  trailing slashes and the leading `/`. It deliberately leaves `..` alone so
  `valid_target` can still see and reject it. `/` itself becomes the empty
  string, which `valid_target` also rejects.
- **`resolve_path`** (`:140`) — for a path that **exists**. It resolves the
  path's *parent* physically (`cd -P` + `pwd -P`, both POSIX — no `realpath`
  dependency), re-attaches the basename, and normalizes. So `./LOGIC.md` from
  `~/Projects/x` becomes `home/me/Projects/x/LOGIC.md`, from any directory.
  Returns nonzero only when the parent can't be resolved. Used for the default
  target of `link`/`copy` and as `remove`'s first lookup.
- **`literal_path`** (`:148`) — for a path that may **not** exist yet. Absolute
  as given, otherwise appended to the physical cwd (`pwd -P`), then
  normalized. It never follows a symlink in the path itself, which matters:
  a symlinked parent stays visible to `guard_path` instead of being silently
  resolved past. Used for explicit `[target]`s and by `remove`.

**`valid_target`** (`:158`) — the *string-level* guard, applied to every db
path from user input and from `index.db` alike. Rejects:

- the empty path (i.e. `/` itself);
- absolute paths (`/*`) — db paths are root-relative, so a leading `/` can only
  come from a hand edit;
- anything with a `..` component (`../*`, `*/../*`, `*/..`, `..`);
- anything that **overlaps `~/.dotsx`**: the dotsx directory itself, anything
  inside it, or any ancestor of it (`home/me`, `home`). Tracking those would
  make the store copy itself — `link ~` would try to move the store into the
  store. Checked against both the logical (`$HOME/.dotsx`) and physical
  (`DOTSX_REAL`) spellings.

**`within_tree`** / **`guard_path`** (`:178`, `:199`) — the *filesystem-level*
companion to `valid_target`. A purely textual check can't catch a path that
escapes through a **symlinked parent directory**: if `~/.config` is a symlink to
`/mnt/elsewhere`, the string `home/me/.config/foo` looks innocent but a deploy
(`mkdir`/`cp`/`ln`/`rm`) would write into `/mnt/elsewhere` — somewhere other
than what the index records. `within_tree base rel` walks the existing parent
components of `base/rel` and returns false if any is a symlink (the **leaf is
not checked** — a tracked entry's own deployed file is legitimately a symlink);
an empty `base` means `/`. `guard_path rel` runs that check against **both**
the store and `/` and is the single chokepoint, called
from `prepare_source` (so `link` and `copy` are covered), from the `apply_db`
loop (both `sync` and `repair`, counted as a non-fatal per-entry error), and from
`cmd_remove`. Because it gates DB-read paths too, a hand-edited `index.db` can't
use a symlinked ancestor to escape either. Note that it walks from `/`, so a
target under a system symlink such as Arch's `/bin -> usr/bin` is refused;
a *source* there is fine, because `resolve_path` records it physically
(`usr/bin/...`).

**`parent_writable`** (`:214`) — walks up from the target's parent to the
nearest directory that exists and fails, with a `permission denied` message,
unless it is writable. `link` and `copy` call it **before** `store_first`. A
deploy into `/etc` without root would otherwise fail only *after* the store
copy had landed, aborting before `db_set` and leaving a ghost. It's an early
refusal, not a guarantee (a file-level permission can still fail later), but
it turns the common case into a clean no-op.

**`parse_line`** — splits a line into `f_type`, `t_type`, `t_mode`, `t_path`
using prefix/suffix expansion. The key detail: `t_path` takes *everything* after
the **third** colon, so a path that itself contains a colon survives intact.

**`db_remove`** (`:234`) / **`db_set`** (`:251`) — the DB writer. `db_remove`
rewrites the file into a temp (`$DB.tmp.$$`) keeping every line whose path ≠ the
target, then `mv`s it over — atomic, so a crash can't leave a half-written DB.
`db_set` calls `db_remove` then appends the new line. That remove-then-append is
what makes re-running `link`/`copy` on the same target **not** create duplicate
entries.

**`safe_to_place`** — the data-loss guard, the heart of the safety model. Given
a live target, source, and db path, it returns "safe" only if:

1. the target is a **symlink** — removing a link never destroys the data it
   points at; or
2. the target doesn't exist — nothing to lose; or
3. the target **is the source itself** (`-ef`, inode comparison) — its content
   is about to be preserved in the store anyway; or
4. the target **still matches the store copy** for that path
   (`content_matches "$STORE/$3" "$1"`) — it's the unmodified artifact we
   already deploy, so refreshing it loses nothing.

Otherwise it returns false → the command refuses. `-ef` compares inodes, so a
relative path and an absolute path to the same file are correctly recognized as
identical.

> **Why a content check, not a name check.** An earlier version asked only
> "is this path tracked in `index.db`?" (`is_tracked`). That was unsafe: a path
> can be tracked while the file *currently on disk* has been replaced by real,
> unmanaged content (e.g. the user deleted the symlink and dropped in a real
> file). The name was tracked, so the guard allowed the clobber and the data was
> lost. The legitimate "re-run `link`/`copy` to update" case is already covered
> by the symlink check (#1) and the matching-copy check (#4), so the name-only
> branch only ever fired in the dangerous case. The content comparison closes
> that hole while still allowing a genuine refresh of an unmodified artifact.

**`ensure_store`** (`:271`) — errors out if `$STORE` doesn't exist yet, pointing
at `dotsx init`. Called first by every command that touches the store —
`link`, `copy`, `sync`, `repair`, `ghost`, `remove`. **`init` and `list` do not
call it**: `init` is what creates the store, and `list` only reads `index.db`,
so it works even if the store directory is missing (it checks for the DB itself
instead).

---

## `init` — `cmd_init, :282`

The only command that creates anything outside the store, and the only one that
doesn't call `ensure_store` first. It is **idempotent** — safe to re-run on an
existing setup.

1. `mkdir -p "$STORE" "$BACKUPS"` (`:283`) — create the store *and* the backups
   directory in one call (`-p`, so no error if either already exists). Both are
   made up front so `backup_path` never has to worry about the top-level
   directory being absent. A failure here is fatal: error and return 1.
2. `touch "$DB"` **only if it doesn't already exist** (`:287`) — so re-running
   never blanks an existing database. Also fatal if it fails.
3. Verify the store and DB are both readable **and** writable (`:292-299`),
   accumulating into `rc` rather than bailing on the first failure — so one run
   reports every permission problem, not just the first.
4. Print `Initialized <dir>` only if everything checked out (`:300`); return
   `rc`.

Note that step 3 only checks `$STORE` and `$DB`, not `$BACKUPS` — an unwritable
backups directory isn't caught here, only later when a backup is actually
attempted (where it correctly aborts the overwrite).

---

## Argument parsing for `link`/`copy` — `parse_add_args, :309`

Both add-commands share this. It walks the args:

- `-r` → sets `recursive=1`. Only `copy` ever reads this flag; `link` accepts it
  (the parser is shared) and silently ignores it.
- any other `-*` → "unknown flag" error (commands parse their own options — the
  top level deliberately doesn't)
- first bare word → `source`, second → `target`, a third → "too many arguments"

Flags may appear anywhere in the argument list — the loop is a plain `for` over
`"$@"` with no terminator, so `copy -r dir` and `copy dir -r` are equivalent.

Then: source is required and run through `strip_slash`; the target is validated
against traversal.

**Default target — track in place.** When no explicit target is given, the
target is the source's own location, computed by **`resolve_path`** (physical
parent + basename, root-relative). So `link ./LOGIC.md` run from
`~/Projects/x` records `home/me/Projects/x/LOGIC.md` and replaces *that* file
in place, and `copy ./foo.service` run from `/etc/systemd/system` records
`etc/systemd/system/foo.service`. There is no "outside `$HOME`" fallback any
more: every existing path has a location. If the parent can't be resolved, the
source can't exist, and that's the error reported.

**Explicit target — an ordinary path.** A `[target]` goes through
**`literal_path`**: absolute as given, or relative to the current directory,
exactly like the second argument to `cp`. It is *not* resolved physically, so a
symlinked parent in it reaches `guard_path` and is refused. Either way the
result is then `valid_target`-checked.

**The orphaned-source caveat.** Tracking in place is what normally makes the
store/live path *be* where the source already lives, so the original is
consumed rather than duplicated. An explicit `[target]` that differs from the
source's own location breaks that identity: the source is copied into the
store, the symlink/copy is deployed at the target, and the **original source
file is left untouched** — still a real file, no longer tracked, never updated
by `sync` or `repair`. The script does not delete it for you; confirm the target
is what you want, then remove the orphan yourself.

---

## `link`/`copy` shared steps — `prepare_source, :361`, `store_first, :387`

`link` and `copy` share almost everything, so two helpers carry the common work:

- **`prepare_source`** — validates the source and sets the globals both commands
  need. It **rejects a symlink source** (the `-L` check first, so a *dangling*
  symlink still gets the clear "is a symlink" message and not "does not exist"):
  its intent is ambiguous (track the link, or its target?) and dereferencing it
  would store a surprise copy and orphan the link. It then requires the source to
  **exist**, computes `dst` (`$STORE/<target>`) and `live_tgt` (`/<target>`), picks `f_type` (directory → `d` with
  `cp -Rp`, else `f` with `cp -p`), and **captures the source's mode** with
  `file_mode` for enforcement.
- **`store_first`** — lands the canonical copy in the store before the original is
  touched. It runs the **overwrite guard** (`safe_to_place`; refuse if the live
  target is unmanaged, unrelated data), makes the store parent dir, then — unless
  source already *is* the store file (`-ef`) — backs up any existing `dst` to
  `backups/` (kind `store`), wipes it, and copies the source in. So the canonical
  copy always exists before anything else changes; nothing is ever only in the
  live location.

## `link <source> [target]` — `cmd_link, :408`

Goal: move a file/dir into the store and replace the original with a symlink.

1. `ensure_store`, parse args, `prepare_source`, `parent_writable` (the live
   location must be writable — a link always writes there), `store_first`.
2. **Replace live target**: remove whatever's there (we already proved it's
   safe) and create the symlink `live_tgt → dst`.

   The live target's **parent directory is created first** (`mkdir -p`), because
   an explicit `[target]` may name a directory that doesn't exist yet.
   `store_first` only `mkdir`s the *store* side, so without this the bare `ln -s`
   would fail — and it would fail *after* the store copy landed but *before*
   `db_set` runs, leaving an untracked store file (a **ghost**) behind. `copy`
   never had this problem because `deploy_copy` does its own `mkdir -p`.
3. **Record** `f:l:<mode>:target` (or `d:l:…` for a directory), then print
   `Linked: …`. (`cp -p` already gave the store file the source's mode; recording
   it lets `sync`/`repair` re-enforce it later.)

**Directories need no `-r` here**, unlike `copy`. `prepare_source` already picked
`cp -Rp` from the `f_type=d` branch, and the result is a single symlink to the
stored directory, so there is nothing for a recursion flag to opt into. `link`
also does **not** refuse an empty directory — that check lives only in `copy`.

---

## `copy <source> [target] [-r]` — `cmd_copy, :444`

Goal: keep a plain copy in the store *and* in place (no symlink) — for things
that shouldn't be symlinked.

Same skeleton as `link` (`prepare_source` then `store_first`), with three
differences:

- **Directory handling** (after `prepare_source` sets `f_type=d`): a directory
  source requires `-r`, otherwise it's rejected; and an **empty** directory is
  refused (`ls -A` is empty) — only non-empty structures are tracked.
- Before `store_first` it runs `parent_writable` **only when the copy deploys
  somewhere else**. An in-place copy (source *is* the live target) never writes
  to the live location, so `copy /etc/foo.conf` works without root — only the
  store and index change.
- After `store_first`, it **deploys a real copy to the live target** via
  `deploy_copy` instead of symlinking — skipped when source already *is* the
  live target.
- It **records** `f:c:<mode>:` or `d:c:<mode>:`, then prints `Copied: …`.

Two deploy helpers it relies on: **`content_matches`** compares target vs. store
(`cmp -s` for files, `diff -r` for dirs); **`deploy_copy`** backs up the target
(kind `live`), makes the parent dir, clears the target, and copies store→target.

---

## `sync` / `repair` — one DB walk: `apply_db, :589`

`sync` and `repair` are 95% the same walk over `index.db`, so they're a single
function — `apply_db <op>`, where `<op>` is `sync` or `repair`. **Non-fatal by
design**: it fixes what it can, counts `errors`, and only returns nonzero at the
end. Goal: make the filesystem match `index.db`. They diverge in exactly two places (a
blocked link target, and the summary line), called out below.

Two preconditions are checked up front, and these *are* fatal (return 1 before
the walk begins): `ensure_store`, and the DB file must exist — a missing
`index.db` gets `no database at …`, not an empty, silently successful run.

For each DB line:

1. Skip blank lines; parse; then run **both** path guards on the DB-supplied
   path — `valid_target` (string-level: absolute, `..`, overlapping `~/.dotsx`)
   and `guard_path` (filesystem-level: symlinked parents). Either failure logs,
   counts an error, and `continue`s to the next entry. This is what stops a
   hand-edited `index.db` from steering a deploy through a symlink or into the
   store itself.
2. **Source-missing check**: if `$STORE/path` is gone, that's corruption —
   log, count, `continue`.
3. **Mode enforcement on the store file first** (`apply_mode "$t_mode" "$src"`),
   so a source whose own permissions were stripped (e.g. `000`) becomes readable
   before we compare or copy it.
4. **Link entries (`l`)** → `deploy_link`:
   - Already a correct symlink → leave it.
   - A *wrong* symlink → `rm -f` it (safe — only the link is removed) and relink.
   - Nothing there → create the symlink, **creating any missing parent
     directories first**. This is what makes restore-to-a-new-machine work: after
     cloning the store, an `l` entry like `.config/nvim/init.vim` has to be
     deployed into a `~/.config/nvim/` that doesn't exist yet (likewise
     `/etc/systemd/system/foo.service.d/`). `relink` therefore
     mirrors `deploy_copy` and runs `mkdir -p "$(dirname "$tgt")"` before `ln -s`
     — otherwise every `l` entry under a not-yet-created directory would fail on
     a fresh machine while every `c` entry succeeded. `guard_path` has already
     cleared this entry and `mkdir -p` only ever creates real directories, so
     creating parents can't open an escape from the recorded path.
   - A **real file/dir** sitting where a link belongs → **this is the one
     behavioural split.** Under `sync` it **refuses to delete it**, emits an
     error pointing at `repair`, and counts it (the key safety rule: `sync` never
     destroys unmanaged data non-interactively). Under `repair` it **prompts**
     `Overwrite? [y/N]`; `y` removes and relinks, anything else leaves it
     untouched. The read is from `/dev/tty`, not stdin, because the loop is
     `while read ... done <"$DB"` — stdin is the database file, so a plain `read`
     would consume the next DB line instead of the keystroke. The redirections
     are ordered `2>/dev/null </dev/tty` so that with no terminal at all the
     failed open is silent and `|| ans=n` defaults to leaving the file untouched
     — never a silent destroy.
5. **Copy entries (`c`)**: if content matches, leave it; otherwise re-deploy from
   the store. Then `apply_mode "$t_mode" "$tgt"` enforces the recorded mode on
   the deployed live copy too (the store copy was already done in step 3).
6. Unknown `track_type` → counted as an error.

A write that fails for lack of permission (a system entry when `sync` runs
without root) is just another per-entry error: it's reported, counted, and the
walk carries on with the entries it *can* deploy.

Two small helpers keep the loop tight: **`apply_mode`** runs `sync_mode` and
folds the 0/1/2 result into the run state (a `chmod` marks the entry changed, a
failed `chmod` bumps `errors`); **`relink`** creates the `src → tgt` symlink and
marks the entry changed. Counting is **per entry, not per fix**: a `changed` flag
is reset at the top of each iteration, set by any helper that actually altered
something, and folded into `n` once at the end. So a single copy entry that needs
a relink/redeploy *and* a mode `chmod` counts as **one** file updated, not two or
three — the summary reports files touched, not individual operations.

**The other split is the summary line.** `sync` prints `Sync complete. N files
updated.` and, if any entries failed, the count to stderr + return 1. `repair`
prints `Repair complete. N links restored. M errors found.` and returns nonzero
if `M > 0`.

---

## `list` — `cmd_list, :684`

Goal: print the database as a human-readable table.

1. Require the DB to exist, then make a first pass just to **count** non-blank
   lines. Zero → print `No files tracked.` and return 0 (so an empty store reads
   as a clean state, not an error).
2. Otherwise print a header row (`TYPE TRACK MODE PATH`) and a second pass that,
   per entry, **expands the single-letter codes into words** — `f`→`file`,
   `d`→`dir`, `l`→`symlink`, `c`→`copy` — and prints the mode, substituting `-`
   for an empty mode (`${t_mode:--}`) so the columns still line up.
3. Close with a blank line and `N file(s) tracked.`

Paths are printed in db form (`home/me/.bashrc`), which `remove` accepts as-is
from any directory.

It's read-only: it never touches the store, the live files, or the DB.

---

## `ghost` — `cmd_ghost, :742`

Goal: surface **ghosts** — canonical files sitting in the store that no DB entry
references. These are the residue of a hand-edited `index.db` or a half-finished
removal: `sync`/`repair` never deploy them because nothing points at them, so
they'd otherwise rot invisibly.

Like the DB-walking commands it requires both a store (`ensure_store`) and an
existing `index.db` up front, and fails with `no database at …` otherwise — with
no index there is no way to tell a ghost from a tracked file.

It walks `find "$STORE" ! -type d` (every store file, not directories) fed in via
a **heredoc rather than a pipe** — that keeps the loop in the current shell so the
`found` counter survives (a piped `while` runs in a subshell and the count would
be lost). For each store file it strips the `$STORE/` prefix to a relpath and
asks **`path_tracked`** (`:727`) whether the DB accounts for it. Because the
store mirrors `/`, a store-relative path *is* a db path; no translation is
needed.

`path_tracked` returns true when the relpath either **equals** a tracked
`t_path` (a file entry) **or lives beneath one** (`"$t_path"/*` — a directory
entry covers everything under it). So a file inside a tracked directory is *not*
a ghost, while a stray dropped anywhere else in the store is. Anything untracked
is printed; if nothing is found it warns `no ghost files in store`. Always
returns 0 — it's a diagnostic, not a check that can fail.

---

## `remove <target>` — `cmd_remove, :786`

Goal: stop tracking a path and leave a plain, untracked file in its place. The
inverse of `link`/`copy`, and just as careful never to lose data.

1. `ensure_store`, require the DB, then `strip_slash` the argument and form its
   **`literal_path`**, which is `valid_target`-checked up front. So `remove
   ../escape` is still refused as unsafe before any lookup happens.
2. **Locate the entry** with **`db_find`** (`:770`), which scans the DB and, on
   a match, leaves `f_type`/`t_type`/`t_mode` set for the dispatch below. The
   argument is tried three ways, first match wins:
   1. **`resolve_path`** — resolved physically, exactly as `link`/`copy` derive
      a default target, so `remove ./LOGIC.md` from a subdirectory finds what
      `link ./LOGIC.md` recorded;
   2. **`literal_path`** — taken literally, for when the parent is gone, or has
      become a symlink that `guard_path` must still get to see and refuse;
   3. **the argument as a db path** — the exact string `list` prints
      (`home/me/.bashrc`), which therefore works from any directory.

   No match → `not tracked` error, exit 1.
3. `guard_path`, then the **source-missing check**: if `$STORE/target` is gone,
   refuse with `corruption` rather than guess — there's no canonical content to
   restore.
4. Branch on `t_type`:
   - **link (`l`)** — the data lives *only* in the store (the symlink just points
     at it), so **move it back out**: if something is at the live target, back it
     up first **only when it's a real file** (drift — a stale symlink loses
     nothing and is just removed), remove it, then `mv` the store file to the
     live location. The symlink is replaced by the real file.
   - **copy (`c`)** — the live file may have diverged, so reuse **`deploy_copy`**
     to overwrite it with the store version (which backs up the current content,
     kind `live`, first), then **`rm -rf` the store copy**. What's left is a
     plain file holding the store version; the prior content is in `backups/`.
5. **`db_remove target`** drops the entry (atomic temp-file rewrite), then print
   `Removed: …`.

The result in both cases: the path is gone from the DB and the store, an ordinary
file remains in place, and nothing the user had was destroyed without a backup.

---

## Dispatch — `:902-926`

`cmd` is the first arg; it's `shift`ed off (guarded by `[ "$#" -gt 0 ]` so a
bare invocation doesn't `shift` an empty list) and `"$@"` becomes the command's
own args.

The `case` routes only on the **command word**, and four commands carry a
two-letter alias matching the Unix tool they echo:

| command  | alias | command  | alias |
| -------- | ----- | -------- | ----- |
| `list`   | `ls`  | `copy`   | `cp`  |
| `link`   | `ln`  | `remove` | `rm`  |

`init`, `ghost`, `sync`, `repair`, and `help` have no alias. `help` prints
`usage` to stdout and exits 0; an **empty** command prints usage to **stderr**
and exits 1; anything else — including `-h` and `--help`, which are deliberately
*not* special-cased — is "unknown command" (error + usage on stderr, exit 1).

Option parsing is intentionally left entirely to the individual commands: the
top level never inspects anything past the command word.

---

## The safety guarantees, in one place

- **Store-first**: canonical copy lands in `~/.dotsx/store` before the original
  is touched.
- **Nothing overwritten is lost**: before replacing the store copy (re-add) or a
  live copy (`sync`/`repair`), `backup_path` saves the current content to
  `backups/`.
- **No unrecoverable deletes**: `safe_to_place` blocks `link`/`copy` from
  clobbering unmanaged data; `sync` refuses to delete a real file at a link
  target; `repair` only overwrites a real file after an explicit `y`; `remove`
  always leaves a real file in place and backs up a diverged copy before
  restoring the store version.
- **Atomic DB**: every write goes through a temp file + `mv`.
- **Traversal-proof**: `valid_target` rejects `..`, `/` itself, absolute db
  paths, and anything overlapping `~/.dotsx`; `guard_path` rejects any target
  with a symlinked parent directory, so a deploy always lands at exactly the
  path the index records — for both user input and DB-read paths.
- **No half-done adds on permission errors**: `parent_writable` refuses a
  `link`/`copy` whose live location isn't writable before the store is touched.
- **No ambiguous sources**: a symlink source is rejected up front rather than
  silently dereferenced.
- **Permission-aware**: the intended octal mode is recorded per entry and
  re-enforced by `sync`/`repair` (on the store file for symlinks), so a `git`
  round-trip or stray `chmod` can't silently weaken e.g. a `600` key.
- **Resilient**: `init`, `sync`, and `repair` accumulate problems and report at
  the end rather than aborting on the first.
