#!/usr/bin/env bats
# tests/test_rust.bats — lib/rust.sh: the pure package map, the _rust_probe
# rows, the read-only rust_diagnose report, and the rust_setup flow (teach mode,
# real mode installing the distro rustup package, the official-script fallback,
# and decline). Nothing real is installed: pm_* is seam-overridden and rustup/
# cargo/rustc are mocks (tests/mocks/bin/*). The install seam symlinks the rustup
# mock into place, mirroring "installing the package makes rustup appear". rc is
# captured set-e-safely (lib/core.sh runs set -euo pipefail).

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# Every rust command; the mock rustup is always present so the toolchain steps
# run against it, never a real rustup on the box.
RMOCKS="rustup rustc cargo rustup-init curl rustfmt cargo-clippy rust-analyzer gcc cc sudo dnf id getent install"

# Force the rustup *gate* to report absent (so setup takes the install branch)
# without hiding the mock rustup that _rust_bin runs — mirrors sudo.sh's
# overridable probes. All other tools resolve normally (the mocks in TMPBIN).
RUST_ABSENT='_rust_has(){ case "$1" in rustup) return 1;; *) command -v "$1" >/dev/null 2>&1;; esac; }'
# Install seam: echo what would be installed (idempotently re-link the mock).
REAL_SEAMS='pm_require_privileges(){ :; }; pm_refresh(){ :; }; pm_install(){ echo "INSTALL $*"; for a in "$@"; do if [ "$a" = rustup ]; then ln -sf "$LTI_ROOT/tests/mocks/bin/rustup" "$TMPBIN/rustup"; fi; done; }'
# Fallback seam: the distro package "fails", so the official installer runs.
FALLBACK_SEAMS='pm_require_privileges(){ :; }; pm_refresh(){ :; }; pm_install(){ echo "INSTALL $*"; return 1; }; _rust_install_via_script(){ echo "SCRIPT-FALLBACK"; ln -sf "$LTI_ROOT/tests/mocks/bin/rustup" "$TMPBIN/rustup"; }'

# _rs <env> <seams> <stdin> [mock...]  — interactive rust_setup
_rs() {
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
        source "$LTI_ROOT/lib/rust.sh"
        '"$seams"'
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        pm_init
        rust_setup && _rc=0 || _rc=$?; echo "RUSTRC=$_rc"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# _rd <env> <pathmode> [mock...]  — read-only rust_diagnose (no pm_init).
# pathmode "keep" appends the real PATH; "only" restricts to the mock dir.
_rd() {
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
        source "$LTI_ROOT/lib/rust.sh"
        if [[ $PATHMODE == only ]]; then PATH="$TMPBIN"; else PATH="$TMPBIN:$PATH"; fi
        detect_distro_family
        rust_diagnose && _rc=0 || _rc=$?; echo "RUSTRC=$_rc"
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
        source "$LTI_ROOT/lib/rust.sh"
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        '"$expr"'
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# --- pure helpers -----------------------------------------------------------

@test "_rust_pkg: rustup on every family" {
    [ "$(_src '' '_rust_pkg debian')" = "rustup" ]
    [ "$(_src '' '_rust_pkg fedora')" = "rustup" ]
    [ "$(_src '' '_rust_pkg arch')"   = "rustup" ]
    [ "$(_src '' '_rust_pkg suse')"   = "rustup" ]
}

@test "_rust_pkg: unknown family -> non-zero, no output" {
    run _src '' '_rust_pkg martian && echo GOT || echo RC=$?'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]]
    [[ "$output" != *"GOT"* ]]
}

@test "_rust_probe: present command -> [OK] with version" {
    run _src '' '_rust_probe "rustup" rustup' rustup
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"* ]]
    [[ "$output" == *"rustup 1.27"* ]]
}

@test "_rust_probe: absent command -> [FAIL], returns non-zero" {
    run _src '' '_rust_probe "x" definitely_no_such_tool_xyz && echo Y || echo RC=$?'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL]"* ]]
    [[ "$output" == *"RC=1"* ]]
}

# --- rust_diagnose (read-only) ----------------------------------------------

@test "diagnose: full toolchain present -> all OK, rc 0" {
    run _rd '' keep rustup rustc cargo cargo-clippy rustfmt rust-analyzer gcc
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"* ]]
    [[ "$output" == *"looks complete"* ]]
    [[ "$output" == *"RUSTRC=0"* ]]
}

@test "diagnose: nothing installed -> items missing + linker warning, rc 1" {
    run _rd '' only
    [ "$status" -eq 0 ]
    [[ "$output" == *"[FAIL]"* ]]
    [[ "$output" == *"Rust needs it to link"* ]]
    [[ "$output" == *"item(s) missing"* ]]
    [[ "$output" == *"RUSTRC=1"* ]]
}

# --- teach mode (DRY_RUN): the install + toolchain steps are printed only -----

@test "teach mode (fedora): prints rustup install, default stable, components" {
    run _rs "DRY_RUN=1 LTI_FORCE_FAMILY=fedora" "$RUST_ABSENT" '' $RMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"RUSTRC=0"* ]]
    [[ "$output" == *"install -y rustup"* ]]
    [[ "$output" == *"rustup default stable"* ]]
    [[ "$output" == *"rustup component add rust-analyzer rust-src"* ]]
    # The build verify is skipped under --dry-run.
    [[ "$output" != *"cargo build works"* ]]
}

# --- real mode with mocks: install the package, then set up the toolchain -----

@test "real mode (fedora): installs rustup pkg, defaults stable, adds components, builds" {
    run _rs "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_TEST_CAPTURE=/dev/stdout" \
        "$RUST_ABSENT; $REAL_SEAMS" $'y\n' $RMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL rustup"* ]]
    [[ "$output" == *"rustup default stable"* ]]
    [[ "$output" == *"rustup component add rust-analyzer rust-src"* ]]
    [[ "$output" == *"cargo build works"* ]]
    [[ "$output" == *"RUSTRC=0"* ]]
}

@test "real mode: distro package unavailable -> official-script fallback runs" {
    run _rs "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_TEST_CAPTURE=/dev/stdout" \
        "$RUST_ABSENT; $FALLBACK_SEAMS" $'y\n' $RMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL rustup"* ]]
    [[ "$output" == *"SCRIPT-FALLBACK"* ]]
    [[ "$output" == *"rustup default stable"* ]]
    [[ "$output" == *"RUSTRC=0"* ]]
}

@test "real mode: decline -> nothing installed, returns 0" {
    local cap; cap="$(mktemp)"
    run _rs "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_TEST_CAPTURE=$cap" \
        "$RUST_ABSENT; $REAL_SEAMS" $'n\n' $RMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"RUSTRC=0"* ]]
    [[ "$output" != *"INSTALL rustup"* ]]
    [[ "$output" != *"cargo build works"* ]]
    rm -f "$cap"
}
