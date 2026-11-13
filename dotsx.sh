#!/bin/sh
# dotsx - minimal POSIX file manager: dotfiles, service files, anything on disk
#
# Layout:        ~/.dotsx/store/     canonical files, mirroring / (git-friendly)
#                ~/.dotsx/backups/   prior versions, saved before any overwrite
#                ~/.dotsx/index.db   the index
# DB format:     field_type:track_type:mode:path
#   field_type   f = file, d = directory
#   track_type   l = symlink, c = copy
#   mode         octal permission bits to enforce (e.g. 600); may be empty
#   path         path relative to / -- the live file is /<path>, the store copy
#                is ~/.dotsx/store/<path>
#   example:     f:l:600:home/me/.ssh/config   f:c:644:etc/systemd/system/x.service
#
# mode comes before path so a path containing ':' still parses correctly.
#
# Nothing is ever quietly destroyed: before a tracked file is overwritten
# (the store copy on re-add, or the live copy on sync/repair) its current
# content is saved into backups/<path>.<store|live>.<timestamp>.
#
# Default target: with no <target>, the source is tracked where it actually
# lives. So `dotsx link ./LOGIC.md` from ~/Projects/x tracks it as
# home/<you>/Projects/x/LOGIC.md and replaces that file in place. This works
# from any directory, inside or outside $HOME.
#
# Caveat -- orphaned sources: an explicit <target> that differs from where the
# source really is makes dotsx copy the source into the store, deploy the
# symlink/copy at <target>, and leave the ORIGINAL source file untouched. That
# original is now orphaned: still a real file, no longer tracked, and never
# updated by sync or repair. Delete it yourself once <target> is what you want.
#
# Many filesystem states are recoverable. Subcommands that walk the DB
# (sync, repair) treat per-entry problems as non-fatal: they fix what they
# can, count the rest, and only report failure once at the end.
#
# Targets are confined: besides rejecting ".." paths and paths that overlap
# ~/.dotsx itself, dotsx refuses any target whose parent directory is a symlink
# (e.g. ~/.config -> /mnt/elsewhere), since deploying through it would write
# somewhere other than the path recorded in the index. The deployed leaf may
# itself be a symlink; only the ancestors are guarded.

DOTSX_DIR="$HOME/.dotsx"
STORE="$DOTSX_DIR/store"
BACKUPS="$DOTSX_DIR/backups"
DB="$DOTSX_DIR/index.db"
# Physical, root-relative location of DOTSX_DIR (empty if it doesn't exist yet),
# so valid_target also catches the dotsx dir reached through a symlinked path.
DOTSX_REAL=$(CDPATH= cd -P -- "$DOTSX_DIR" 2>/dev/null && pwd -P)
DOTSX_REAL=${DOTSX_REAL#/}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

err() { printf 'Error: %s\n' "$1" >&2; }
warn() { printf 'Warning: %s\n' "$1" >&2; }

# Resolve a symlink's target. readlink is not in POSIX but is present on every
# Linux/BusyBox system and is robust against odd filenames, unlike parsing ls.
link_target() {
	readlink -- "$1" 2>/dev/null
}

# Print a file's octal permission bits (e.g. 644, 600, 4755), empty on failure.
# GNU/BusyBox use -c, BSD uses -f; both are tried so the mode survives anywhere.
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# Enforce recorded octal mode $1 on path $2.
#   return 0  nothing to do (no mode recorded, path absent, or already correct)
#   return 1  mode changed successfully
#   return 2  chmod failed
sync_mode() {
	[ -n "$1" ] && [ -e "$2" ] || return 0
	[ "$(file_mode "$2")" = "$1" ] && return 0
	chmod "$1" "$2" 2>/dev/null && return 1
	return 2
}

# Save the content currently at $1 into backups/<relpath>.<kind>.<timestamp>
# before the caller overwrites it. No-op if nothing is there. Returns nonzero
# only if a backup was attempted but failed, so callers can refuse to proceed.
#   $1 path to save   $2 relpath (db path)   $3 kind tag (store|live)
#
# The timestamp has one-second resolution, so two overwrites of the same path
# within the same second would otherwise land on the same name and the later
# one would clobber the earlier backup -- the opposite of the guarantee. Never
# overwrite an existing backup: keep the timestamp and append .1, .2, ... until
# the destination is free.
backup_path() {
	[ -e "$1" ] || [ -L "$1" ] || return 0
	_bbase="$BACKUPS/$2.$3.$(date +%Y%m%d%H%M%S)"
	mkdir -p "$(dirname "$_bbase")" || return 1
	_bdst=$_bbase
	_bn=1
	while [ -e "$_bdst" ] || [ -L "$_bdst" ]; do
		_bdst="$_bbase.$_bn"
		_bn=$((_bn + 1))
	done
	cp -Rp -- "$1" "$_bdst" 2>/dev/null || return 1
	return 0
}

# Strip trailing slashes (keeping "/" itself) so basename/cp behave the same
# across coreutils and busybox regardless of how the user typed the path.
strip_slash() {
	case "$1" in
	/) printf '/' ;;
	*)
		_s=$1
		while [ "${_s%/}" != "$_s" ]; do _s=${_s%/}; done
		printf '%s' "$_s"
		;;
	esac
}

