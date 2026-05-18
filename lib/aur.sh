# lib/aur.sh — Arch User Repository helper (yay). Arch family only.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/pkg.sh.
#
# bundle.sh only reaches these on DISTRO_FAMILY=arch; on any other family an
# `aur:` mapping is treated as "no package for this family" (skip + warn).
#
# Public:
#   aur_ensure_helper        ensure `yay` exists (bootstrap from AUR if absent)
#   aur_install <pkg...>     install AUR packages via yay
#
# Hardened vs. the original script.sh recipe: build happens in a mktemp dir
# registered for EXIT cleanup (no `cd yay`/`rm -rf yay` in the caller's CWD).

[[ -n ${_LTI_AUR_SH:-} ]] && return 0
_LTI_AUR_SH=1

aur_ensure_helper() {
    if command -v yay >/dev/null 2>&1; then
        return 0
    fi

    if (( DRY_RUN )); then
        printf '%s[dry-run]%s would bootstrap yay (pm_install git base-devel; git clone aur/yay; makepkg -si)\n' \
            "${C_DIM:-}" "${C_RESET:-}"
        return 0
    fi

    if ! confirm "AUR helper 'yay' is not installed. Bootstrap it now?"; then
        warn "Skipping yay bootstrap; AUR packages will be skipped."
        return 1
    fi

    if ! pm_install git base-devel; then
        error "Failed to install build prerequisites (git base-devel)."
        return 1
    fi

    local tmp
    if ! tmp=$(mktemp -d); then
        error "mktemp failed; cannot bootstrap yay."
        return 1
    fi
    lti_register_tmp "$tmp"

    info "Cloning yay from the AUR..."
    if ! git clone --depth 1 https://aur.archlinux.org/yay.git "$tmp/yay"; then
        error "git clone of yay failed."
        return 1
    fi

    info "Building yay (makepkg -si)..."
    if ! ( cd "$tmp/yay" && makepkg -si --noconfirm ); then
        error "makepkg build of yay failed."
        return 1
    fi

    ok "yay installed."
}

aur_install() {
    (( $# > 0 )) || return 0
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s yay -S --needed --noconfirm %s\n' \
            "${C_DIM:-}" "${C_RESET:-}" "$*"
        return 0
    fi
    yay -S --needed --noconfirm "$@"
}
