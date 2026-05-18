# lib/distro.sh — detect the distro family from /etc/os-release.
# Sourced (never executed). Safe to source more than once.
#
# Sets two globals:
#   DISTRO_ID      raw ID= from os-release (or "forced:<f>")
#   DISTRO_FAMILY  one of: debian fedora arch suse unknown
#
# Test/override hooks:
#   OS_RELEASE_PATH   path to read instead of /etc/os-release
#   LTI_FORCE_FAMILY  force the family (must be a supported family)

[[ -n ${_LTI_DISTRO_SH:-} ]] && return 0
_LTI_DISTRO_SH=1

LTI_SUPPORTED_FAMILIES="debian fedora arch suse"

# Map a single distro id token to a family. Non-zero + no output if unknown.
_lti_family_of() {
    case "$1" in
        debian|ubuntu|linuxmint|mint|pop|raspbian|elementary|kali|devuan|zorin)
            printf 'debian\n' ;;
        fedora|rhel|centos|rocky|almalinux|ol|amzn|scientific)
            printf 'fedora\n' ;;
        arch|manjaro|endeavouros|garuda|artix|cachyos)
            printf 'arch\n' ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles|sled|suse)
            printf 'suse\n' ;;
        *)
            return 1 ;;
    esac
}

detect_distro_family() {
    DISTRO_ID=""
    DISTRO_FAMILY=""

    # Explicit override wins (validated against supported families).
    if [[ -n ${LTI_FORCE_FAMILY:-} ]]; then
        case "$LTI_FORCE_FAMILY" in
            debian|fedora|arch|suse) ;;
            *) lti_fatal "LTI_FORCE_FAMILY='${LTI_FORCE_FAMILY}' is not one of: ${LTI_SUPPORTED_FAMILIES}" 2 ;;
        esac
        DISTRO_ID="forced:${LTI_FORCE_FAMILY}"
        DISTRO_FAMILY=$LTI_FORCE_FAMILY
        return 0
    fi

    local os_release=${OS_RELEASE_PATH:-/etc/os-release}
    local id="" id_like="" line key val

    if [[ -r $os_release ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line != *=* ]] && continue
            key=${line%%=*}
            val=${line#*=}
            val=${val#\"}; val=${val%\"}
            val=${val#\'}; val=${val%\'}
            case "$key" in
                ID)      id=$val ;;
                ID_LIKE) id_like=$val ;;
            esac
        done < "$os_release"
    fi

    DISTRO_ID=$id

    local fam="" tok
    if [[ -n $id ]]; then
        fam=$(_lti_family_of "$id") || fam=""
    fi
    if [[ -z $fam && -n $id_like ]]; then
        for tok in $id_like; do
            fam=$(_lti_family_of "$tok") || fam=""
            [[ -n $fam ]] && break
        done
    fi

    DISTRO_FAMILY=${fam:-unknown}
    return 0
}
