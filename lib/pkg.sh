# lib/pkg.sh — package-manager abstraction over apt/dnf/pacman/zypper.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh (DISTRO_FAMILY set).
#
# Two concepts:
#   PM_NAME  logical PM (drives command shape + bundle column):
#            apt | dnf | pacman | zypper
#   PM_BIN   concrete executable actually invoked (apt-get, dnf5, yum, ...)
#
# Public contract (bundle.sh depends only on these):
#   pm_detect              resolve PM_NAME + PM_BIN; may re-point DISTRO_FAMILY
#   pm_init                call pm_detect, set SUDO, export PM_NAME/PM_BIN/SUDO
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

# --- PM resolution: logical PM vs concrete binary ---------------------------

# Logical PM a distro family prefers. Non-zero if family unknown.
_pm_logical_for_family() {
    case "$1" in
        debian) printf 'apt\n' ;;
        fedora) printf 'dnf\n' ;;
        arch)   printf 'pacman\n' ;;
        suse)   printf 'zypper\n' ;;
        *)      return 1 ;;
    esac
}

# Family that owns a logical PM (inverse of the above).
_pm_family_for_logical() {
    case "$1" in
        apt)    printf 'debian\n' ;;
        dnf)    printf 'fedora\n' ;;
        pacman) printf 'arch\n' ;;
        zypper) printf 'suse\n' ;;
        *)      return 1 ;;
    esac
}

# Ordered concrete-binary candidates for a logical PM.
_pm_candidates() {
    case "$1" in
        apt)    printf 'apt-get apt\n' ;;
        dnf)    printf 'dnf dnf5 yum\n' ;;
        pacman) printf 'pacman\n' ;;
        zypper) printf 'zypper\n' ;;
        *)      return 1 ;;
    esac
}

# Echo the first of the given binaries found on PATH; non-zero if none.
# Ends with an explicit return (set -e safe in any caller).
_pm_first_present() {
    local b
    for b in "$@"; do
        if command -v "$b" >/dev/null 2>&1; then
            printf '%s\n' "$b"
            return 0
        fi
    done
    return 1
}

# Scan logical PMs by fixed priority (apt, dnf, pacman, zypper); echo
# "<logical> <bin>" for the first whose binary is present. Non-zero if none.
_pm_any_present() {
    local lp bin
    for lp in apt dnf pacman zypper; do
        # shellcheck disable=SC2046  # intentional word-split of the candidate list
        if bin=$(_pm_first_present $(_pm_candidates "$lp")); then
            printf '%s %s\n' "$lp" "$bin"
            return 0
        fi
    done
    return 1
}

# Resolve PM_NAME + PM_BIN from the distro family (a hint) and what is actually
# installed. May re-point DISTRO_FAMILY when adopting an available PM (never
# for an explicit LTI_FORCE_FAMILY). Fatal only if nothing usable exists and
# not --dry-run.
pm_detect() {
    local hint=${DISTRO_FAMILY:-unknown}
    local logical bin pair

    # 1. Forced family: locked. Resolve its binary; never auto-switch.
    if [[ -n ${LTI_FORCE_FAMILY:-} ]]; then
        logical=$(_pm_logical_for_family "$hint") \
            || lti_fatal "pm_detect: forced family '$hint' has no package manager." 2
        # shellcheck disable=SC2046  # intentional word-split of the candidate list
        if bin=$(_pm_first_present $(_pm_candidates "$logical")); then
            PM_NAME=$logical; PM_BIN=$bin
            return 0
        fi
        if (( DRY_RUN )); then
            PM_NAME=$logical
            PM_BIN=$(_pm_candidates "$logical"); PM_BIN=${PM_BIN%% *}
            warn "package manager for forced family '$hint' not found — continuing because --dry-run (using '$PM_BIN' nominally)."
            return 0
        fi
        lti_fatal "Package manager for forced family '$hint' not found (looked for: $(_pm_candidates "$logical"))." 2
    fi

    # 2. Detected family with its own PM present → use it (family unchanged).
    if logical=$(_pm_logical_for_family "$hint"); then
        # shellcheck disable=SC2046  # intentional word-split of the candidate list
        if bin=$(_pm_first_present $(_pm_candidates "$logical")); then
            PM_NAME=$logical; PM_BIN=$bin
            return 0
        fi
        # 3. Its PM is absent → adopt an available one and re-point family.
        if pair=$(_pm_any_present); then
            PM_NAME=${pair%% *}; PM_BIN=${pair##* }
            DISTRO_FAMILY=$(_pm_family_for_logical "$PM_NAME")
            warn "os-release indicates '$hint' but its package manager is not installed; using '$PM_BIN' ($DISTRO_FAMILY) which is present."
            return 0
        fi
    else
        # 4. Unknown family → adopt the first present PM by priority.
        if pair=$(_pm_any_present); then
            PM_NAME=${pair%% *}; PM_BIN=${pair##* }
            DISTRO_FAMILY=$(_pm_family_for_logical "$PM_NAME")
            info "No recognized distro; using '$PM_BIN' ($DISTRO_FAMILY) found on PATH."
            return 0
        fi
    fi

    # 5. Nothing usable.
    if (( DRY_RUN )); then
        if logical=$(_pm_logical_for_family "$hint"); then
            PM_NAME=$logical
        else
            PM_NAME=apt; DISTRO_FAMILY=debian
        fi
        PM_BIN=$(_pm_candidates "$PM_NAME"); PM_BIN=${PM_BIN%% *}
        warn "no supported package manager found — continuing because --dry-run (using '$PM_BIN' nominally)."
        return 0
    fi
    lti_fatal "No supported package manager found (looked for: apt-get apt dnf dnf5 yum pacman zypper)." 2
}

pm_init() {
    pm_detect    # sets PM_NAME, PM_BIN; may re-point DISTRO_FAMILY

    # sudo prefix; real validation deferred to pm_require_privileges.
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
    export PM_NAME PM_BIN SUDO
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