# Normalize an absolute path textually: collapse "//" and drop "." components,
# then strip the leading "/" to give the root-relative db form. ".." is left in
# place on purpose so valid_target can reject it.
root_relative() {
	_rr=$1
	while :; do
		case "$_rr" in
		*//*) _rr="${_rr%%//*}/${_rr#*//}" ;;
		*/./*) _rr="${_rr%%/./*}/${_rr#*/./}" ;;
		*/.) _rr=${_rr%/.} ;;
		*) break ;;
		esac
	done
	_rr=${_rr#/}
	printf '%s' "$(strip_slash "$_rr")"
}

# Print the db path (root-relative) of an EXISTING path $1, given relative to
# the current directory or absolute, so it is tracked where it actually lives
# (e.g. ./LOGIC.md in ~/Projects/x -> home/me/Projects/x/LOGIC.md). Resolves "."
# / ".." and symlinked parents physically (cd -P/pwd -P, both POSIX). Returns
# nonzero when $1's parent can't be resolved.
resolve_path() {
	_rp_dir=$(CDPATH= cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
	root_relative "$_rp_dir/$(basename -- "$1")"
}

# Print the db path of $1 taken literally: absolute as given, or relative to the
# current directory. Unlike resolve_path it needs nothing to exist and never
# follows a symlinked parent -- guard_path gets to see and refuse those.
literal_path() {
	case "$1" in
	/*) root_relative "$1" ;;
	*) root_relative "$(pwd -P)/$1" ;;
	esac
}

# Reject db paths that are empty (i.e. / itself), absolute, escape via "..", or
# overlap dotsx's own directory (tracking ~/.dotsx, something inside it, or an
# ancestor of it would make the store copy itself).
valid_target() {
	case "$1" in
	'' | /* | ../* | */../* | */.. | ..)
		return 1
		;;
	esac
	for _vt_d in "${DOTSX_DIR#/}" "$DOTSX_REAL"; do
		[ -n "$_vt_d" ] || continue
		[ "$1" = "$_vt_d" ] && return 1
		case "$1" in "$_vt_d"/*) return 1 ;; esac
		case "$_vt_d" in "$1"/*) return 1 ;; esac
	done
	return 0
}

# Walk the existing parent directories of base/$rel and fail (return 1) if any
# is a symlink: following it would let a deploy land somewhere other than the
# recorded path (e.g. ~/.config -> /mnt/elsewhere makes ~/.config/foo write to
# the external drive). The leaf is not checked -- a tracked entry's own
# deployed file is allowed to be a symlink. An empty base means /.
within_tree() {
	_wt_path=$1
	_wt_parents=${2%/*}
	[ "$_wt_parents" = "$2" ] && return 0 # no parent components, leaf only
	_wt_oifs=$IFS
	IFS=/
	for _wt_c in $_wt_parents; do
		[ -z "$_wt_c" ] && continue
		_wt_path="$_wt_path/$_wt_c"
		if [ -L "$_wt_path" ]; then
			IFS=$_wt_oifs
			return 1
		fi
	done
	IFS=$_wt_oifs
	return 0
}

# Refuse a db path whose parents under the store OR under / pass through a
# symlinked directory -- the central guard against a deploy escaping the
# recorded location. Prints the reason; returns 1 when unsafe.
guard_path() {
	if ! within_tree "$STORE" "$1"; then
		err "refusing /$1: a parent directory in the store is a symlink"
		return 1
	fi
	if ! within_tree "" "$1"; then
		err "refusing /$1: a parent directory is a symlink"
		return 1
	fi
	return 0
}

# Fail when the nearest existing ancestor directory of $1 is not writable, so a
# deploy that is bound to fail (a system path without root, say) is refused
# before the store copy lands rather than leaving a ghost behind.
parent_writable() {
	_pw=$(dirname -- "$1")
	while [ ! -e "$_pw" ] && [ ! -L "$_pw" ]; do _pw=$(dirname -- "$_pw"); done
	[ -d "$_pw" ] && [ -w "$_pw" ] && return 0
	err "cannot write to $_pw (permission denied)"
	return 1
}

# Split a DB line into the globals f_type, t_type, t_mode, t_path.
# Path is everything after the third colon, so colons in paths survive.
parse_line() {
	f_type=${1%%:*}
	_rest=${1#*:}
	t_type=${_rest%%:*}
	_rest=${_rest#*:}
	t_mode=${_rest%%:*}
	t_path=${_rest#*:}
}

# Remove every DB entry whose path equals $1. Written atomically via temp file.
db_remove() {
	[ -f "$DB" ] || return 0
	_tmp="$DB.tmp.$$"
	: >"$_tmp" || {
		err "cannot write to $_tmp"
		return 1
	}
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		[ "$t_path" = "$1" ] && continue
		printf '%s\n' "$line" >>"$_tmp"
	done <"$DB"
	mv "$_tmp" "$DB"
}

# Append field_type:track_type:mode:path, replacing any prior entry for the path.
db_set() {
	db_remove "$4" || return 1
	printf '%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >>"$DB"
}

# Refuse to clobber data we cannot recover. Safe when the live target is a
# symlink (removing it loses no data), is the source itself (its content is
# preserved into the store first), or is the unmodified copy we already deploy
# for this path. A real file that merely shares a tracked path name but has
# diverged from the store is NOT safe -- the user may have put real data there.
#   $1 live target   $2 source   $3 db path
safe_to_place() {
	[ -L "$1" ] && return 0
	[ -e "$1" ] || return 0
	[ "$1" -ef "$2" ] && return 0
	content_matches "$STORE/$3" "$1" && return 0
	return 1
}

# Confirm the store exists; create the parent dir for a store path.
ensure_store() {
	[ -d "$STORE" ] || {
		err "store $STORE missing; run 'dotsx init' first"
		return 1
	}
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

cmd_init() {
	if ! mkdir -p "$STORE" "$BACKUPS"; then
		err "could not create $DOTSX_DIR"
		return 1
	fi
	if [ ! -f "$DB" ] && ! touch "$DB"; then
		err "could not create $DB"
		return 1
	fi
	rc=0
	[ -r "$STORE" ] && [ -w "$STORE" ] || {
		err "$STORE is not readable/writable"
		rc=1
	}
	[ -r "$DB" ] && [ -w "$DB" ] || {
		err "$DB is not readable/writable"
		rc=1
	}
	[ "$rc" -eq 0 ] && printf 'Initialized %s\n' "$DOTSX_DIR"
	return "$rc"
}

# ---------------------------------------------------------------------------
# link / copy share most of their argument handling
# ---------------------------------------------------------------------------

# Sets globals: source, target, recursive. Returns nonzero on bad args.
parse_add_args() {
	source=''
	target=''
	recursive=0
	for arg in "$@"; do
		case "$arg" in
		-r)
			recursive=1
			;;
		-*)
			err "unknown flag: $arg"
			return 1
			;;
		*)
			if [ -z "$source" ]; then
				source=$arg
			elif [ -z "$target" ]; then
				target=$arg
			else
				err "too many arguments"
				return 1
			fi
			;;
		esac
	done
	[ -n "$source" ] || {
		err "missing <source>"
		return 1
	}
	source=$(strip_slash "$source")
	# Default target: track the source where it actually lives, so a relative
	# path like ./LOGIC.md is tracked as home/me/Projects/x/LOGIC.md and not
	# flattened anywhere. An explicit target is a path like any other: absolute,
	# or relative to the current directory.
	if [ -z "$target" ]; then
		if ! target=$(resolve_path "$source"); then
			err "source does not exist: $source"
			return 1
		fi
	else
		target=$(literal_path "$target")
	fi
	if ! valid_target "$target"; then
		err "unsafe target path: $target"
		return 1
	fi
	return 0
}

# Validate the source and set the globals link/copy both need: dst (store path),
# live_tgt (live path), f_type (f|d), cp_cmd (the copy command), mode. A symlink
# source is rejected outright (ambiguous intent); a missing source is an error.
prepare_source() {
	if [ -L "$source" ]; then
		err "source is a symlink: $source. Point dotsx at the file or directory it references."
		return 1
	fi
	if [ ! -e "$source" ]; then
		err "source does not exist: $source"
		return 1
	fi
	guard_path "$target" || return 1
	dst="$STORE/$target"
	live_tgt="/$target"
	if [ -d "$source" ]; then
		f_type=d
		cp_cmd="cp -Rp"
	else
		f_type=f
		cp_cmd="cp -p"
	fi
	mode=$(file_mode "$source")
}

# Land the canonical copy in the store before the original is touched (globals
# source, dst, live_tgt, target, cp_cmd). Refuse if the live target holds
# unmanaged data; otherwise create the store parent, back up any existing store
# copy, and copy the source in -- skipped when source already is the store file.
store_first() {
	if ! safe_to_place "$live_tgt" "$source" "$target"; then
		err "$live_tgt already exists and is not managed by dotsx; refusing to overwrite"
		return 1
	fi
	if ! mkdir -p "$(dirname "$dst")"; then
		err "could not create store path for $target"
		return 1
	fi
	[ "$source" -ef "$dst" ] && return 0
	if ! backup_path "$dst" "$target" store; then
		err "could not back up the existing store copy of $target"
		return 1
	fi
	rm -rf -- "$dst"
	if ! $cp_cmd -- "$source" "$dst"; then
		err "failed to copy $source into store"
		return 1
	fi
}

cmd_link() {
	ensure_store || return 1
	parse_add_args "$@" || return 1
	prepare_source || return 1

	parent_writable "$live_tgt" || return 1
	store_first || return 1

	# Replace whatever is at the live target with a fresh symlink.
	if [ -e "$live_tgt" ] || [ -L "$live_tgt" ]; then
		if ! rm -rf -- "$live_tgt"; then
			err "could not remove existing $live_tgt"
			return 1
		fi
	fi
	# Create the live target's parent before linking: an explicit <target> may
	# name a directory that does not exist yet. Without this the bare
	# ln fails after the store copy already landed, leaving an untracked store
	# file (a ghost) because db_set below never runs. deploy_copy does the same
	# for copy entries.
	if ! mkdir -p "$(dirname "$live_tgt")"; then
		err "could not create path for $live_tgt"
		return 1
	fi
	if ! ln -s "$dst" "$live_tgt"; then
		err "could not create symlink $live_tgt"
		return 1
	fi

	if ! db_set "$f_type" l "$mode" "$target"; then
		err "linked files but failed to update database"
		return 1
	fi
	printf 'Linked: %s -> %s\n' "$target" "$dst"
}

cmd_copy() {
	ensure_store || return 1
	parse_add_args "$@" || return 1
	prepare_source || return 1

	if [ "$f_type" = d ]; then
		if [ "$recursive" -ne 1 ]; then
			err "source is a directory. Use -r for recursive copy."
			return 1
		fi
		if [ -z "$(ls -A -- "$source" 2>/dev/null)" ]; then
			err "refusing to track empty directory: $source"
			return 1
		fi
	fi

	# An in-place copy (source is the live target) never writes there, so only
	# a copy that deploys elsewhere needs a writable destination.
	if [ ! "$source" -ef "$live_tgt" ]; then
		parent_writable "$live_tgt" || return 1
	fi

	store_first || return 1

	# Deploy the store copy to the live target so a plain copy lives there now,
	# matching link's immediacy rather than waiting for the next sync.
	if [ ! "$source" -ef "$live_tgt" ] && ! deploy_copy "$dst" "$live_tgt" "$target"; then
		err "copied to store but failed to place copy at $live_tgt"
		return 1
	fi

	if ! db_set "$f_type" c "$mode" "$target"; then
		err "copied files but failed to update database"
		return 1
	fi
	printf 'Copied: %s -> %s\n' "$target" "$dst"
}

# ---------------------------------------------------------------------------
# Content comparison for copy-tracked entries
# ---------------------------------------------------------------------------

# Returns 0 when target content matches the store source.
content_matches() {
	_src=$1
	_tgt=$2
	[ -e "$_tgt" ] || return 1
	if [ -d "$_src" ]; then
		diff -r -- "$_src" "$_tgt" >/dev/null 2>&1
	else
		cmp -s -- "$_src" "$_tgt"
	fi
}

# Copy store source onto target, replacing whatever is there. The target's
# current content is backed up first (kind "live") so a local edit that is
# about to be overwritten can always be recovered.
#   $1 store source   $2 live target   $3 db path (for backup naming)
deploy_copy() {
	_src=$1
	_tgt=$2
	backup_path "$_tgt" "$3" live || return 1
	mkdir -p "$(dirname "$_tgt")" || return 1
	rm -rf -- "$_tgt" || return 1
	if [ -d "$_src" ]; then
		cp -Rp -- "$_src" "$_tgt"
	else
		cp -p -- "$_src" "$_tgt"
	fi
}

# ---------------------------------------------------------------------------
# sync / repair share one DB walk; they differ only in how an unmanaged file
# blocking a link target is handled (sync refuses, repair prompts) and in the
# summary line.
# ---------------------------------------------------------------------------

# Enforce recorded mode $1 on path $2 (globals changed, errors): a chmod marks
# the entry changed, a failed chmod is an error.
apply_mode() {
	sync_mode "$1" "$2"
	case $? in
	1) changed=1 ;;
	2)
		err "could not set mode $1 on $2"
		errors=$((errors + 1))
		;;
	esac
}

# Create the symlink src -> tgt, marking the entry changed. Nonzero on failure.
# Missing parent directories are created first: restoring a freshly cloned store
# onto a new machine has to place links under directories (~/.config/nvim/ and
# friends) that do not exist there yet. guard_path already ran for this entry, and
# mkdir -p only ever creates real directories, so this cannot open an escape.
relink() {
	if mkdir -p "$(dirname "$tgt")" && ln -s "$src" "$tgt"; then
		changed=1
	else
		err "could not link $tgt"
		errors=$((errors + 1))
		return 1
	fi
}

# Bring the live symlink for the current entry in line with the store (globals
# op, src, tgt, t_path, n, errors). When a real file/dir is in the way, sync
# refuses (it never destroys unmanaged data); repair prompts on the terminal.
deploy_link() {
	if [ -L "$tgt" ]; then
		# Wrong symlink: removing a symlink never touches its target.
		[ "$(link_target "$tgt")" = "$src" ] && return 0
		rm -f -- "$tgt"
		relink
		return 0
	fi
	if [ ! -e "$tgt" ]; then
		relink
		return 0
	fi
	# A real file/dir lives where the link belongs.
	if [ "$op" = sync ]; then
		err "$tgt is not a symlink; run 'dotsx repair' to resolve"
		errors=$((errors + 1))
		return 0
	fi
	# repair: stdin is the DB file (the while loop reads it), so the prompt must
	# read from the terminal directly. With no terminal the read fails and we
	# default to leaving the file untouched -- never a silent destroy.
	printf 'File %s exists but is not a managed link. Overwrite? [y/N] ' "$t_path"
	read -r ans 2>/dev/null </dev/tty || ans=n
	case "$ans" in
	y | Y | yes | YES)
		rm -rf -- "$tgt"
		relink
		;;
	*)
		warn "left $t_path untouched"
		;;
	esac
}

# Walk the DB and make the filesystem match it. $1 is the operation: sync or
# repair.
# Non-fatal by design: fix what we can, count the rest, report once at the end.
apply_db() {
	op=$1
	ensure_store || return 1
	[ -f "$DB" ] || {
		err "no database at $DB"
		return 1
	}

	n=0
	errors=0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		if ! valid_target "$t_path"; then
			err "skipping unsafe path in db: $t_path"
			errors=$((errors + 1))
			continue
		fi
		if ! guard_path "$t_path"; then
			errors=$((errors + 1))
			continue
		fi
		src="$STORE/$t_path"
		tgt="/$t_path"

		if [ ! -e "$src" ]; then
			err "corruption: source missing at $src. Manual intervention required."
			errors=$((errors + 1))
			continue
		fi

		# changed tracks whether *this entry* needed any fix (a relink, a copy,
		# or a mode chmod). It is counted once at the end of the iteration so the
		# summary reports files touched, not the number of individual fixes -- a
		# single copy entry can otherwise bump the count up to three times.
		changed=0

		# Enforce the recorded mode on the store file first, so a source whose
		# own permissions were stripped (e.g. 000) becomes readable before we
		# compare or copy it.
		apply_mode "$t_mode" "$src"

		case "$t_type" in
		l)
			deploy_link
			;;
		c)
			if ! content_matches "$src" "$tgt"; then
				if deploy_copy "$src" "$tgt" "$t_path"; then
					changed=1
				else
					err "could not copy to $tgt"
					errors=$((errors + 1))
					continue
				fi
			fi
			# A copy's deployed live file must match the recorded mode too.
			apply_mode "$t_mode" "$tgt"
			;;
		*)
			err "unknown track type '$t_type' for $t_path"
			errors=$((errors + 1))
			continue
			;;
		esac

		[ "$changed" -eq 1 ] && n=$((n + 1))
	done <"$DB"

	if [ "$op" = repair ]; then
		printf 'Repair complete. %s links restored. %s errors found.\n' "$n" "$errors"
		[ "$errors" -gt 0 ] && return 1
		return 0
	fi
	printf 'Sync complete. %s files updated.\n' "$n"
	[ "$errors" -gt 0 ] && {
		printf '%s entries could not be synced.\n' "$errors" >&2
		return 1
	}
	return 0
}

# Make the filesystem match index.db non-interactively, never destroying
# unmanaged data.
cmd_sync() { apply_db sync; }

# Like sync, but prompt before overwriting an unmanaged file blocking a link.
cmd_repair() { apply_db repair; }

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

# Print the DB in a human-readable table: expand the single-letter codes into
# words and show a placeholder for an unset mode so each column lines up.
cmd_list() {
	[ -f "$DB" ] || {
		err "no database at $DB"
		return 1
	}

	count=0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		count=$((count + 1))
	done <"$DB"

	if [ "$count" -eq 0 ]; then
		printf 'No files tracked.\n'
		return 0
	fi

	printf '%-6s  %-7s  %-4s  %s\n' TYPE TRACK MODE PATH
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		case "$f_type" in
		f) _ft=file ;;
		d) _ft=dir ;;
		*) _ft=$f_type ;;
		esac
		case "$t_type" in
		l) _tt=symlink ;;
		c) _tt=copy ;;
		*) _tt=$t_type ;;
		esac
		printf '%-6s  %-7s  %-4s  %s\n' "$_ft" "$_tt" "${t_mode:--}" "$t_path"
	done <"$DB"

	printf '\n%s file(s) tracked.\n' "$count"
}

# ---------------------------------------------------------------------------
# ghost
# ---------------------------------------------------------------------------

# Is store-relative path $1 accounted for by the DB? True when it matches a
# tracked path exactly (a file entry) or lives beneath one (a directory entry).
path_tracked() {
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		[ "$1" = "$t_path" ] && return 0
		case "$1" in
		"$t_path"/*) return 0 ;;
		esac
	done <"$DB"
	return 1
}

# Print every store file that no DB entry covers, one per line. These are
# "ghosts": canonical data left behind by a hand edit of index.db or a half-done
# removal, which sync and repair never deploy because nothing references them.
cmd_ghost() {
	ensure_store || return 1
	[ -f "$DB" ] || {
		err "no database at $DB"
		return 1
	}

	found=0
	# Heredoc (not a pipe) so the loop runs in this shell and 'found' survives.
	while IFS= read -r f || [ -n "$f" ]; do
		[ -z "$f" ] && continue
		rel=${f#"$STORE/"}
		path_tracked "$rel" && continue
		printf '%s\n' "$rel"
		found=$((found + 1))
	done <<EOF
$(find "$STORE" ! -type d 2>/dev/null)
EOF

	[ "$found" -eq 0 ] && warn "no ghost files in store"
	return 0
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------

# Is db path $1 tracked? On a match parse_line leaves f_type/t_type/t_mode set.
db_find() {
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		[ "$t_path" = "$1" ] && return 0
	done <"$DB"
	return 1
}

# Stop tracking <target> and leave a plain, untracked file in its place.
#   link: the canonical data lives only in the store, so move it back out to the
#         live location, replacing the symlink that pointed at it.
#   copy: the live file may have diverged; overwrite it with the canonical store
#         version (its current content is backed up first, kind "live"), then
#         drop the store copy.
# Either way the store entry and the DB record are removed afterward.
cmd_remove() {
	ensure_store || return 1
	[ -f "$DB" ] || {
		err "no database at $DB"
		return 1
	}

	target=${1:-}
	[ -n "$target" ] || {
		err "missing <target>"
		return 1
	}
	_rm_arg=$(strip_slash "$target")
	target=$(literal_path "$_rm_arg")
	if ! valid_target "$target"; then
		err "unsafe target path: $target"
		return 1
	fi
	# Accept the path however it is written: resolved physically the way
	# link/copy derive their target (so ./LOGIC.md from a subdir works), taken
	# literally (its parent may be gone, or be a symlink guard_path must see), or
	# as the exact db path from list, which works from any directory.
	if _rt=$(resolve_path "$_rm_arg") && valid_target "$_rt" && db_find "$_rt"; then
		target=$_rt
	elif db_find "$target"; then
		:
	elif _rt=$(root_relative "$_rm_arg") && valid_target "$_rt" && db_find "$_rt"; then
		target=$_rt
	else
		err "not tracked: $target"
		return 1
	fi

	guard_path "$target" || return 1
	src="$STORE/$target"
	tgt="/$target"

	if [ ! -e "$src" ]; then
		err "corruption: source missing at $src. Cannot untrack cleanly."
		return 1
	fi

	case "$t_type" in
	l)
		# Replace the live symlink with the real file moved out of the store.
		# A real file unexpectedly sitting there (drift) is backed up before
		# we remove it, so no unmanaged data is lost.
		if [ -e "$tgt" ] || [ -L "$tgt" ]; then
			if [ ! -L "$tgt" ] && ! backup_path "$tgt" "$target" live; then
				err "could not back up existing $tgt"
				return 1
			fi
			if ! rm -rf -- "$tgt"; then
				err "could not remove $tgt"
				return 1
			fi
		fi
		if ! mkdir -p "$(dirname "$tgt")"; then
			err "could not create path for $tgt"
			return 1
		fi
		if ! mv -- "$src" "$tgt"; then
			err "could not move $src back to $tgt"
			return 1
		fi
		;;
	c)
		# Bring the live file up to the store version (backing up its current
		# content), then discard the store copy, leaving an untracked file.
		if ! deploy_copy "$src" "$tgt" "$target"; then
			err "could not restore store copy onto $tgt"
			return 1
		fi
		if ! rm -rf -- "$src"; then
			err "could not remove store copy $src"
			return 1
		fi
		;;
	*)
		err "unknown track type '$t_type' for $target"
		return 1
		;;
	esac

	if ! db_remove "$target"; then
		err "untracked files but failed to update database"
		return 1
	fi
	printf 'Removed: %s\n' "$target"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: dotsx <command> [args]

  init                       create ~/.dotsx and index.db
  list|ls                    show tracked files from index.db as a table
  link|ln <source> [target]  move into store, replace original with symlink
  copy|cp <source> [target] [-r]  copy into store, keep a plain copy in place
  remove|rm <target>         stop tracking; leave a plain file in place
  ghost                      list store files not referenced by index.db
  sync                       make the filesystem match index.db
  repair                     like sync, but prompt before overwriting

Any path on the system can be tracked: ~/.bashrc and /etc/foo.conf alike.
With no [target], the source is tracked where it lives (in place). A [target]
is a path, absolute or relative to the current directory; one that differs
from the source's own location leaves the original orphaned (real but
untracked). System paths need root: sudo HOME="\$HOME" dotsx <command>
EOF
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift

case "$cmd" in
init) cmd_init "$@" ;;
list|ls) cmd_list "$@" ;;
link|ln) cmd_link "$@" ;;
copy|cp) cmd_copy "$@" ;;
remove|rm) cmd_remove "$@" ;;
ghost) cmd_ghost "$@" ;;
sync) cmd_sync "$@" ;;
repair) cmd_repair "$@" ;;
help)
	usage
	;;
'')
	usage >&2
	exit 1
	;;
*)
	err "unknown command: $cmd"
	usage >&2
	exit 1
	;;
esac
