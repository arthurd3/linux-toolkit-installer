# lib/disk.sh — interactive disk mounting (enumerate partitions, mount one).
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh, lib/pkg.sh.
# Sourced after lib/sudo.sh in install.sh (so pm_require_privileges can
# bootstrap a missing sudo before any mount runs).
#
# Zero external deps: lsblk and mount are base util-linux (always present, so
# no dependency check). The only real package this offers is ntfs-3g, installed
# via the package manager (pm_install) when mounting an NTFS partition.
#
# Public contract:
#   disk_mount   interactive: pick a partition, choose a mount point, mount it.
# Private helpers:
#   _disk_enumerate                       emit candidate partitions (TSV rows)
#   _disk_default_mountpoint <dev> <label>  suggested /run/media/<user>/<name>
#   _disk_mount_argv <dev> <mp> <fstype>    raw mount argv (no $SUDO)

[[ -n ${_LTI_DISK_SH:-} ]] && return 0
_LTI_DISK_SH=1

# --- enumeration ------------------------------------------------------------

# Emit one TAB-separated row per candidate partition:
#   path<TAB>size<TAB>fstype<TAB>label<TAB>mountpoint
# Source is `lsblk -P` (key="value" pairs, robust to spaces in LABEL). We must
# NOT `eval` the lines: the PATH key would clobber the shell's $PATH. Instead
# each line is parsed with bash regex into local vars (device kept in `dev`).
# Keeps only real partitions with a non-swap, non-empty filesystem; already
# mounted ones are still emitted (with their mountpoint) so the caller can
# mark/reject them. Always returns 0 (set -e safe in any caller).
_disk_enumerate() {
    local line dev size fstype label mountpoint type
    while IFS= read -r line; do
        dev=""; size=""; fstype=""; label=""; mountpoint=""; type=""
        # Anchor each key on a boundary (start-of-line or a space) so a key that
        # is the suffix of another does not capture the wrong value — bash =~
        # takes the FIRST match, and e.g. FSTYPE="..." would otherwise satisfy
        # the TYPE pattern. The captured value is BASH_REMATCH[2].
        [[ $line =~ (^|[[:space:]])PATH=\"([^\"]*)\"       ]] && dev=${BASH_REMATCH[2]}
        [[ $line =~ (^|[[:space:]])SIZE=\"([^\"]*)\"       ]] && size=${BASH_REMATCH[2]}
        [[ $line =~ (^|[[:space:]])FSTYPE=\"([^\"]*)\"     ]] && fstype=${BASH_REMATCH[2]}
        [[ $line =~ (^|[[:space:]])LABEL=\"([^\"]*)\"      ]] && label=${BASH_REMATCH[2]}
        [[ $line =~ (^|[[:space:]])MOUNTPOINT=\"([^\"]*)\" ]] && mountpoint=${BASH_REMATCH[2]}
        [[ $line =~ (^|[[:space:]])TYPE=\"([^\"]*)\"       ]] && type=${BASH_REMATCH[2]}

        [[ $type == part ]] || continue
        [[ -n $fstype ]] || continue
        [[ $fstype == swap ]] && continue

        printf '%s\t%s\t%s\t%s\t%s\n' "$dev" "$size" "$fstype" "$label" "$mountpoint"
    done < <(lsblk -P -o PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT,TYPE 2>/dev/null)
    return 0
}

# --- pure helpers -----------------------------------------------------------

# Pure: suggested mount point /run/media/<user>/<name>, where <name> is the
# sanitized label (any char outside [A-Za-z0-9._-] -> '_') or, if the label is
# empty, the device basename. Always returns 0.
_disk_default_mountpoint() {
    local dev=$1 label=$2 user name
    user=${USER:-$(id -un)}
    if [[ -n $label ]]; then
        name=${label//[^A-Za-z0-9._-]/_}
    else
        name=${dev##*/}
    fi
    printf '/run/media/%s/%s\n' "$user" "$name"
    return 0
}

# Pure: echo the raw mount command (NO $SUDO), mirroring _pm_install_argv's
# style. NTFS uses the ntfs-3g driver. Always returns 0.
_disk_mount_argv() {
    local dev=$1 mp=$2 fstype=$3
    case "$fstype" in
        ntfs|ntfs3) printf 'mount -t ntfs-3g %s %s\n' "$dev" "$mp" ;;
        *)          printf 'mount %s %s\n' "$dev" "$mp" ;;
    esac
    return 0
}

# --- public entrypoint ------------------------------------------------------

disk_mount() {
    banner "Mount a disk"

    local -a rows=()
    local row
    while IFS= read -r row; do
        rows+=("$row")
    done < <(_disk_enumerate)

    if (( ${#rows[@]} == 0 )); then
        warn "No mountable partitions detected."
        return 0
    fi

    local choice i rest dev size fstype label mountpoint
    while true; do
        # Header.
        if (( _LTI_FANCY )); then
            printf '%s  %2s  %-15s %6s  %-6s %-16s %s%s\n' \
                "$C_BOLD" '#' 'DEVICE' 'SIZE' 'FS' 'LABEL' 'MOUNTED' "$C_RESET"
        else
            printf '  %2s  %-15s %6s  %-6s %-16s %s\n' \
                '#' 'DEVICE' 'SIZE' 'FS' 'LABEL' 'MOUNTED'
        fi
        # Rows.
        for i in "${!rows[@]}"; do
            # Split on TAB by parameter expansion, not `IFS=$'\t' read`: TAB is
            # IFS-whitespace, so read collapses adjacent tabs and an empty LABEL
            # would shift MOUNTPOINT into its place (an unlabeled mounted disk
            # would then look unmounted).
            rest=${rows[i]}
            dev=${rest%%$'\t'*};    rest=${rest#*$'\t'}
            size=${rest%%$'\t'*};   rest=${rest#*$'\t'}
            fstype=${rest%%$'\t'*}; rest=${rest#*$'\t'}
            label=${rest%%$'\t'*};  rest=${rest#*$'\t'}
            mountpoint=$rest
            [[ -n $label ]] || label='-'
            local mounted='no'
            [[ -n $mountpoint ]] && mounted=$mountpoint
            if (( _LTI_FANCY )) && [[ $mounted == no ]]; then
                printf '  %2d) %-15s %6s  %-6s %-16s %s%s%s\n' \
                    "$((i + 1))" "$dev" "$size" "$fstype" "$label" \
                    "$C_DIM" "$mounted" "$C_RESET"
            else
                printf '  %2d) %-15s %6s  %-6s %-16s %s\n' \
                    "$((i + 1))" "$dev" "$size" "$fstype" "$label" "$mounted"
            fi
        done
        say "  ---"
        printf '   r) Refresh     q) Cancel\n'

        if ! read -rp "Select a disk to mount: " choice; then choice=q; fi
        say ""

        case "$choice" in
            ''|q|Q) return 0 ;;
            r|R)
                rows=()
                while IFS= read -r row; do
                    rows+=("$row")
                done < <(_disk_enumerate)
                if (( ${#rows[@]} == 0 )); then
                    warn "No mountable partitions detected."
                    return 0
                fi
                continue ;;
            *)
                if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#rows[@]} )); then
                    rest=${rows[choice - 1]}   # tab-split preserving empty fields (see above)
                    dev=${rest%%$'\t'*};    rest=${rest#*$'\t'}
                    size=${rest%%$'\t'*};   rest=${rest#*$'\t'}
                    fstype=${rest%%$'\t'*}; rest=${rest#*$'\t'}
                    label=${rest%%$'\t'*};  rest=${rest#*$'\t'}
                    mountpoint=$rest
                    if [[ -n $mountpoint ]]; then
                        warn "$dev is already mounted at $mountpoint."
                        continue
                    fi
                    break
                fi
                error "invalid option: '$choice'"
                continue ;;
        esac
    done

    # A valid, unmounted device is now selected.
    local def mp
    def=$(_disk_default_mountpoint "$dev" "$label")
    if ! read -rp "Mount point [$def]: " mp; then mp=""; fi
    [[ -z $mp ]] && mp=$def

    # NTFS needs the ntfs-3g userspace driver.
    if [[ $fstype == ntfs || $fstype == ntfs3 ]] && ! pm_is_installed ntfs-3g; then
        info "Mounting NTFS needs the 'ntfs-3g' package."
        if confirm "Install ntfs-3g now?"; then
            pm_require_privileges
            pm_install ntfs-3g
        else
            warn "ntfs-3g is required to mount NTFS; aborting."
            return 0
        fi
    fi

    # Teach mode: print the exact commands, mutate nothing.
    if (( DRY_RUN )); then
        local pfx=""
        [[ -n ${SUDO:-} ]] && pfx="$SUDO "
        say "  ${pfx}mkdir -p $mp"
        say "  ${pfx}$(_disk_mount_argv "$dev" "$mp" "$fstype")"
        return 0
    fi

    # Real mode.
    confirm "Mount $dev at $mp?" || return 0
    pm_require_privileges   # no-op under root/dry-run; bootstraps sudo if missing

    local -a mkcmd mcmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    mkcmd=( $SUDO mkdir -p "$mp" )
    case "$fstype" in
        ntfs|ntfs3)
            # shellcheck disable=SC2206  # intentional word-split of $SUDO
            mcmd=( $SUDO mount -t ntfs-3g "$dev" "$mp" ) ;;
        *)
            # shellcheck disable=SC2206  # intentional word-split of $SUDO
            mcmd=( $SUDO mount "$dev" "$mp" ) ;;
    esac

    if "${mkcmd[@]}" && "${mcmd[@]}"; then
        ok "Mounted $dev at $mp."
        return 0
    fi
    error "Failed to mount $dev at $mp."
    return 1
}
