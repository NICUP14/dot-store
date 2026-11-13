#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="system"

# Paths outside $HOME. Each scenario gets a scratch "system" directory that lives
# outside the sandboxed $HOME, standing in for /etc and friends without root.
sysdir() {
	[ -n "$SYS" ] && { chmod -R u+w "$SYS" 2>/dev/null; rm -rf "$SYS"; }
	SYS=$(mktemp -d)
	SYS=$(cd -P -- "$SYS" && pwd -P)
	S=${SYS#/}                 # its db form
	mkdir -p "$SYS/etc/systemd/system"
}
db() { cat "$HOME/.dotsx/index.db"; }
SYS=""

# copy in place: the store mirrors the absolute location, the live file stays a
# real file, and the db records the path relative to /.
sandbox; sysdir
run init
printf '[Unit]\n' >"$SYS/etc/systemd/system/foo.service"
run copy "$SYS/etc/systemd/system/foo.service"
assert_rc 0 "copy a file outside \$HOME in place"
assert_file_is "$HOME/.dotsx/store/$S/etc/systemd/system/foo.service" "[Unit]" "store mirrors the absolute path"
assert_eq "" "$(readlink "$SYS/etc/systemd/system/foo.service")" "live file stays a real file"
assert_match "$(db)" "f:c:644:$S/etc/systemd/system/foo.service" "db path is relative to /"
run list
assert_match "$OUT" "$S/etc/systemd/system/foo.service" "list shows the system path"

# link in place outside $HOME.
sandbox; sysdir
run init
printf 'k=v\n' >"$SYS/etc/app.conf"
run link "$SYS/etc/app.conf"
assert_rc 0 "link a file outside \$HOME in place"
assert_link_to "$SYS/etc/app.conf" "$HOME/.dotsx/store/$S/etc/app.conf" "replaced by a link into the store"
assert_file_is "$SYS/etc/app.conf" "k=v" "content readable through the link"

# A relative source from a cwd outside $HOME is resolved to where it lives.
sandbox; sysdir
run init
printf 'r\n' >"$SYS/etc/rel.conf"
cd "$SYS/etc" || exit 1
run copy ./rel.conf
cd "$HOME" || exit 1
assert_rc 0 "relative source outside \$HOME"
assert_match "$(db)" "$S/etc/rel.conf" "tracked at its real location, not flattened"

# An explicit absolute target outside $HOME, under directories that don't exist.
sandbox; sysdir
run init
printf 'unit\n' >unit
run copy unit "$SYS/usr/lib/systemd/user/u.service"
assert_rc 0 "explicit absolute target with missing parents"
assert_file_is "$SYS/usr/lib/systemd/user/u.service" "unit" "deployed to the absolute target"
assert_file_is "$HOME/unit" "unit" "original left behind (the documented orphan)"

# An absolute target under $HOME is the same entry as the relative spelling.
sandbox
run init
printf 'a\n' >a
run link a "$HOME/b"
run link a b
assert_eq 1 "$(grep -c . "$HOME/.dotsx/index.db")" "absolute and relative spellings are one entry"
assert_match "$(db)" "f:l:644:$R/b" "stored in canonical form"

# An explicit relative target is relative to the current directory.
sandbox
run init
mkdir sub
printf 'x\n' >sub/f
cd sub || exit 1
run copy f g
cd "$HOME" || exit 1
assert_file_is "$HOME/sub/g" "x" "relative target resolved from the cwd"

# "//" and "/./" in a target are normalized away.
sandbox; sysdir
run init
printf 'n\n' >n
run copy n "$SYS//etc/./norm.conf"
assert_match "$(db)" "f:c:644:$S/etc/norm.conf" "target path normalized"

# sync restores system links and copies, recreating missing parent directories.
sandbox; sysdir
run init
printf 'L\n' >"$SYS/etc/l.conf"
printf 'C\n' >"$SYS/etc/systemd/system/c.service"
run link "$SYS/etc/l.conf"
run copy "$SYS/etc/systemd/system/c.service"
rm -rf "$SYS/etc"
run sync
assert_rc 0 "sync restores a wiped system tree"
assert_symlink "$SYS/etc/l.conf" "system link recreated"
assert_file_is "$SYS/etc/systemd/system/c.service" "C" "system copy recreated under new parents"
run sync
assert_match "$OUT" "0 files updated" "sync is idempotent for system entries"

# repair restores a missing system link too.
sandbox; sysdir
run init
printf 'L\n' >"$SYS/etc/l.conf"
run link "$SYS/etc/l.conf"
rm -f "$SYS/etc/l.conf"
run repair
assert_rc 0 "repair returns 0"
assert_symlink "$SYS/etc/l.conf" "repair recreated the system link"

# Overwrites of system entries are backed up under the same mirrored path.
sandbox; sysdir
run init
printf 'v1\n' >"$SYS/etc/b.conf"
run copy "$SYS/etc/b.conf"
printf 'v2\n' >"$SYS/etc/b.conf"
run copy "$SYS/etc/b.conf"
assert_file_is "$(ls -1 "$HOME/.dotsx/backups/$S/etc/b.conf.store."* | tail -1)" "v1" "store backup under the mirrored path"
printf 'local\n' >"$SYS/etc/b.conf"
run sync
assert_file_is "$SYS/etc/b.conf" "v2" "sync restores the system copy"
assert_file_is "$(ls -1 "$HOME/.dotsx/backups/$S/etc/b.conf.live."* | tail -1)" "local" "overwritten live edit backed up"

# remove by absolute path: a link becomes a real file again, a copy stays.
sandbox; sysdir
run init
printf 'L\n' >"$SYS/etc/l.conf"
printf 'C\n' >"$SYS/etc/c.conf"
run link "$SYS/etc/l.conf"
run copy "$SYS/etc/c.conf"
run remove "$SYS/etc/l.conf"
assert_rc 0 "remove a system link"
assert_eq "" "$(readlink "$SYS/etc/l.conf")" "no longer a symlink"
assert_file_is "$SYS/etc/l.conf" "L" "content moved back out of the store"
run remove "$SYS/etc/c.conf"
assert_rc 0 "remove a system copy"
assert_file_is "$SYS/etc/c.conf" "C" "plain copy left in place"
assert_eq 0 "$(grep -c . "$HOME/.dotsx/index.db")" "both entries dropped"
assert_missing "$HOME/.dotsx/store/$S/etc/c.conf" "store copy removed"

# remove accepts the exact db path shown by list, from any directory, and an
# absolute path to a home entry from a cwd outside $HOME.
sandbox; sysdir
run init
printf 'x\n' >"$SYS/etc/x.conf"
printf 'h\n' >h
run copy "$SYS/etc/x.conf"
run link h
cd "$HOME" || exit 1
run remove "$S/etc/x.conf"
assert_rc 0 "remove by the db path from an unrelated cwd"
cd "$SYS" || exit 1
run remove "$HOME/h"
cd "$HOME" || exit 1
assert_rc 0 "remove a home entry by absolute path from outside \$HOME"
assert_eq "" "$(readlink "$HOME/h")" "home entry restored to a real file"

# A linked directory outside $HOME round-trips.
sandbox; sysdir
run init
mkdir -p "$SYS/opt/tool"
printf 'cfg\n' >"$SYS/opt/tool/cfg"
run link "$SYS/opt/tool"
assert_match "$(db)" "d:l:" "recorded as a directory link"
assert_file_is "$SYS/opt/tool/cfg" "cfg" "readable through the link"
run remove "$SYS/opt/tool"
assert_eq "" "$(readlink "$SYS/opt/tool")" "directory restored"
assert_file_is "$SYS/opt/tool/cfg" "cfg" "contents preserved"

# Paths with spaces work inside and outside $HOME.
sandbox; sysdir
run init
printf 's\n' >"my file"
mkdir -p "$SYS/etc/with space"
printf 't\n' >"$SYS/etc/with space/a b.conf"
run link "my file"
run copy "$SYS/etc/with space/a b.conf"
rm -f "$HOME/my file" "$SYS/etc/with space/a b.conf"
run sync
assert_rc 0 "sync handles spaces"
assert_file_is "$HOME/my file" "s" "spaced home path restored"
assert_file_is "$SYS/etc/with space/a b.conf" "t" "spaced system path restored"

# ghost covers mirrored system paths: files under a tracked system directory are
# covered, a stray in the mirror is not.
sandbox; sysdir
run init
mkdir -p "$SYS/opt/tool"
printf 'c\n' >"$SYS/opt/tool/c"
run copy "$SYS/opt/tool" -r
printf 'stray\n' >"$HOME/.dotsx/store/$S/opt/stray"
run ghost
assert_match "$OUT" "$S/opt/stray" "stray system mirror file flagged"
case "$OUT" in
*opt/tool/c*) _fail "ghost flags a file under a tracked system dir" "$OUT" ;;
*) _pass ;;
esac

