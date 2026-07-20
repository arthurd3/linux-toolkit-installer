#!/usr/bin/env bats
# tests/test_docker.bats — lib/docker.sh: the pure helpers, the read-only
# docker_diagnose health report, and the interactive docker_setup flow (teach
# mode, real mode with mocks, the three group states, Podman-shim detection,
# and early-cancel). Nothing real is installed, enabled, or written: every
# command is mocked (tests/mocks/bin/*), config writes go through the mocked
# install(1), and pm_* is dry-run or seam-overridden.
#
# docker_setup now runs docker_diagnose first, so real-mode/teach tests symlink
# the read-only probe mocks too (getent/id/lsmod/runc/...). Space-containing
# mock vars (LTI_MOCK_GROUPS/GROUPS_USER/MODULES/DOCKER_VERSION) are forwarded
# directly (not through `env $envs`) so their spaces survive, like the disk
# suite does with LTI_MOCK_LSBLK. rc is captured set-e-safely (lib/core.sh runs
# set -euo pipefail, so a plain `f; echo $?` would never print on non-zero).

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# Every command docker_setup / docker_diagnose may touch.
DMOCKS="systemctl sysctl docker modprobe install usermod sudo dnf getent groupadd lsmod id runc"
# Seam pm_* so no package manager runs; other commands hit the mocks.
REAL_SEAMS='pm_require_privileges(){ :; }; pm_refresh(){ :; }; pm_install(){ echo "INSTALL $*"; }'

# _ds <env-assignments> <seam-defs> <stdin> [mock...]  — interactive docker_setup
_ds() {
    local envs=$1 seams=$2 input=$3; shift 3
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    printf '%s' "$input" | \
    LTI_ROOT="$LTI_ROOT" TMPBIN="$t" \
    LTI_MOCK_GROUPS="${LTI_MOCK_GROUPS:-}" LTI_MOCK_GROUPS_USER="${LTI_MOCK_GROUPS_USER:-}" \
    LTI_MOCK_MODULES="${LTI_MOCK_MODULES:-}" LTI_MOCK_DOCKER_VERSION="${LTI_MOCK_DOCKER_VERSION:-}" \
    env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        source "$LTI_ROOT/lib/docker.sh"
        '"$seams"'
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        pm_init
        docker_setup && _ds_rc=0 || _ds_rc=$?; echo "DSRC=$_ds_rc"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# _dg <env-assignments> [mock...]  — read-only docker_diagnose (no pm_init)
_dg() {
    local envs=$1; shift
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY=fedora TMPBIN="$t" \
    LTI_MOCK_GROUPS="${LTI_MOCK_GROUPS:-}" LTI_MOCK_GROUPS_USER="${LTI_MOCK_GROUPS_USER:-}" \
    LTI_MOCK_MODULES="${LTI_MOCK_MODULES:-}" LTI_MOCK_DOCKER_VERSION="${LTI_MOCK_DOCKER_VERSION:-}" \
    env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        source "$LTI_ROOT/lib/docker.sh"
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        docker_diagnose && _dg_rc=0 || _dg_rc=$?; echo "DGRC=$_dg_rc"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# _src <env-assignments> <expr> [mock...]  — pure helpers
_src() {
    local envs=$1 expr=$2; shift 2
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY=debian DRY_RUN=1 TMPBIN="$t" \
    LTI_MOCK_GROUPS="${LTI_MOCK_GROUPS:-}" LTI_MOCK_GROUPS_USER="${LTI_MOCK_GROUPS_USER:-}" \
    LTI_MOCK_MODULES="${LTI_MOCK_MODULES:-}" LTI_MOCK_DOCKER_VERSION="${LTI_MOCK_DOCKER_VERSION:-}" \
    env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/sudo.sh"
        source "$LTI_ROOT/lib/docker.sh"
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        '"$expr"'
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# --- pure helpers -----------------------------------------------------------

@test "_docker_core_pkg: engine package per family" {
    [ "$(_src '' '_docker_core_pkg debian')" = "docker.io" ]
    [ "$(_src '' '_docker_core_pkg fedora')" = "moby-engine" ]
    [ "$(_src '' '_docker_core_pkg arch')"   = "docker" ]
    [ "$(_src '' '_docker_core_pkg suse')"   = "docker" ]
}

@test "_docker_core_pkg: unknown family -> non-zero, no output" {
    run _src '' '_docker_core_pkg martian && echo GOT || echo RC=$?'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]]
    [[ "$output" != *"GOT"* ]]
}

@test "_docker_sysctl_lines: ip_forward + both bridge-nf-call keys" {
    run _src '' '_docker_sysctl_lines'
    [ "$status" -eq 0 ]
    [[ "$output" == *"net.ipv4.ip_forward = 1"* ]]
    [[ "$output" == *"net.bridge.bridge-nf-call-iptables = 1"* ]]
    [[ "$output" == *"net.bridge.bridge-nf-call-ip6tables = 1"* ]]
}

@test "_docker_modules_lines: overlay + br_netfilter" {
    run _src '' '_docker_modules_lines'
    [ "$status" -eq 0 ]
    [[ "$output" == *"overlay"* ]]
    [[ "$output" == *"br_netfilter"* ]]
}

@test "_docker_engine_kind: real docker vs Podman shim" {
    [ "$(_src '' '_docker_engine_kind' docker)" = "docker" ]
    [ "$(LTI_MOCK_DOCKER_VERSION=podman-4.9.0 _src '' '_docker_engine_kind' docker)" = "podman" ]
}

@test "_docker_module_loaded: reflects lsmod" {
    run _src 'LTI_MOCK_MODULES=overlay' '_docker_module_loaded overlay && echo Y || echo N' lsmod
    [[ "$output" == *"Y"* ]]
    run _src 'LTI_MOCK_MODULES=overlay' '_docker_module_loaded br_netfilter && echo Y || echo N' lsmod
    [[ "$output" == *"N"* ]]
}

@test "_docker_group_state: missing / absent / inactive / active" {
    [ "$(_src 'LTI_MOCK_GROUP_DOCKER=absent' '_docker_group_state tester' getent id)" = "missing" ]
    [ "$(LTI_MOCK_GROUPS_USER=tester LTI_MOCK_GROUPS=tester \
        _src 'LTI_MOCK_GROUP_DOCKER=present' '_docker_group_state tester' getent id)" = "absent" ]
    [ "$(LTI_MOCK_GROUPS_USER='tester docker' LTI_MOCK_GROUPS='tester docker' \
        _src 'LTI_MOCK_GROUP_DOCKER=present' '_docker_group_state tester' getent id)" = "active" ]
    [ "$(LTI_MOCK_GROUPS_USER='tester docker' LTI_MOCK_GROUPS=tester \
        _src 'LTI_MOCK_GROUP_DOCKER=present' '_docker_group_state tester' getent id)" = "inactive" ]
}

# --- docker_diagnose (read-only) --------------------------------------------

@test "diagnose: healthy system -> all OK, 0 issues, rc 0" {
    LTI_MOCK_GROUPS_USER='tester docker' LTI_MOCK_GROUPS='tester docker' \
        LTI_MOCK_MODULES='overlay br_netfilter' \
        run _dg 'LTI_MOCK_GROUP_DOCKER=present LTI_MOCK_DOCKER_ACTIVE=active LTI_MOCK_DOCKER_RC=0 LTI_MOCK_SYSCTL_VALUE=1' \
        $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"real Docker on PATH"* ]]
    [[ "$output" == *"active and enabled"* ]]
    [[ "$output" == *"reachable from this shell"* ]]
    [[ "$output" == *"active in this shell"* ]]
    [[ "$output" == *"overlay loaded"* ]]
    [[ "$output" == *"no issues found"* ]]
    [[ "$output" == *"DGRC=0"* ]]
}

