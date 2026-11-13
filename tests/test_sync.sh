#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="sync"

# A deleted symlink is recreated.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
rm -f "$HOME/bashrc"
run sync
assert_rc 0 "sync returns 0"
assert_symlink "$HOME/bashrc" "broken symlink restored"

# A tampered copy is restored from the store.
sandbox
run init
mkdir -p c/n
printf 'orig\n' >c/n/i
run copy c/n nv -r
printf 'bad\n' >"$HOME/nv/i"
run sync
assert_file_is "$HOME/nv/i" "orig" "tampered copy restored"

# A real directory where a link belongs is never deleted by sync.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
rm -f "$HOME/bashrc"
mkdir "$HOME/bashrc"
printf 'precious\n' >"$HOME/bashrc/d"
run sync
assert_rc 1 "sync reports an error when a real dir blocks a link"
assert_file_is "$HOME/bashrc/d" "precious" "real directory not deleted"
assert_match "$OUT" "repair" "points the user at repair"

# A clean tree is a no-op.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
run sync
assert_match "$OUT" "0 files updated" "clean sync changes nothing"

# A missing store source is a non-fatal corruption error.
sandbox
run init
printf 'A\n' >.bashrc
run link .bashrc bashrc
printf '%s\n' "f:l:644:$R/ghost" >>"$HOME/.dotsx/index.db"
run sync
assert_rc 1 "missing source is a non-fatal error"
assert_match "$OUT" "source missing" "reports the corruption"

# Restoring a cloned store onto a fresh machine: link entries whose home parent
# directories do not exist yet must be created. Regression -- relink called a
# bare `ln -s`, so every `l` entry under a not-yet-existing directory failed
# while `c` entries succeeded (deploy_copy makes its own parents).
sandbox
run init
mkdir -p "$ST/.config/nvim" "$ST/.config/fish"
printf 'set nu\n' >"$ST/.config/nvim/init.vim"
printf 'x\n' >"$ST/.config/fish/config.fish"
printf '%s\n' "f:l:644:$R/.config/nvim/init.vim" >>"$HOME/.dotsx/index.db"
printf '%s\n' "f:c:644:$R/.config/fish/config.fish" >>"$HOME/.dotsx/index.db"
assert_missing "$HOME/.config" "home parent does not exist before sync"
run sync
assert_rc 0 "sync restores a clone with no pre-existing home tree"
assert_symlink "$HOME/.config/nvim/init.vim" "link entry deployed under a created parent"
assert_link_to "$HOME/.config/nvim/init.vim" "$ST/.config/nvim/init.vim" \
	"restored link points into the store"
assert_file_is "$HOME/.config/fish/config.fish" "x" "copy entry deployed too"
assert_match "$OUT" "2 files updated" "both entries counted"

# repair restores the same missing-parent case (it shares relink with sync).
sandbox
run init
mkdir -p "$ST/.config/nvim"
printf 'set nu\n' >"$ST/.config/nvim/init.vim"
printf '%s\n' "f:l:644:$R/.config/nvim/init.vim" >>"$HOME/.dotsx/index.db"
run repair
assert_rc 0 "repair restores a link under a missing parent"
assert_symlink "$HOME/.config/nvim/init.vim" "repair created the parent directory"
assert_match "$OUT" "0 errors found" "repair reports no errors"

# One entry needing several fixes (content + mode) is counted once, not per fix.
sandbox
run init
printf 'data\n' >cfg
chmod 644 cfg
run copy cfg cfg
chmod 600 "$ST/cfg"   # store mode drift (recorded 644)
printf 'edited\n' >"$HOME/cfg"       # home content drift
run sync
assert_rc 0 "sync returns 0"
assert_match "$OUT" "1 files updated" "an entry needing several fixes counts once"
assert_file_is "$HOME/cfg" "data" "home content restored from store"
assert_mode "$ST/cfg" 644 "store mode restored"

report
