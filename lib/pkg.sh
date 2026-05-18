# lib/pkg.sh — package-manager abstraction over apt/dnf/pacman/zypper.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh (DISTRO_FAMILY set).
#
# Public contract (bundle.sh depends only on these):
#   pm_init                resolve PM_NAME, verify binary, set SUDO prefix
#   pm_require_privileges  validate sudo up front (no-op in --dry-run / root)
#   pm_refresh             update the package index once per run
#   pm_is_installed <pkg>  0 if installed, 1 otherwise (never trips set -e)
#   pm_install <pkg...>    install packages (prints, doesn't run, in --dry-run)

[[ -n ${_LTI_PKG_SH:-} ]] && return 0
_LTI_PKG_SH=1

# Run or (in dry-run) print a command. shellcheck: $SUDO must word-split.
_pm_run() {
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "${C_DIM:-}" "${C_RESET:-}" "$*"
        return 0
    fi
    "$@"
}

pm_init() {
    case "${DISTRO_FAMILY:-}" in
        debian) PM_NAME=apt ;;
        fedora) PM_NAME=dnf ;;
        arch)   PM_NAME=pacman ;;
        suse)   PM_NAME=zypper ;;
        *) lti_fatal "Unsupported distro family '${DISTRO_FAMILY:-<unset>}'. Supported: ${LTI_SUPPORTED_FAMILIES:-debian fedora arch suse}." 2 ;;
    esac

    local bin
    case "$PM_NAME" in
        apt)    bin=apt-get ;;
        dnf)    bin=dnf ;;
        pacman) bin=pacman ;;
        zypper) bin=zypper ;;
    esac
    if ! command -v "$bin" >/dev/null 2>&1; then
        if (( DRY_RUN )); then
            warn "package manager '$bin' not found — continuing because --dry-run."
        else
            lti_fatal "Required package manager '$bin' not found on PATH." 2
        fi
    fi

    # sudo prefix; real validation deferred to pm_require_privileges.
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
    export PM_NAME SUDO
}

pm_require_privileges() {
    (( DRY_RUN )) && return 0
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        SUDO=""
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        lti_fatal "Not running as root and 'sudo' is not available." 2
    fi
    info "Requesting sudo access (you may be prompted for your password)..."
    if ! sudo -v; then
        lti_fatal "sudo authentication failed." 2
    fi
    SUDO="sudo"
}

pm_refresh() {
    (( PM_REFRESHED )) && return 0
    local cmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    case "$PM_NAME" in
        apt)    cmd=( $SUDO apt-get update ) ;;
        dnf)    cmd=( $SUDO dnf -y makecache ) ;;
        pacman) cmd=( $SUDO pacman -Sy --noconfirm ) ;;
        zypper) cmd=( $SUDO zypper --non-interactive refresh ) ;;
        *) error "pm_refresh: pm_init not called"; return 1 ;;
    esac
    info "Refreshing package index ($PM_NAME)..."
    _pm_run "${cmd[@]}"
    PM_REFRESHED=1
}

# Never lets a raw failing probe be the last command (set -e safe in any caller).
pm_is_installed() {
    local pkg=$1
    case "$PM_NAME" in
        apt)
            if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
                return 0
            fi
            return 1 ;;
        dnf|zypper)
            if rpm -q "$pkg" >/dev/null 2>&1; then return 0; fi
            return 1 ;;
        pacman)
            if pacman -Qq "$pkg" >/dev/null 2>&1; then return 0; fi
            return 1 ;;
        *)
            return 1 ;;
    esac
}

pm_install() {
    (( $# > 0 )) || return 0
    local cmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    case "$PM_NAME" in
        apt)    cmd=( $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ) ;;
        dnf)    cmd=( $SUDO dnf install -y "$@" ) ;;
        pacman) cmd=( $SUDO pacman -S --needed --noconfirm "$@" ) ;;
        zypper) cmd=( $SUDO zypper --non-interactive install "$@" ) ;;
        *) error "pm_install: pm_init not called"; return 1 ;;
    esac
    _pm_run "${cmd[@]}"
}