# Still refused: /, $HOME and other ancestors of ~/.dotsx, anything inside
# ~/.dotsx, and ".." anywhere in a target.
sandbox; sysdir
run init
printf 'a\n' >a
run link a /
assert_rc 1 "/ is not a target"
run copy a "$HOME" -r
assert_rc 1 "\$HOME (an ancestor of ~/.dotsx) is not a target"
assert_match "$OUT" "unsafe target" "explains the rejection"
run link "$HOME/.dotsx/index.db"
assert_rc 1 "a file inside ~/.dotsx is not a source"
run copy a "$HOME/.dotsx/store/x"
assert_rc 1 "a path inside ~/.dotsx is not a target"
run copy a "$SYS/etc/../escape"
assert_rc 1 ".. in an absolute target is rejected"
assert_missing "$SYS/escape" "nothing written for the .. target"
assert_eq 0 "$(grep -c . "$HOME/.dotsx/index.db")" "nothing recorded"

# A symlinked parent outside $HOME is refused like one inside it.
sandbox; sysdir
run init
EXT=$(mktemp -d)
ln -s "$EXT" "$SYS/lnk"
printf 'd\n' >d
run copy d "$SYS/lnk/x"
assert_rc 1 "symlinked parent outside \$HOME refused"
assert_missing "$EXT/x" "nothing written through it"
rm -rf "$EXT"