@test "diagnose: broken system -> shim/daemon/group/sysctl/module flagged, rc 1" {
    # Podman shim, daemon down, no modules, forwarding off, group configured but
    # not effective in this shell.
    LTI_MOCK_GROUPS_USER='tester docker' LTI_MOCK_GROUPS='tester' LTI_MOCK_MODULES='' \
        LTI_MOCK_DOCKER_VERSION=podman-4.9 \
        run _dg 'LTI_MOCK_GROUP_DOCKER=present LTI_MOCK_DOCKER_ACTIVE=inactive LTI_MOCK_SYSCTL_VALUE=0' \
        $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"Podman's shim"* ]]
    [[ "$output" == *"daemon not running"* ]]
    [[ "$output" == *"THIS shell predates it"* ]]
    [[ "$output" == *"net.ipv4.ip_forward is not 1"* ]]
    [[ "$output" == *"overlay not loaded"* ]]
    [[ "$output" == *"issue(s) found"* ]]
    [[ "$output" == *"DGRC=1"* ]]
}

# --- teach mode (DRY_RUN): diagnosis runs (read-only), fixes are only printed --

@test "teach mode (fedora): shows engine+runc, config writes, enable — mutates nothing" {
    local cap; cap="$(mktemp)"
    run _ds "DRY_RUN=1 LTI_FORCE_FAMILY=fedora LTI_TEST_CAPTURE=$cap" '' '' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"DSRC=0"* ]]
    [[ "$output" == *"moby-engine"*"containerd"*"runc"* ]]
    [[ "$output" == *"/etc/modules-load.d/docker.conf"* ]]
    [[ "$output" == *"/etc/sysctl.d/99-docker.conf"* ]]
    [[ "$output" == *"net.ipv4.ip_forward = 1"* ]]
    [[ "$output" == *"systemctl enable --now docker"* ]]
    [[ "$output" == *"sysctl --system"* ]]
    # Diagnosis probes may appear in the capture, but NO mutating command ran.
    ! grep -qE 'enable --now|reset-failed|install -m|modprobe|usermod|groupadd' "$cap"
    rm -f "$cap"
}

