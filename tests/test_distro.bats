#!/usr/bin/env bats
# Unit tests for lib/distro.sh — distro family detection.
# Run via: bats tests/test_distro.bats   (or: make test)

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    MOCKS="$LTI_ROOT/tests/mocks/os-release"
}

# Detect family from a given os-release fixture path.
_detect() {
    OS_RELEASE_PATH="$1" bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        detect_distro_family
        printf "%s|%s\n" "$DISTRO_ID" "$DISTRO_FAMILY"
    '
}

@test "ubuntu -> debian (via ID)" {
    run _detect "$MOCKS/ubuntu"
    [ "$status" -eq 0 ]
    [ "$output" = "ubuntu|debian" ]
}

@test "debian -> debian" {
    run _detect "$MOCKS/debian"
    [ "$status" -eq 0 ]
    [ "$output" = "debian|debian" ]
}

@test "fedora -> fedora" {
    run _detect "$MOCKS/fedora"
    [ "$status" -eq 0 ]
    [ "$output" = "fedora|fedora" ]
}

@test "arch -> arch" {
    run _detect "$MOCKS/arch"
    [ "$status" -eq 0 ]
    [ "$output" = "arch|arch" ]
}

@test "opensuse-leap -> suse (via ID, quoted value)" {
    run _detect "$MOCKS/opensuse"
    [ "$status" -eq 0 ]
    [ "$output" = "opensuse-leap|suse" ]
}

@test "unknown id -> unknown" {
    run _detect "$MOCKS/unknown"
    [ "$status" -eq 0 ]
    [ "$output" = "plan9|unknown" ]
}

@test "missing os-release file -> unknown" {
    run _detect "$MOCKS/does-not-exist"
    [ "$status" -eq 0 ]
    [ "$output" = "|unknown" ]
}

@test "LTI_FORCE_FAMILY overrides detection" {
    run bash -c '
        LTI_FORCE_FAMILY=fedora
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        detect_distro_family
        printf "%s|%s\n" "$DISTRO_ID" "$DISTRO_FAMILY"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "forced:fedora|fedora" ]
}

@test "invalid LTI_FORCE_FAMILY is fatal (exit 2)" {
    run bash -c '
        LTI_FORCE_FAMILY=gentoo
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        detect_distro_family
    '
    [ "$status" -eq 2 ]
}

# Detect family + pretty name from a given os-release fixture path.
_detect3() {
    OS_RELEASE_PATH="$1" bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        detect_distro_family
        printf "%s|%s|%s\n" "$DISTRO_ID" "$DISTRO_FAMILY" "$DISTRO_PRETTY"
    '
}

@test "DISTRO_PRETTY from PRETTY_NAME (ubuntu)" {
    run _detect3 "$MOCKS/ubuntu"
    [ "$status" -eq 0 ]
    [ "$output" = "ubuntu|debian|Ubuntu 24.04 LTS" ]
}

@test "DISTRO_PRETTY falls back to NAME + VERSION_ID" {
    run _detect3 "$MOCKS/nopretty"
    [ "$status" -eq 0 ]
    [ "$output" = "debian|debian|Frobnix 9" ]
}

@test "DISTRO_PRETTY for forced family is the forced id" {
    run bash -c '
        LTI_FORCE_FAMILY=fedora
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        detect_distro_family
        printf "%s|%s|%s\n" "$DISTRO_ID" "$DISTRO_FAMILY" "$DISTRO_PRETTY"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "forced:fedora|fedora|forced:fedora" ]
}

@test "DISTRO_PRETTY is 'unknown' when os-release missing" {
    run _detect3 "$MOCKS/does-not-exist"
    [ "$status" -eq 0 ]
    [ "$output" = "|unknown|unknown" ]
}
