#!/usr/bin/env bats
# Unit tests for lib/pkg.sh resolution (pm_detect): logical PM_NAME vs concrete
# PM_BIN, forced-family lock, cross-family adoption, unknown fallback.
# Nothing real is installed; only mock PM binaries are exposed on a clean PATH.

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# _resolve <mode> <bins> [dry]
#   mode = force:<family> | osrel:<fixture>
#   bins = space-separated mock PM binaries to expose (e.g. "yum")
#   dry  = DRY_RUN (default 1)
# Prints "NAME=<PM_NAME> BIN=<PM_BIN> FAM=<DISTRO_FAMILY>" plus any WARN/FATAL
# (stderr merged). Exits with pm_init's status.
_resolve() {
    local mode=$1 bins=$2 dry=${3:-1} t b f="" o=""
    t="$(mktemp -d)"
    for b in $bins; do
        [ -n "$b" ] && ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"
    done
    case "$mode" in
        force:*) f="${mode#force:}" ;;
        osrel:*) o="$LTI_ROOT/tests/mocks/os-release/${mode#osrel:}" ;;
    esac
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY="$f" OS_RELEASE_PATH="$o" \
    DRY_RUN="$dry" TMPBIN="$t" bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        PATH="$TMPBIN"
        detect_distro_family
        pm_init
        echo "NAME=${PM_NAME:-} BIN=${PM_BIN:-} FAM=${DISTRO_FAMILY:-}"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

@test "fedora forced, only yum present -> PM_BIN=yum" {
    run _resolve force:fedora yum
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=dnf BIN=yum FAM=fedora"* ]]
}

@test "fedora forced, only dnf5 present -> PM_BIN=dnf5" {
    run _resolve force:fedora dnf5
    [[ "$output" == *"NAME=dnf BIN=dnf5 FAM=fedora"* ]]
}

@test "fedora forced, dnf+dnf5+yum -> prefers dnf" {
    run _resolve force:fedora "dnf dnf5 yum"
    [[ "$output" == *"NAME=dnf BIN=dnf FAM=fedora"* ]]
}

@test "fedora forced, only dnf -> PM_BIN=dnf (backward-compat)" {
    run _resolve force:fedora dnf
    [[ "$output" == *"NAME=dnf BIN=dnf FAM=fedora"* ]]
}

@test "debian forced, only dnf, dry-run -> nominal apt-get, NOT switched" {
    run _resolve force:debian dnf 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=apt BIN=apt-get FAM=debian"* ]]
    [[ "$output" == *"WARN:"* ]]
}

@test "debian forced, only dnf, non-dry-run -> fatal exit 2 (locked)" {
    run _resolve force:debian dnf 0
    [ "$status" -eq 2 ]
    [[ "$output" == *"forced family 'debian'"* ]]
}

@test "os-release debian, only dnf -> adopts dnf, family re-pointed to fedora" {
    run _resolve osrel:debian dnf 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=dnf BIN=dnf FAM=fedora"* ]]
    [[ "$output" == *"WARN: os-release indicates 'debian'"* ]]
}

@test "unknown os-release, apt-get present -> adopts apt/debian" {
    run _resolve osrel:unknown apt-get 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=apt BIN=apt-get FAM=debian"* ]]
}

@test "unknown os-release, no PM, non-dry-run -> fatal exit 2" {
    run _resolve osrel:unknown "" 0
    [ "$status" -eq 2 ]
    [[ "$output" == *"No supported package manager found"* ]]
}

@test "unknown os-release, no PM, dry-run -> warn, nominal apt-get, no crash" {
    run _resolve osrel:unknown "" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=apt BIN=apt-get FAM=debian"* ]]
    [[ "$output" == *"WARN: no supported package manager found"* ]]
}
