#!/usr/bin/env bats
# tests/test_state.bats — lib/state.sh: path resolution, first-run detection,
# atomic persist, --dry-run no-op, and tolerant load. Never touches the real
# $HOME — every case points LTI_STATE_FILE / XDG_STATE_HOME at a temp dir.

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TDIR"
}

# _st "<VAR=val ...>" '<expr>' : source core+state from the real repo, apply
# the given env, run the expression; stdout+stderr merged; exits expr status.
_st() {
    LTI_ROOT="$LTI_ROOT" env $1 bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/state.sh"
        '"$2"'
    ' 2>&1
}

@test "state_path honors LTI_STATE_FILE" {
    run _st "LTI_STATE_FILE=$TDIR/s" 'state_path'
    [ "$status" -eq 0 ]
    [ "$output" = "$TDIR/s" ]
}

@test "state_path falls back to XDG_STATE_HOME" {
    run _st "XDG_STATE_HOME=$TDIR/xdg" 'state_path'
    [ "$output" = "$TDIR/xdg/linux-toolkit-installer/state" ]
}

@test "state_is_first_run true when file absent" {
    run _st "LTI_STATE_FILE=$TDIR/none" 'state_load; if state_is_first_run; then echo FIRST; else echo NOT; fi'
    [ "$status" -eq 0 ]
    [[ "$output" == *FIRST* ]]
}

@test "state_persist writes a 0600 file with the keys; not first-run after" {
    run _st "LTI_STATE_FILE=$TDIR/s" '
        state_set schema 1
        state_set first_run_done 1
        state_set distro_family debian
        if state_persist; then echo SAVED; else echo SAVEFAIL; fi
        echo "MODE=$(stat -c %a "$LTI_STATE_FILE")"
        cat "$LTI_STATE_FILE"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *SAVED* ]]
    [[ "$output" == *"MODE=600"* ]]
    [[ "$output" == *"first_run_done=1"* ]]
    [[ "$output" == *"distro_family=debian"* ]]
    run _st "LTI_STATE_FILE=$TDIR/s" 'state_load; if state_is_first_run; then echo FIRST; else echo NOT; fi'
    [[ "$output" == *NOT* ]]
}

@test "state_persist is a no-op under DRY_RUN=1 (no file created)" {
    run _st "LTI_STATE_FILE=$TDIR/dry DRY_RUN=1" '
        state_set first_run_done 1
        if state_persist; then echo RC0; else echo RC1; fi
        if [ -e "$LTI_STATE_FILE" ]; then echo EXISTS; else echo ABSENT; fi
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *RC0* ]]
    [[ "$output" == *ABSENT* ]]
}

@test "state_load ignores comments and malformed lines; round-trips values" {
    printf '%s\n' '# a comment' 'garbage_no_equals' 'distro_family=arch' '' 'pm_bin=pacman' > "$TDIR/s"
    run _st "LTI_STATE_FILE=$TDIR/s" '
        state_load
        echo "fam=$(state_get distro_family) bin=$(state_get pm_bin) miss=$(state_get nope)"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"fam=arch bin=pacman miss="* ]]
}

@test "first_seen preserved across persists; last_seen changes" {
    _st "LTI_STATE_FILE=$TDIR/s" '
        state_set first_seen 2026-01-01T00:00:00Z
        state_set last_seen  2026-01-01T00:00:00Z
        state_persist'
    run _st "LTI_STATE_FILE=$TDIR/s" '
        state_load
        if [ -z "$(state_get first_seen)" ]; then state_set first_seen NEW; fi
        state_set last_seen 2026-02-02T00:00:00Z
        state_persist
        state_load
        echo "first=$(state_get first_seen) last=$(state_get last_seen)"
    '
    [[ "$output" == *"first=2026-01-01T00:00:00Z last=2026-02-02T00:00:00Z"* ]]
}
