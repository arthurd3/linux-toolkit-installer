#!/usr/bin/env bats
# tests/test_sudo.bats — lib/sudo.sh: privilege state, group map, and the
# three sudo_bootstrap modes. The privileged script's in-place /etc/sudoers
# edit needs real root and is deferred to the user (project convention); here
# we assert its exact CONTENT in teach mode and the orchestration around `su`.

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# _sb <force-family> <env-assignments> <seam-defs> [mock...]
# Runs sudo_bootstrap with only the named mocks prepended to PATH and the
# given seam function definitions injected after sourcing the libs.
_sb() {
    local fam=$1 envs=$2 seams=$3; shift 3
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY="$fam" TMPBIN="$t" \
    LTI_TEST_CAPTURE=/dev/stdout env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        '"$seams"'
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        pm_init
        sudo_bootstrap "test" && _sb_rc=0 || _sb_rc=$?; echo "BOOTRC=$_sb_rc"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

_src() {  # source libs only, run an expression; no mocks, no pm_init
    LTI_ROOT="$LTI_ROOT" bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        '"$1"'
    ' 2>&1
}

@test "sudo_admin_group maps families" {
    [ "$(_src 'sudo_admin_group debian')" = sudo ]
    [ "$(_src 'sudo_admin_group suse')"   = sudo ]
    [ "$(_src 'sudo_admin_group fedora')" = wheel ]
    [ "$(_src 'sudo_admin_group arch')"   = wheel ]
    run _src 'sudo_admin_group zzz && echo SHOULDNOT'
    [[ "$output" != *SHOULDNOT* ]]
}

@test "sudo_privilege_state: root" {
    run _src '_sudo_is_root(){ return 0; }; sudo_privilege_state'
    [ "$output" = root ]
}

@test "sudo_privilege_state: missing" {
    run _src '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 1; }; sudo_privilege_state'
    [ "$output" = missing ]
}

@test "sudo_privilege_state: present" {
    run _src '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 0; }; sudo_privilege_state'
    [ "$output" = present ]
}

@test "teach (debian, missing): secure script, no NOPASSWD/sudoers.d" {
    run _sb debian DRY_RUN=1 '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 1; }; _sudo_user(){ echo tester; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"BOOTRC=0"* ]]
    [[ "$output" == *"env DEBIAN_FRONTEND=noninteractive apt-get install -y sudo"* ]]
    [[ "$output" == *"usermod -aG \"\$GROUP\" \"\$TARGET_USER\""* ]]
    [[ "$output" == *"visudo -cf"* ]]
    [[ "$output" == *"install -m 0440 -o root -g root"* ]]
    [[ "$output" == *"GROUP='sudo'"* ]]
    [[ "$output" == *"newgrp sudo"* ]]
    [[ "$output" != *NOPASSWD* ]]
    [[ "$output" != *"/etc/sudoers.d"* ]]
}

@test "teach (arch, missing): wheel group + pacman argv" {
    run _sb arch DRY_RUN=1 '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 1; }; _sudo_user(){ echo tester; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"pacman -S --needed --noconfirm sudo"* ]]
    [[ "$output" == *"GROUP='wheel'"* ]]
    [[ "$output" == *"newgrp wheel"* ]]
    [[ "$output" != *NOPASSWD* ]]
}

@test "auto (missing): invokes su root -c and reports success" {
    run _sb debian ASSUME_YES=1 '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 1; }; _sudo_user(){ echo tester; }' su usermod visudo install
    [ "$status" -eq 0 ]
    [[ "$output" == *"su root -c"* ]]
    [[ "$output" == *"sudo is set up for 'tester'"* ]]
    [[ "$output" == *"BOOTRC=0"* ]]
}

@test "auto (missing) with su failing: manual fallback, not fatal" {
    run _sb debian 'ASSUME_YES=1 LTI_MOCK_SU_RC=1' '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 1; }; _sudo_user(){ echo tester; }' su
    [ "$status" -eq 0 ]
    [[ "$output" == *"privileged step failed"* ]]
    [[ "$output" == *"usermod -aG"* ]]
    [[ "$output" == *"BOOTRC=1"* ]]
    [[ "$output" != *"FATAL:"* ]]
}

@test "auto (missing) with no su: manual fallback" {
    run _sb debian ASSUME_YES=1 '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 1; }; _sudo_have_su(){ return 1; }; _sudo_user(){ echo tester; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"'su' is not available"* ]]
    [[ "$output" == *"usermod -aG"* ]]
    [[ "$output" == *"BOOTRC=1"* ]]
}

@test "root: silent no-op rc 0" {
    run _sb debian '' '_sudo_is_root(){ return 0; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"BOOTRC=0"* ]]
    [[ "$output" != *"su root -c"* ]]
    [[ "$output" != *"usermod"* ]]
}

@test "present + teach: no install line, group config still shown" {
    run _sb arch DRY_RUN=1 '_sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 0; }; _sudo_user(){ echo tester; }; _sudo_user_groups(){ echo tester; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL_CMD=''"* ]]
    [[ "$output" == *"usermod -aG"* ]]
    [[ "$output" == *"BOOTRC=0"* ]]
}

@test "--list output stays free of bootstrap text" {
    run bash -c "cd '$LTI_ROOT' && ./install.sh --force-family debian --dry-run --list"
    [ "$status" -eq 0 ]
    [[ "$output" != *"su root -c"* ]]
    [[ "$output" != *"Set up sudo"* ]]
}
