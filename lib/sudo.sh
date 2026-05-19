# lib/sudo.sh — privilege-escalation bootstrap (install & securely configure sudo).
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh (DISTRO_FAMILY),
#             lib/pkg.sh (PM_NAME/PM_BIN, _pm_install_argv).
#
# Secure-by-default: the only path offered is the password-required admin-group
# method (group `sudo` on debian/suse, `wheel` on fedora/arch). NEVER NOPASSWD,
# never a /etc/sudoers.d drop-in. Any /etc/sudoers change is validated with
# `visudo -cf` on a temp copy and applied atomically with
# `install -m 0440 -o root -g root`. All privileged steps run as root via a
# single `su root -c` (or are PRINTED, in teach mode). The ROOT password is read
# by `su` itself — never by this script.
#
# Public contract:
#   sudo_admin_group [family]  echo sudo|wheel (pure); non-zero if family unknown
#   sudo_privilege_state       echo root|missing|present (always returns 0)
#   sudo_bootstrap [reason]    install/configure sudo; 0 if a usable path exists
#                              afterwards, 1 otherwise. Never fatal. DRY_RUN =>
#                              teach (print only); ASSUME_YES => automatic.
# Overridable probes (tests redefine these after sourcing):
#   _sudo_is_root  _sudo_have_sudo  _sudo_have_su  _sudo_user  _sudo_user_groups

[[ -n ${_LTI_SUDO_SH:-} ]] && return 0
_LTI_SUDO_SH=1

# --- overridable probes -----------------------------------------------------
_sudo_is_root()      { [[ ${EUID:-$(id -u)} -eq 0 ]]; }
_sudo_have_sudo()    { command -v sudo >/dev/null 2>&1; }
_sudo_have_su()      { command -v su   >/dev/null 2>&1; }
_sudo_user()         { printf '%s\n' "${SUDO_USER:-$(id -un)}"; }
_sudo_user_groups()  { id -nG 2>/dev/null || true; }

# Pure: admin group for a family (defaults to $DISTRO_FAMILY). Non-zero if unknown.
sudo_admin_group() {
    case "${1:-${DISTRO_FAMILY:-}}" in
        debian|suse) printf 'sudo\n';  return 0 ;;
        fedora|arch) printf 'wheel\n'; return 0 ;;
        *)           return 1 ;;
    esac
}

# Echo root|missing|present. Always returns 0 (set -e safe).
sudo_privilege_state() {
    if _sudo_is_root;     then printf 'root\n';    return 0; fi
    if ! _sudo_have_sudo; then printf 'missing\n'; return 0; fi
    printf 'present\n'
    return 0
}

# Write the privileged script (fully literal; GROUP/TARGET_USER/INSTALL_CMD
# are supplied via the environment on the `su root -c` command line).
_sudo_write_script() {
    local f=$1
    cat > "$f" <<'SUDOSCRIPT'
#!/usr/bin/env bash
set -e
if [ -n "${INSTALL_CMD:-}" ]; then
    eval "$INSTALL_CMD"
fi
usermod -aG "$GROUP" "$TARGET_USER"
if command -v visudo >/dev/null 2>&1; then
    t=$(mktemp)
    sed -E "s|^[#[:space:]]*(%${GROUP}[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL)|\1|" /etc/sudoers > "$t"
    if visudo -cf "$t"; then
        install -m 0440 -o root -g root "$t" /etc/sudoers
    else
        echo "WARN: edited sudoers failed validation; /etc/sudoers left unchanged" >&2
        rm -f "$t"; exit 1
    fi
    rm -f "$t"
else
    echo "NOTE: visudo not found; ensure '%${GROUP} ALL=(ALL:ALL) ALL' is enabled in /etc/sudoers" >&2
fi
SUDOSCRIPT
    return 0
}

# Print the steps (teach mode + manual fallback). Never executes anything.
_sudo_show_steps() {
    local script=$1 group=$2 user=$3 instcmd=$4
    say "These secure steps run as root (the ROOT password is asked by 'su'):"
    say ""
    say "  su root -c \"GROUP='$group' TARGET_USER='$user' INSTALL_CMD='$instcmd' bash $script\""
    say ""
    say "where the script is:"
    hr 60
    cat "$script"
    hr 60
    say "Then log out and back in, or run 'newgrp $group', so the new group applies."
    return 0
}

# Install (if missing) + add user to admin group + enable that group in sudoers.
sudo_bootstrap() {
    local reason=${1:-} state group user mode script instcmd="" ans=""
    state=$(sudo_privilege_state)
    [[ $state == root ]] && return 0
    if ! group=$(sudo_admin_group); then
        warn "Unknown distro family — cannot determine the sudo admin group. See your distro's documentation to set up sudo."
        return 1
    fi
    user=$(_sudo_user)

    if (( DRY_RUN )); then
        mode=teach
    elif (( ASSUME_YES )); then
        mode=auto
    else
        info "Set up sudo${reason:+ — $reason}"
        if ! confirm "Configure a secure 'sudo' privilege path now?"; then
            warn "Skipped sudo setup."
            return 1
        fi
        printf "Choose: [a]utomatic ('su' will ask for the ROOT password)  [s]how me the commands  [c]ancel: "
        read -r ans || ans="c"
        case "$ans" in
            a|A) mode=auto  ;;
            s|S) mode=teach ;;
            *)   warn "Cancelled."; return 1 ;;
        esac
    fi

    if [[ $state == missing ]]; then
        instcmd=$(_pm_install_argv sudo) || instcmd=""
    elif [[ $state == present ]]; then
        if [[ " $(_sudo_user_groups) " == *" $group "* ]]; then
            info "User '$user' is already in group '$group'."
        fi
    fi

    script=$(mktemp) || { error "mktemp failed."; return 1; }
    lti_register_tmp "$script"
    _sudo_write_script "$script"

    if [[ $mode == teach ]]; then
        _sudo_show_steps "$script" "$group" "$user" "$instcmd"
        return 0
    fi

    if ! _sudo_have_su; then
        warn "'su' is not available — cannot escalate automatically. Do it manually:"
        _sudo_show_steps "$script" "$group" "$user" "$instcmd"
        return 1
    fi
    info "Escalating with 'su' (you will be prompted for the ROOT password)..."
    say "  su root -c \"GROUP='$group' TARGET_USER='$user' INSTALL_CMD='$instcmd' bash $script\""
    if su root -c "GROUP='$group' TARGET_USER='$user' INSTALL_CMD='$instcmd' bash $script"; then
        ok "sudo is set up for '$user'. Log out and back in, or run 'newgrp $group', for it to take effect."
        return 0
    fi
    warn "The privileged step failed. Do it manually:"
    _sudo_show_steps "$script" "$group" "$user" "$instcmd"
    return 1
}
