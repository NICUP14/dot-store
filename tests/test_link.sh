#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="link"

# Link a file: store gets the content, home gets a symlink into the store.
sandbox
run init
printf 'A=1\n' >.bashrc
run link .bashrc bashrc
assert_rc 0 "link returns 0"
assert_symlink "$HOME/bashrc" "home target is a symlink"
assert_link_to "$HOME/bashrc" "$HOME/.dotsx/store/bashrc" "symlink points into the store"
assert_file_is "$HOME/.dotsx/store/bashrc" "A=1" "store holds the content"
assert_match "$(cat "$HOME/.dotsx/index.db")" "f:l:" "recorded as a file link"

# Re-linking the same target must not create a duplicate DB entry.
sandbox
run init
printf 'x\n' >f
run link f cfg
run link f cfg
n=$(grep -c . "$HOME/.dotsx/index.db")
assert_eq 1 "$n" "re-link does not duplicate the db entry"

# Default target tracks the source where it lives under ~/ (in place), not
# flattened to ~/<basename>.
sandbox
run init
mkdir sub
printf 'y\n' >sub/thing
run link sub/thing
assert_symlink "$HOME/sub/thing" "default target tracks the source in place"
assert_missing "$HOME/thing" "not flattened to the basename under ~/"
assert_match "$(cat "$HOME/.dotsx/index.db")" "f:l:644:sub/thing" "db records the home-relative path"

# Trailing slash on the target is normalized away.
sandbox
run init
printf 'z\n' >z
run link z cfg/
assert_symlink "$HOME/cfg" "trailing slash on target normalized"

# Linking a file in place (source == home target): backed into store, replaced.
sandbox
run init
printf 'B\n' >.bashrc
run link .bashrc
assert_rc 0 "link a file in place returns 0"
assert_symlink "$HOME/.bashrc" "original replaced by a symlink"
assert_file_is "$HOME/.dotsx/store/.bashrc" "B" "content backed into the store"

# A relative source run from a subdirectory is tracked at its real location
# under ~/ (the reported bug: ./x was being flattened to ~/x).
sandbox
run init
mkdir -p projects/app
printf 'cfg\n' >projects/app/conf
cd projects/app || exit 1
run link ./conf
cd "$HOME" || exit 1
assert_rc 0 "link ./conf from a subdir returns 0"
assert_symlink "$HOME/projects/app/conf" "relative source tracked in place"
assert_missing "$HOME/conf" "not flattened to the basename under ~/"
assert_match "$(cat "$HOME/.dotsx/index.db")" "projects/app/conf" "db path is home-relative"

# An explicit target under a directory that does not exist yet under ~/: link
# must create the parent itself. Regression -- the bare `ln -s` used to fail
# after store_first had already copied into the store, aborting before db_set
# and leaving an untracked store file (a ghost) behind.
sandbox
run init
mkdir src
printf 'v\n' >src/two
run link src/two nested/deep/two.conf
assert_rc 0 "link creates a missing home parent directory"
assert_symlink "$HOME/nested/deep/two.conf" "symlink placed under the new parent"
assert_link_to "$HOME/nested/deep/two.conf" "$HOME/.dotsx/store/nested/deep/two.conf" \
	"symlink points into the store"
assert_match "$(cat "$HOME/.dotsx/index.db")" "f:l:644:nested/deep/two.conf" "db entry recorded"
run ghost
assert_match "$OUT" "no ghost files" "no ghost left behind"

# Linking a directory records type d and stores the tree.
sandbox
run init
mkdir cfgdir
printf 'i\n' >cfgdir/f
run link cfgdir
assert_rc 0 "link a directory returns 0"
assert_symlink "$HOME/cfgdir" "directory replaced by a symlink"
assert_file_is "$HOME/.dotsx/store/cfgdir/f" "i" "directory contents in the store"
assert_match "$(cat "$HOME/.dotsx/index.db")" "d:l:" "recorded as a directory link"

report
