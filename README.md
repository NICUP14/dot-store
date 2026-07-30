# dotsx

A dotfile manager in one POSIX shell script. It keeps your configuration files in
a single directory and puts them where they belong in `$HOME` — as symlinks, or
as plain copies when a symlink won't do.

There is no daemon, no config file, no lockfile, and no runtime to install. The
whole program is `dotsx.sh`, and the whole state is a directory of your files
plus a text index you can read in a pager.

## Philosophy

Most dotfile managers fail in the same place: the moment something on disk isn't
what they expected. A file exists where a link should go. A symlink points
somewhere stale. The index disagrees with reality. The tempting move is to guess
and carry on. `dotsx` is built around the opposite instinct.

**The canonical copy lands first.** Every add operation writes into the store
*before* touching the original. If the command dies halfway, the worst case is a
file that exists in two places — never one that exists in none.

**Nothing is quietly destroyed.** Before any overwrite, the current content is
copied to `backups/` with a timestamp. This is not best-effort: if the backup
cannot be written, the operation refuses to proceed rather than press on with an
unrecoverable overwrite. Backups are never reused or clobbered, so two writes in
the same second produce two backups.

**Refuse rather than guess.** A symlink handed in as a source is rejected outright
instead of silently dereferenced. An unmanaged file sitting where a link belongs
stops `sync` cold. Ambiguity is reported, not resolved on your behalf.

**Automatic and interactive are different commands.** `sync` is the one you can
put in a script: it never destroys unmanaged data without asking, and when it
can't proceed it says so and exits nonzero. `repair` is the one you run yourself,
and it is the only one that will prompt you to overwrite something it doesn't
manage. Keeping these apart means the safe operation is also the ergonomic one.

**Plain text, all the way down.** The index is a flat file with one entry per
line. The store is an ordinary directory tree. Both are meant to be read, edited,
diffed, and repaired by hand. If `dotsx` vanished tomorrow, everything it manages
would still be sitting there in a form you can use.

**One job.** It does not wrap `git`, template your configs, or manage packages.
The store is a normal directory; put it under version control or don't.

## Install

```sh
cp dotsx.sh ~/.local/bin/dotsx
chmod +x ~/.local/bin/dotsx
```

It targets `sh`/`dash`/BusyBox, not just Bash, and leans on a normal Unix
userland: `cp`, `ln`, `mv`, `rm`, `mkdir`, `chmod`, `cat`, `ls`, `find`, `date`,
`touch`, `basename`, `dirname`, `cmp`, `diff`, `stat`, `readlink`. Only the last
two sit outside strict POSIX, and both are handled portably — `stat` is tried in
its GNU form and then its BSD form, and if neither works mode tracking degrades
to "no mode recorded" instead of breaking.

## Quick start

```sh
dotsx init                          # create ~/.dotsx and its index
dotsx link ~/.bashrc                # store it, leave a symlink in its place
dotsx copy ~/.ssh/config            # store it, leave a real copy in its place
dotsx copy ~/.config/nvim -r        # directories need -r for copy
dotsx list                          # everything tracked, as a table
dotsx sync                          # make $HOME match the index
```

On a new machine, clone your store into `~/.dotsx/store`, restore `index.db`
alongside it, and run `dotsx sync`. Missing parent directories are created for
you, so a bare `$HOME` is a fine starting point.

## Commands

| Command  | Alias | What it does                                              |
| -------- | ----- | --------------------------------------------------------- |
| `init`   |       | Create `~/.dotsx`, its store, backups, and index           |
| `link`   | `ln`  | Move into the store, leave a symlink behind                |
| `copy`   | `cp`  | Copy into the store, leave an independent copy behind      |
| `list`   | `ls`  | Print the index as a table                                 |
| `remove` | `rm`  | Stop tracking; leave an ordinary file behind               |
| `sync`   |       | Make `$HOME` match the index, non-interactively            |
| `repair` |       | Same walk, but prompt before overwriting unmanaged files   |
| `ghost`  |       | List store files the index doesn't reference               |
| `help`   |       | Print usage                                                |

### link and copy

`link` replaces the original with a symlink into the store, so edits at either
end are the same file. `copy` leaves an independent copy in `$HOME`, for the
files that refuse to be symlinks — some daemons and SSH configurations reject
them, and a few tools rewrite them in place.