@test "teach mode (debian): engine package is docker.io" {
    run _ds "DRY_RUN=1 LTI_FORCE_FAMILY=debian" '' '' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker.io"* ]]
    [[ "$output" == *"DSRC=0"* ]]
}

# --- real mode with mocks: install/config/enable + group intelligence --------

@test "real mode: group absent -> installs, configures, enables, adds to docker group" {
    # group exists but user is not a member -> the group prompt fires.
    LTI_MOCK_GROUPS_USER=tester LTI_MOCK_GROUPS=tester \
        run _ds "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_MOCK_GROUP_DOCKER=present LTI_MOCK_DOCKER_ACTIVE=active LTI_TEST_CAPTURE=/dev/stdout" \
        "$REAL_SEAMS" $'y\ny\n' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"DSRC=0"* ]]
    [[ "$output" == *"INSTALL moby-engine containerd runc"* ]]
    [[ "$output" == *"modprobe overlay"* ]]
    [[ "$output" == *"sysctl --system"* ]]
    [[ "$output" == *"systemctl reset-failed docker.service"* ]]
    [[ "$output" == *"systemctl enable --now docker"* ]]
    [[ "$output" == *"usermod -aG docker"* ]]
}

@test "real mode: group inactive -> advises newgrp, does NOT run usermod" {
    # member per the DB, but not effective in this shell -> newgrp, not usermod.
    LTI_MOCK_GROUPS_USER='tester docker' LTI_MOCK_GROUPS=tester \
        run _ds "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_MOCK_GROUP_DOCKER=present LTI_MOCK_DOCKER_ACTIVE=active LTI_TEST_CAPTURE=/dev/stdout" \
        "$REAL_SEAMS" $'y\n' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"DSRC=0"* ]]
    [[ "$output" == *"systemctl enable --now docker"* ]]
    [[ "$output" == *"predates it"* ]]
    [[ "$output" != *"usermod -aG docker"* ]]
}

@test "real mode: group active -> no group prompt, no usermod" {
    LTI_MOCK_GROUPS_USER='tester docker' LTI_MOCK_GROUPS='tester docker' \
        run _ds "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_MOCK_GROUP_DOCKER=present LTI_MOCK_DOCKER_ACTIVE=active LTI_TEST_CAPTURE=/dev/stdout" \
        "$REAL_SEAMS" $'y\n' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"DSRC=0"* ]]
    [[ "$output" == *"already in the 'docker' group"* ]]
    [[ "$output" != *"usermod -aG docker"* ]]
}

@test "real mode: docker group missing -> groupadd then usermod" {
    LTI_MOCK_GROUPS_USER=tester LTI_MOCK_GROUPS=tester \
        run _ds "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_MOCK_GROUP_DOCKER=absent LTI_MOCK_DOCKER_ACTIVE=active LTI_TEST_CAPTURE=/dev/stdout" \
        "$REAL_SEAMS" $'y\ny\n' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"DSRC=0"* ]]
    [[ "$output" == *"groupadd docker"* ]]
    [[ "$output" == *"usermod -aG docker"* ]]
}

@test "real mode: Podman shim -> warns first, then installs real Docker" {
    LTI_MOCK_GROUPS_USER='tester docker' LTI_MOCK_GROUPS='tester docker' \
        LTI_MOCK_DOCKER_VERSION=podman-4.9 \
        run _ds "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_MOCK_GROUP_DOCKER=present LTI_MOCK_DOCKER_ACTIVE=active LTI_TEST_CAPTURE=/dev/stdout" \
        "$REAL_SEAMS" $'y\ny\n' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"Podman's shim"* ]]
    [[ "$output" == *"INSTALL moby-engine containerd runc"* ]]
    [[ "$output" == *"DSRC=0"* ]]
}

@test "real mode: decline install/repair -> no mutation, returns 0" {
    # Diagnosis (read-only) still runs, but declining the confirm means nothing
    # is installed/enabled/changed. Capture to a file so the pre-confirm summary
    # text on stdout can't be mistaken for a command that ran.
    local cap; cap="$(mktemp)"
    run _ds "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_MOCK_DOCKER_ACTIVE=active LTI_TEST_CAPTURE=$cap" \
        "$REAL_SEAMS" $'n\n' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"DSRC=0"* ]]
    [[ "$output" != *"INSTALL"* ]]
    ! grep -qE 'enable --now|reset-failed|install -m|modprobe|usermod|groupadd' "$cap"
    rm -f "$cap"
}

@test "real mode: failed daemon enable -> error + rc 1" {
    run _ds "DRY_RUN=0 LTI_FORCE_FAMILY=fedora LTI_MOCK_DOCKER_ACTIVE=active LTI_MOCK_SYSTEMCTL_RC=1" \
        "$REAL_SEAMS" $'y\n' $DMOCKS
    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed to enable/start the Docker service"* ]]
    [[ "$output" == *"DSRC=1"* ]]
}
