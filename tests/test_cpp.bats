#!/usr/bin/env bats
# tests/test_cpp.bats — lib/cpp.sh: the pure package map, the _cpp_probe report
# rows, the read-only cpp_diagnose report, and the cpp_setup flow (teach mode,
# real mode with mocks, decline). Nothing real is installed: pm_* is dry-run or
# seam-overridden, and the compilers are mocks (tests/mocks/bin/*). rc is
# captured set-e-safely (lib/core.sh runs set -euo pipefail, so a plain
# `f; echo $?` would never print on non-zero).

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# Commands cpp_setup / cpp_diagnose / _cpp_verify may touch.
CMOCKS="gcc g++ cc c++ make cmake ninja gdb clang valgrind install sudo dnf"
# Seam pm_* so no package manager runs; pm_install echoes what it would install.
REAL_SEAMS='pm_require_privileges(){ :; }; pm_refresh(){ :; }; pm_install(){ echo "INSTALL $*"; }'

# _cs <env> <seams> <stdin> [mock...]  — interactive cpp_setup
_cs() {
    local envs=$1 seams=$2 input=$3; shift 3
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    printf '%s' "$input" | \
    LTI_ROOT="$LTI_ROOT" TMPBIN="$t" \
    env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        source "$LTI_ROOT/lib/cpp.sh"
        '"$seams"'
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        pm_init
        cpp_setup && _rc=0 || _rc=$?; echo "CPPRC=$_rc"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# _cd <env> <inner-path?> [mock...]  — read-only cpp_diagnose (no pm_init).
# <inner-path> = "keep" appends the real PATH (finds mocks + system tools);
# "only" restricts PATH to the mock dir (deterministic "missing" checks).
_cd() {
    local envs=$1 pathmode=$2; shift 2
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY=fedora TMPBIN="$t" PATHMODE="$pathmode" \
    env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        source "$LTI_ROOT/lib/cpp.sh"
        if [[ $PATHMODE == only ]]; then PATH="$TMPBIN"; else PATH="$TMPBIN:$PATH"; fi
        detect_distro_family
        cpp_diagnose && _rc=0 || _rc=$?; echo "CPPRC=$_rc"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# _src <env> <expr> [mock...]  — pure helpers
_src() {
    local envs=$1 expr=$2; shift 2
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY=debian DRY_RUN=1 TMPBIN="$t" \
    env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        source "$LTI_ROOT/lib/cpp.sh"
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        '"$expr"'
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# --- pure helpers -----------------------------------------------------------

@test "_cpp_pkgs: essential compilers present per family" {
    [[ "$(_src '' '_cpp_pkgs debian')" == *"build-essential"*"gdb"*"valgrind"* ]]
    [[ "$(_src '' '_cpp_pkgs fedora')" == *"gcc-c++"*"cmake"*"clang-tools-extra"* ]]
    [[ "$(_src '' '_cpp_pkgs arch')"   == *"base-devel"*"clang"* ]]
    [[ "$(_src '' '_cpp_pkgs suse')"   == *"gcc-c++"*"valgrind"* ]]
}

@test "_cpp_pkgs: unknown family -> non-zero, no output" {
    run _src '' '_cpp_pkgs martian && echo GOT || echo RC=$?'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]]
    [[ "$output" != *"GOT"* ]]
}

@test "_cpp_probe: present command -> [OK] with version" {
    run _src '' '_cpp_probe "cc" gcc' gcc
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"* ]]
    [[ "$output" == *"16.1.1"* ]]
}

@test "_cpp_probe: absent command -> [FAIL], returns non-zero" {
    run _src '' '_cpp_probe "x" definitely_no_such_tool_xyz && echo Y || echo RC=$?'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL]"* ]]
    [[ "$output" == *"not found"* ]]
    [[ "$output" == *"RC=1"* ]]
}

# --- cpp_diagnose (read-only) -----------------------------------------------

@test "diagnose: full toolchain present -> all OK, rc 0" {
    run _cd '' keep gcc g++ make cmake ninja gdb clang valgrind
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"* ]]
    [[ "$output" == *"looks complete"* ]]
    [[ "$output" == *"CPPRC=0"* ]]
}

@test "diagnose: nothing installed -> items missing, rc 1" {
    # PATH restricted to an empty mock dir so no system compiler is found.
    run _cd '' only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL]"* ]]
    [[ "$output" == *"item(s) missing"* ]]
    [[ "$output" == *"CPPRC=1"* ]]
}

# --- teach mode (DRY_RUN): install is printed, nothing runs, no verify -------

@test "teach mode (fedora): prints the dnf install with the toolchain packages" {
    local cap; cap="$(mktemp)"
    run _cs "DRY_RUN=1 LTI_FORCE_FAMILY=fedora LTI_TEST_CAPTURE=$cap" '' '' $CMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"CPPRC=0"* ]]
    [[ "$output" == *"install -y"*"gcc"*"gcc-c++"*"cmake"* ]]
    # Nothing mutating ran, and the compile verify is skipped under --dry-run.
    [[ "$output" != *"compiles and links"* ]]
    rm -f "$cap"
}

@test "teach mode (debian): package set uses build-essential" {
    run _cs "DRY_RUN=1 LTI_FORCE_FAMILY=debian" '' '' $CMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"build-essential"* ]]
    [[ "$output" == *"CPPRC=0"* ]]
}

# --- real mode with mocks: install the batch, then verify it compiles --------

@test "real mode (fedora): installs the batch, compiles + links C and C++" {
    run _cs "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_TEST_CAPTURE=/dev/stdout" \
        "$REAL_SEAMS" $'y\n' $CMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL gcc gcc-c++ make"* ]]
    [[ "$output" == *"C compiles and links"* ]]
    [[ "$output" == *"C++ compiles and links"* ]]
    [[ "$output" == *"CPPRC=0"* ]]
}

@test "real mode: decline -> nothing installed, returns 0" {
    local cap; cap="$(mktemp)"
    run _cs "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_TEST_CAPTURE=$cap" \
        "$REAL_SEAMS" $'n\n' $CMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"CPPRC=0"* ]]
    [[ "$output" != *"INSTALL"* ]]
    [[ "$output" != *"compiles and links"* ]]
    rm -f "$cap"
}
