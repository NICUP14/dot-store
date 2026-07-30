#!/bin/sh
. "$(dirname "$0")/test_lib.sh"
SUITE="init"

# Creates the store and the database, and announces it.
sandbox
run init
assert_rc 0 "init returns 0"
assert_exists "$HOME/.dotsx/store" "store directory created"
assert_exists "$HOME/.dotsx/backups" "backups directory created"
assert_exists "$HOME/.dotsx/index.db" "database created"
assert_match "$OUT" "Initialized" "prints Initialized"

# Idempotent, and never blanks an existing database.
sandbox
run init
printf 'f:l:644:bashrc\n' >"$HOME/.dotsx/index.db"
run init
assert_rc 0 "second init returns 0"
assert_file_is "$HOME/.dotsx/index.db" "f:l:644:bashrc" "existing db left intact"

report
