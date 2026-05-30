#!/usr/bin/env bats
# tests/test_disk.bats — lib/disk.sh: partition enumeration, the pure mount-point
# and mount-argv helpers, and the interactive disk_mount flow (teach mode,
# already-mounted rejection, the ntfs-3g offer, empty enumeration). lsblk and
# mount are mocked (tests/mocks/bin/{lsblk,mount}); nothing is ever really
# mounted. We force family=debian + DRY_RUN where pm_init/SUDO matter (apt-get
# exists on the dev box, so pm_detect does not FATAL on a forced family).

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# _dm <env-assignments> <seam-defs> <stdin> [mock...]
# Sources core,ui,distro,pkg,disk; injects <seam-defs> after sourcing; exposes
# only the named mocks on PATH (prepended AFTER sourcing); feeds <stdin> to
# disk_mount; prints its output (stderr merged) and a trailing DMRC=<rc> line.
# The rc capture uses the set-e-safe `f && rc=0 || rc=$?` idiom (lib/core.sh
# runs set -euo pipefail, so a plain `disk_mount; echo $?` would never print on
# a non-zero return).
# <env-assignments> is for simple single-token vars only; a multi-line lsblk
# fixture is supplied via the caller's LTI_MOCK_LSBLK (a single direct
# assignment, forwarded below) so its embedded newline/spaces never reach the
# word-split `env $envs`.
_dm() {
    local envs=$1 seams=$2 input=$3; shift 3
    local t b; t="$(mktemp -d)"
    for b in "$@"; do ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"; done
    printf '%s' "$input" | \
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY=debian TMPBIN="$t" \
    LTI_MOCK_LSBLK="${LTI_MOCK_LSBLK:-}" \
    env $envs bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        source "$LTI_ROOT/lib/disk.sh"
        '"$seams"'
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        pm_init
        disk_mount && _dm_rc=0 || _dm_rc=$?; echo "DMRC=$_dm_rc"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# _src <env-assignments> <expr> [mock...]
# Sources the libs, exposes the named mocks on PATH after sourcing, then runs
# <expr>. For the pure helpers and _disk_enumerate (no pm_init needed, but
# debian+DRY_RUN keeps SUDO/family nominal if a helper ever reads them).
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
        source "$LTI_ROOT/lib/disk.sh"
        PATH="$TMPBIN:$PATH"
        detect_distro_family
        '"$expr"'
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

# --- _disk_enumerate --------------------------------------------------------

@test "_disk_enumerate: exactly 4 candidates (disk + swap filtered, mounted kept)" {
    run _src '' '_disk_enumerate' lsblk
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    # The ext4 partition is fully fielded (tab-joined here for the assertion).
    [[ "$output" == *"/dev/sdb1	3.6T	ext4	backup	"* ]]
    # Whole-disk row and swap row are dropped.
    [[ "$output" != *"/dev/sda	"* ]]
    [[ "$output" != *swap* ]]
    [[ "$output" != *"/dev/nvme0n1p2"* ]]
    # Spaced label survives intact, with its TAB delimiters around it.
    [[ "$output" == *"	vfat	USB STICK	/media/usb"* ]]
    [[ "$output" == *"/dev/sdc1	"* ]]
    # nvme0n1p1: empty LABEL (two adjacent TABs) and mountpoint /boot/efi.
    [[ "$output" == *"/dev/nvme0n1p1	512M	vfat		/boot/efi"* ]]
}

# --- _disk_default_mountpoint (pure) ----------------------------------------

@test "_disk_default_mountpoint: label, empty label, spaced label" {
    local u; u="${USER:-$(id -un)}"
    [ "$(_src '' '_disk_default_mountpoint /dev/sdb1 backup')" = "/run/media/$u/backup" ]
    # Empty label -> device basename.
    [ "$(_src '' '_disk_default_mountpoint /dev/sdb1 ""')" = "/run/media/$u/sdb1" ]
    # Space (and any non [A-Za-z0-9._-]) sanitized to '_'.
    [ "$(_src '' '_disk_default_mountpoint /dev/sdc1 "USB STICK"')" = "/run/media/$u/USB_STICK" ]
}

# --- _disk_mount_argv (pure) ------------------------------------------------

@test "_disk_mount_argv: ntfs/ntfs3 -> ntfs-3g, ext4 -> plain mount" {
    [ "$(_src '' '_disk_mount_argv /dev/sda1 /mnt/x ntfs')"  = "mount -t ntfs-3g /dev/sda1 /mnt/x" ]
    [ "$(_src '' '_disk_mount_argv /dev/sdb1 /mnt/x ext4')"  = "mount /dev/sdb1 /mnt/x" ]
    [ "$(_src '' '_disk_mount_argv /dev/sda1 /mnt/x ntfs3')" = "mount -t ntfs-3g /dev/sda1 /mnt/x" ]
}

# --- teach mode (DRY_RUN) ----------------------------------------------------

@test "teach mode: select ext4 -> prints mkdir+mount, mounts nothing for real" {
    local cap; cap="$(mktemp)"
    # Choose '2' (sdb1/ext4/backup), accept default mount point (blank line).
    # The mount mock is on PATH with LTI_TEST_CAPTURE pointed at $cap so we can
    # prove teach mode never invokes it.
    run _dm "DRY_RUN=1 LTI_TEST_CAPTURE=$cap" '' $'2\n\n' lsblk mount
    [ "$status" -eq 0 ]
    [[ "$output" == *"DMRC=0"* ]]
    # Prefix-agnostic: a leading "sudo " is added because SUDO=sudo (non-root).
    [[ "$output" == *"mkdir -p "*"/backup"* ]]
    [[ "$output" == *"mount /dev/sdb1 "*"/backup"* ]]
    # Teach mode must not run the real mount.
    [ ! -s "$cap" ]
    rm -f "$cap"
}

# --- already-mounted rejection ----------------------------------------------

@test "already-mounted: selecting a mounted partition is rejected, then cancel" {
    # '3' is sdc1 (mounted at /media/usb) -> warn + loop; then 'q' cancels.
    run _dm "DRY_RUN=1" '' $'3\nq\n' lsblk
    [ "$status" -eq 0 ]
    [[ "$output" == *"already mounted at /media/usb"* ]]
    [[ "$output" == *"DMRC=0"* ]]
}

# --- ntfs-3g offer -----------------------------------------------------------

@test "ntfs offer: ntfs-3g absent -> offer fires, installs, teach shows ntfs-3g" {
    # Seam-override the pkg seams so the offer path is deterministic and prints
    # a recognizable INSTALL line. confirm() auto-yes under DRY_RUN, so the
    # offer is accepted without stdin. '1' selects sda1 (ntfs); blank = default.
    local seams='pm_is_installed(){ return 1; }; pm_require_privileges(){ :; }; pm_install(){ echo "INSTALL $*"; }'
    run _dm "DRY_RUN=1" "$seams" $'1\n\n' lsblk
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALL ntfs-3g"* ]]
    [[ "$output" == *"mount -t ntfs-3g /dev/sda1"* ]]
    [[ "$output" == *"DMRC=0"* ]]
}

@test "ntfs offer: ntfs-3g present -> no install, still teaches ntfs-3g mount" {
    local seams='pm_is_installed(){ return 0; }'
    run _dm "DRY_RUN=1" "$seams" $'1\n\n' lsblk
    [ "$status" -eq 0 ]
    [[ "$output" != *INSTALL* ]]
    [[ "$output" == *"mount -t ntfs-3g /dev/sda1"* ]]
    [[ "$output" == *"DMRC=0"* ]]
}

# --- empty enumeration -------------------------------------------------------

@test "empty enumeration: no candidates -> warns and returns 0" {
    # Override the fixture with only the whole disk + swap (both filtered out).
    # Passed via LTI_MOCK_LSBLK (direct assignment), never through `env $envs`.
    local fixture='PATH="/dev/sda" SIZE="931.5G" FSTYPE="" LABEL="" MOUNTPOINT="" TYPE="disk"
PATH="/dev/sda2" SIZE="8G" FSTYPE="swap" LABEL="" MOUNTPOINT="[SWAP]" TYPE="part"'
    LTI_MOCK_LSBLK="$fixture" run _dm "DRY_RUN=1" '' '' lsblk
    [ "$status" -eq 0 ]
    [[ "$output" == *"No mountable partitions detected."* ]]
    [[ "$output" == *"DMRC=0"* ]]
}
