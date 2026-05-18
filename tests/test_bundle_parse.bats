#!/usr/bin/env bats
# Unit tests for lib/bundle.sh — parsing & per-family resolution (pure logic).

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SAMPLE="$LTI_ROOT/tests/fixtures/sample.bundle"
}

# Resolve one mapping line from the sample bundle for a given family.
_resolve() {
    local family=$1 idmatch=$2
    bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        line=$(grep -E "^'"$idmatch"' " "'"$SAMPLE"'")
        if out=$(bundle_resolve "'"$family"'" "$line"); then rc=0; else rc=$?; fi
        printf "%s rc=%s\n" "$out" "$rc"
    '
}

@test "normal resolves on debian" {
    run _resolve debian normal
    [ "$output" = "normal|native|nrm-deb rc=0" ]
}

@test "multi splits + into space list" {
    run _resolve debian multi
    [ "$output" = "multi|native|a b rc=0" ]
}

@test "dashskip: debian=- -> no mapping (rc1)" {
    run _resolve debian dashskip
    [ "$output" = "dashskip|none| rc=1" ]
}

@test "dashskip: fedora has the only package" {
    run _resolve fedora dashskip
    [ "$output" = "dashskip|native|fed-only rc=0" ]
}

@test "omitskip: omitted family -> no mapping (rc1)" {
    run _resolve debian omitskip
    [ "$output" = "omitskip|none| rc=1" ]
}

@test "omitskip: present family resolves" {
    run _resolve fedora omitskip
    [ "$output" = "omitskip|native|onlyfed rc=0" ]
}

@test "auronly: arch -> aur kind" {
    run _resolve arch auronly
    [ "$output" = "auronly|aur|aurpkg rc=0" ]
}

@test "auronly: debian -> no mapping (rc1)" {
    run _resolve debian auronly
    [ "$output" = "auronly|none| rc=1" ]
}

@test "malformed line -> rc2 bad" {
    run bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        if out=$(bundle_resolve debian "this_is_garbage_no_pipe"); then rc=0; else rc=$?; fi
        printf "%s rc=%s\n" "$out" "$rc"
    '
    [ "$output" = "this_is_garbage_no_pipe|bad| rc=2" ]
}

@test "bundle_header extracts name and description" {
    run bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        bundle_header "'"$SAMPLE"'"
    '
    [ "$output" = "Sample|covers parser edge cases" ]
}

@test "bundle_run (dry-run, debian) skips dash/omit/aur, does not abort" {
    run bash -c '
        LTI_FORCE_FAMILY=debian DRY_RUN=1 ASSUME_YES=1
        export LTI_FORCE_FAMILY DRY_RUN ASSUME_YES
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        source "'"$LTI_ROOT"'/lib/pkg.sh"
        source "'"$LTI_ROOT"'/lib/aur.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        detect_distro_family; pm_init
        bundle_run "'"$SAMPLE"'"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-pkg"*"dashskip"* ]]
    [[ "$output" == *"omitskip"* ]]
    [[ "$output" == *"auronly"* ]]
    [[ "$output" == *"Summary: Sample"* ]]
}

@test "bundle_count and tool_count over a controlled bundles dir" {
    run bash -c '
        tmp=$(mktemp -d); mkdir "$tmp/bundles"
        cp "'"$SAMPLE"'" "$tmp/bundles/one.bundle"
        export LTI_ROOT="$tmp"
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        printf "%s|%s\n" "$(bundle_count)" "$(tool_count)"
        rm -rf "$tmp"
    '
    [ "$output" = "1|6" ]
}

@test "bundle_count and tool_count are 0 for an empty bundles dir" {
    run bash -c '
        tmp=$(mktemp -d); mkdir "$tmp/bundles"
        export LTI_ROOT="$tmp"
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        printf "%s|%s\n" "$(bundle_count)" "$(tool_count)"
        rm -rf "$tmp"
    '
    [ "$output" = "0|0" ]
}