# Hand-edited db entries that are absolute or use .. are skipped by sync.
sandbox; sysdir
run init
printf 'f:l:644:/etc/passwd\nf:c:644:%s/../x\n' "$S" >>"$HOME/.dotsx/index.db"
run sync
assert_rc 1 "unsafe db entries are errors"
assert_match "$OUT" "unsafe path" "reported as unsafe"

# Without write permission (a system path without root, say), link/copy refuse
# before the store copy lands, so no ghost is left behind. An in-place copy
# never writes to the live location and still works.
if [ "$(id -u)" -ne 0 ]; then
	sandbox; sysdir
	run init
	mkdir "$SYS/ro"
	printf 'r\n' >"$SYS/ro/f"
	chmod 555 "$SYS/ro"
	run link "$SYS/ro/f"
	assert_rc 1 "link into an unwritable directory refused"
	assert_match "$OUT" "permission denied" "explains why"
	printf 'n\n' >n
	run copy n "$SYS/ro/new"
	assert_rc 1 "copy into an unwritable directory refused"
	run ghost
	assert_match "$OUT" "no ghost files" "no ghost left behind"
	run copy "$SYS/ro/f"
	assert_rc 0 "in-place copy of a read-only location works"
	# sync of an entry it cannot write is a counted, non-fatal error.
	chmod 755 "$SYS/ro"
	rm -f "$SYS/ro/f"
	chmod 555 "$SYS/ro"
	printf 'h\n' >h
	run copy h
	rm -f "$HOME/h"
	run sync
	assert_rc 1 "sync reports the unwritable entry"
	assert_file_is "$HOME/h" "h" "other entries still synced"
else
	skip "permission tests (running as root)"
fi

[ -n "$SYS" ] && { chmod -R u+w "$SYS" 2>/dev/null; rm -rf "$SYS"; }
report
