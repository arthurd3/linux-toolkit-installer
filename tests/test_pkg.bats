#!/usr/bin/env bats
# Unit tests for lib/pkg.sh — exact command construction (dry-run) and
# pm_is_installed against mocked package managers. Nothing real is installed.

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# Dry-run a pkg action for a forced family; echoes the printed command lines.
_dry() {
    local family=$1; shift
    LTI_FORCE_FAMILY="$family" DRY_RUN=1 bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        source "'"$LTI_ROOT"'/lib/pkg.sh"
        detect_distro_family
        pm_init
        '"$*"'
    ' 2>/dev/null
}

@test "pm_install argv — debian" {
    run _dry debian 'pm_install foo bar'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y foo bar"* ]]
}

@test "pm_install argv — fedora" {
    run _dry fedora 'pm_install foo bar'
    [[ "$output" == *"[dry-run] sudo dnf install -y foo bar"* ]]
}

@test "pm_install argv — arch" {
    run _dry arch 'pm_install foo bar'
    [[ "$output" == *"[dry-run] sudo pacman -S --needed --noconfirm foo bar"* ]]
}

@test "pm_install argv — suse" {
    run _dry suse 'pm_install foo bar'
    [[ "$output" == *"[dry-run] sudo zypper --non-interactive install foo bar"* ]]
}

@test "pm_refresh argv — debian" {
    run _dry debian 'pm_refresh'
    [[ "$output" == *"[dry-run] sudo apt-get update"* ]]
}

@test "pm_refresh argv — arch" {
    run _dry arch 'pm_refresh'
    [[ "$output" == *"[dry-run] sudo pacman -Sy --noconfirm"* ]]
}

@test "pm_install no-op with zero args" {
    run _dry debian 'pm_install; echo RC=$?'
    [[ "$output" == *"RC=0"* ]]
    [[ "$output" != *"apt-get install"* ]]
}

# --- pm_is_installed against mocked PMs --------------------------------------
_is_installed() {
    local family=$1 pkg=$2
    PATH="$LTI_ROOT/tests/mocks/bin:$PATH" LTI_FORCE_FAMILY="$family" bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        source "'"$LTI_ROOT"'/lib/pkg.sh"
        detect_distro_family
        pm_init
        if pm_is_installed "'"$pkg"'"; then echo INSTALLED; else echo MISSING; fi
    '
}

@test "pm_is_installed debian present/absent (dpkg-query mock)" {
    run _is_installed debian present-pkg
    [ "$output" = "INSTALLED" ]
    run _is_installed debian absent-pkg
    [ "$output" = "MISSING" ]
}

@test "pm_is_installed fedora present/absent (rpm mock)" {
    run _is_installed fedora present-pkg
    [ "$output" = "INSTALLED" ]
    run _is_installed fedora absent-pkg
    [ "$output" = "MISSING" ]
}

@test "pm_is_installed arch present/absent (pacman mock)" {
    run _is_installed arch present-pkg
    [ "$output" = "INSTALLED" ]
    run _is_installed arch absent-pkg
    [ "$output" = "MISSING" ]
}
