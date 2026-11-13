# dotsx

A file manager for configuration in one POSIX shell script. It keeps the files
you care about — dotfiles in `$HOME`, service units in `/etc`, anything else on
the machine — in a single directory and puts them where they belong, as
symlinks, or as plain copies when a symlink won't do.

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

**One job.** It does not wrap `git`, template your configs, manage packages, or
escalate privileges for you.
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
sudo HOME="$HOME" "$(command -v dotsx)" copy /etc/systemd/system/foo.service
dotsx list                          # everything tracked, as a table
dotsx sync                          # make the filesystem match the index
```

On a new machine, clone your store into `~/.dotsx/store`, restore `index.db`
alongside it, and run `dotsx sync`. Missing parent directories are created for
you, so a bare system is a fine starting point. Paths are recorded absolutely,
so a store restored under a different username needs its `home/<name>` entries
renamed to match.

## Commands

| Command  | Alias | What it does                                              |
| -------- | ----- | --------------------------------------------------------- |
| `init`   |       | Create `~/.dotsx`, its store, backups, and index           |
| `link`   | `ln`  | Move into the store, leave a symlink behind                |
| `copy`   | `cp`  | Copy into the store, leave an independent copy behind      |
| `list`   | `ls`  | Print the index as a table                                 |
| `remove` | `rm`  | Stop tracking; leave an ordinary file behind               |
| `sync`   |       | Make the filesystem match the index, non-interactively     |
| `repair` |       | Same walk, but prompt before overwriting unmanaged files   |
| `ghost`  |       | List store files the index doesn't reference               |
| `help`   |       | Print usage                                                |

### link and copy

`link` replaces the original with a symlink into the store, so edits at either
end are the same file. `copy` leaves an independent copy in place, for the
files that refuse to be symlinks — some daemons and SSH configurations reject
them, and a few tools rewrite them in place.

Copies flow one way, store to live location. After editing a copied file in place, run
`copy` again to push it back; a `sync` would instead restore the stored version
over your edit. Either way the overwritten content is backed up first, so the
edit is recoverable.

The two commands differ in one more place: `copy` requires `-r` for a directory
and refuses an empty one, while `link` needs no flag and doesn't care, because
the result is a single symlink either way.

### Tracking in place

With no explicit target, a source is tracked **where it already lives**, inside
`$HOME` or anywhere else:

```sh
cd ~/Projects/x
dotsx link ./notes.md      # tracked as home/<you>/Projects/x/notes.md
cd /etc/systemd/system
dotsx copy ./foo.service   # tracked as etc/systemd/system/foo.service
```

This works from any directory and at any depth. `remove` accepts the same path
you added with, an absolute path, or the exact path `list` prints.

An explicit target is an ordinary path: absolute, or relative to the current
directory, like the second argument to `cp`. It is how you deliberately rename
or relocate — but be aware it leaves the original behind as an untracked file,
since the tracked path is now somewhere else. That orphan is a real file that no
longer receives updates; delete it once you've confirmed the new location is
what you wanted.

### System files and root

Files outside `$HOME` usually belong to root, so changing them needs root. Run
`dotsx` through `sudo`, but keep your own `$HOME`: `sudo` normally resets it to
`/root`, which would point `dotsx` at root's (empty) `~/.dotsx` instead of yours.

```sh
sudo HOME="$HOME" "$(command -v dotsx)" sync
```

(The full path is there because `sudo`'s `secure_path` usually leaves out
`~/.local/bin`.) Without root, a `link` or `copy` that would have to write to a
directory you can't write to is refused up front, before anything lands in the
store. An in-place `copy` never writes to the live location, so you can start
tracking `/etc/foo.conf` without `sudo`. A `sync` without root deploys
everything it can and counts the system entries it couldn't write as errors.

Prefer `copy` for system files. Many services refuse to follow a symlink into a
user's home (`ProtectHome=`, for example). And a link into your store means
you can edit that system file without `sudo`, so be deliberate about it.

## Layout and index

```
~/.dotsx/store/      your files, in a tree that mirrors /
~/.dotsx/backups/    prior versions, saved before any overwrite
~/.dotsx/index.db    the index
```

The store mirrors the filesystem: `/etc/foo.conf` is kept at
`~/.dotsx/store/etc/foo.conf` and `~/.bashrc` at
`~/.dotsx/store/home/<you>/.bashrc`. The index sits beside the store rather than
inside it, so the store stays a clean tree of nothing but your files —
convenient if you point `git` at it.

```
field_type:track_type:mode:path
#  f|d        l|c       644   path/relative/to/root
```

`path` is relative to `/`, with no leading slash: `home/me/.bashrc`,
`etc/systemd/system/foo.service`. That one path names both the live file
(`/<path>`) and the store copy (`~/.dotsx/store/<path>`).

`mode` is the octal permission the file should have, and `sync`/`repair` re-apply
it. This exists because `git` records only the executable bit: clone a repo
containing a `600` private key and it comes back `644`. For symlinked entries the
mode is enforced on the store file, which is what tools like `ssh` actually
inspect. The field sits before the path so that a path containing a colon still
parses — the path is everything after the third one.

## Safety model

- Nothing `dotsx` doesn't manage is ever deleted, wherever it lives.
- Before overwriting a tracked file — the store copy on re-add, the live copy on
  `sync`/`repair` — the current content is saved to
  `~/.dotsx/backups/<path>.<store|live>.<timestamp>`.
- `link` and `copy` refuse to overwrite an existing target unless it is a
  symlink, the source itself, or an unmodified copy `dotsx` already deployed.
  The check compares content, not just the path, so a tracked name whose file has
  been replaced by real data is still protected.
- `sync` will not delete a real file or directory sitting where a link belongs.
  It reports it and leaves it for `repair`, which asks first. With no terminal
  available, `repair` defaults to leaving the file untouched.
- Index writes are atomic: a temp file and a rename.
- Targets containing `..`, targets whose parent directory is a symlink, and `/`
  itself are all rejected, so a deploy cannot follow a symlinked parent
  (`~/.config` pointing at an external drive, say) and write somewhere other
  than the path the index records. A target can't be `~/.dotsx`, anything
  inside it, or any directory that contains it (such as `$HOME` or `/home`), so
  the store can never be asked to store itself. These checks apply to paths
  read back out of `index.db` too, along with a ban on absolute paths there, so
  a hand-edited index can't get around them.
- `link` and `copy` check that the live location is writable before touching the
  store, so a permission failure leaves nothing half-done.
- `sync` and `repair` treat per-entry problems as non-fatal: they fix what they
  can, count what they can't, and report once at the end.

## Limitations

- **Copies are one-way.** Editing a copy-tracked file in place does not update
  the store. Re-run `copy` to push it.
- **Removal is one path at a time.** `remove` always leaves a real file behind
  and never deletes your data, but there is no bulk or recursive un-tracking.
- **Backups are never pruned.** Every overwrite adds a timestamped copy. Clear
  out `~/.dotsx/backups/` yourself when it grows.
- **Directories track only their top-level mode.** Permissions inside a tracked
  directory are preserved when copied, but not individually re-enforced.
- **Symlink sources are rejected.** Point `dotsx` at the real file or directory.
- **Ownership is not tracked.** Copies keep the owner of the file they were
  copied from where the user running `dotsx` is allowed to (`cp -p`), so as root
  a deployed copy takes the owner of its store file. Files you add as root
  stay root-owned in the store and deploy root-owned. Files that came from a
  fresh `git clone` belong to you, and so will their deployed copies, until you
  `chown` them.
- **Root is your call.** `dotsx` never runs `sudo` itself. See
  [System files and root](#system-files-and-root).
- **No git integration.** The store is git-friendly; committing and pushing is
  your job.
- The line-based index cannot represent paths containing newlines. Colons are
  fine.

## Tests

```sh
sh tests/run_tests.sh
```

262 assertions across 13 suites, covering the safety guarantees above along with
the awkward cases: colons and spaces in paths, unreadable store files, symlinked
parents, paths outside `$HOME`, unwritable destinations, interrupted operations,
and the interactive `repair` prompt under a pseudo-terminal. Every suite runs in
a throwaway `$HOME` (and throwaway "system" directories outside it), so the
tests never touch your real files and never need root. See `tests/README.md`.

`LOGIC.md` is a full walkthrough of the implementation — the data model, every
shared helper, and each command's exact flow with the reasoning behind each
check.

## Status

Young, and built for personal use. It is carefully tested and deliberately
conservative about your data, but it has not seen wide real-world exposure. Read
the limitations above before trusting it with anything you cannot reproduce.