Copies flow one way, store to home. After editing a copied file in `$HOME`, run
`copy` again to push it back; a `sync` would instead restore the stored version
over your edit. Either way the overwritten content is backed up first, so the
edit is recoverable.

The two commands differ in one more place: `copy` requires `-r` for a directory
and refuses an empty one, while `link` needs no flag and doesn't care, because
the result is a single symlink either way.

### Tracking in place

With no explicit target, a source is tracked **where it already lives under
`$HOME`**:

```sh
cd ~/Projects/x
dotsx link ./notes.md      # tracked as Projects/x/notes.md, not ~/notes.md
```

This works from any directory and at any depth, and `remove` accepts the same
relative path you added with.

Passing an explicit target is how you deliberately rename or relocate — but be
aware it leaves the original behind as an untracked file, since the tracked path
is now somewhere else. The same happens to sources outside `$HOME`, which have no
home-relative path and fall back to their basename. In both cases the orphan is a
real file that no longer receives updates; delete it once you've confirmed the
new location is what you wanted.

## Layout and index

```
~/.dotsx/store/      your dotfiles, and only those
~/.dotsx/backups/    prior versions, saved before any overwrite
~/.dotsx/index.db    the index
```

The index sits beside the store rather than inside it, so the store stays a clean
tree of nothing but your files — convenient if you point `git` at it.

```
field_type:track_type:mode:path
#  f|d        l|c       644   relative/path
```

`mode` is the octal permission the file should have, and `sync`/`repair` re-apply
it. This exists because `git` records only the executable bit: clone a repo
containing a `600` private key and it comes back `644`. For symlinked entries the
mode is enforced on the store file, which is what tools like `ssh` actually
inspect. The field sits before the path so that a path containing a colon still
parses — the path is everything after the third one.

## Safety model

- Nothing in `$HOME` or `~/.dotsx` that `dotsx` doesn't manage is ever deleted.
- Before overwriting a tracked file — the store copy on re-add, the home copy on
  `sync`/`repair` — the current content is saved to
  `~/.dotsx/backups/<path>.<store|home>.<timestamp>`.
- `link` and `copy` refuse to overwrite an existing target unless it is a
  symlink, the source itself, or an unmodified copy `dotsx` already deployed.
  The check compares content, not just the path, so a tracked name whose file has
  been replaced by real data is still protected.
- `sync` will not delete a real file or directory sitting where a link belongs.
  It reports it and leaves it for `repair`, which asks first. With no terminal
  available, `repair` defaults to leaving the file untouched.
- Index writes are atomic: a temp file and a rename.
- Absolute targets, targets containing `..`, and targets whose parent directory
  is a symlink are all rejected, so a deploy cannot follow a symlinked parent
  (`~/.config` pointing at an external drive, say) and write outside the store or
  `$HOME`. These checks apply to paths read back out of `index.db` too, so a
  hand-edited index cannot be used to escape either.
- `sync` and `repair` treat per-entry problems as non-fatal: they fix what they
  can, count what they can't, and report once at the end.

## Limitations

- **Copies are one-way.** Editing a copy-tracked file in `$HOME` does not update
  the store. Re-run `copy` to push it.
- **Removal is one path at a time.** `remove` always leaves a real file behind
  and never deletes your data, but there is no bulk or recursive un-tracking.
- **Backups are never pruned.** Every overwrite adds a timestamped copy. Clear
  out `~/.dotsx/backups/` yourself when it grows.
- **Directories track only their top-level mode.** Permissions inside a tracked
  directory are preserved when copied, but not individually re-enforced.
- **Symlink sources are rejected.** Point `dotsx` at the real file or directory.
- **No git integration.** The store is git-friendly; committing and pushing is
  your job.
- The line-based index cannot represent paths containing newlines. Colons are
  fine.

## Tests

```sh
sh tests/run_tests.sh
```

198 assertions across 13 suites, covering the safety guarantees above along with
the awkward cases: colons in paths, unreadable store files, symlinked parents,
interrupted operations, and the interactive `repair` prompt under a pseudo-
terminal. Every suite runs in a throwaway `$HOME`, so the tests never touch your
real dotfiles. See `tests/README.md`.

`LOGIC.md` is a full walkthrough of the implementation — the data model, every
shared helper, and each command's exact flow with the reasoning behind each
check.

## Status

Young, and built for personal use. It is carefully tested and deliberately
conservative about your data, but it has not seen wide real-world exposure. Read
the limitations above before trusting it with anything you cannot reproduce.
