#!/usr/bin/env bash
# install.sh — linux-toolkit-installer entrypoint.
#
# Install a whole development toolkit with one keypress, on any major Linux
# distro (debian / fedora / arch / suse families). See README.md and docs/.
#
# Usage:
#   ./install.sh                 interactive menu
#   ./install.sh --list          show bundles + resolved packages for this distro
#   ./install.sh --bundle java   install one bundle
#   ./install.sh --all           install every bundle's core group
#   ./install.sh --with-optional include [optional] groups
#   ./install.sh --dry-run       print actions, change nothing (no sudo needed)
#   ./install.sh --yes           skip confirmations
#   ./install.sh --force-family <debian|fedora|arch|suse>
#   ./install.sh -h | --help

set -euo pipefail

# --- resolve our real directory (works through a ~/.local/bin symlink) ------
_self=${BASH_SOURCE[0]}
while [[ -L $_self ]]; do
    _dir=$(cd -P -- "$(dirname -- "$_self")" && pwd)
    _self=$(readlink "$_self")
    [[ $_self != /* ]] && _self="$_dir/$_self"
done
LTI_ROOT=$(cd -P -- "$(dirname -- "$_self")" && pwd)
export LTI_ROOT

source "$LTI_ROOT/lib/core.sh"
source "$LTI_ROOT/lib/state.sh"
source "$LTI_ROOT/lib/ui.sh"
source "$LTI_ROOT/lib/distro.sh"
source "$LTI_ROOT/lib/pkg.sh"
source "$LTI_ROOT/lib/sudo.sh"
source "$LTI_ROOT/lib/aur.sh"
source "$LTI_ROOT/lib/bundle.sh"

usage() {
    cat <<'EOF'
linux-toolkit-installer — one-keypress dev toolkits for any Linux distro

USAGE
  install.sh [options]

OPTIONS
  --list                     list bundles + resolved packages for this distro
  --bundle <name>            install a single bundle (e.g. --bundle java)
  --all                      install every bundle's [core] group
  --with-optional            also include [optional] groups
  --dry-run                  show actions, change nothing (no root needed)
  --yes, -y                  assume "yes" to all prompts
  --force-family <f>         override distro family: debian|fedora|arch|suse
  --setup-sudo               install & securely configure sudo, then exit
  -h, --help                 this help

With no options, an interactive menu is shown.
EOF
}

# --- project header (block art + info band) --------------------------------
show_header() {
    header
    info_band "$DISTRO_PRETTY" "$DISTRO_FAMILY" \
              "$(bundle_count)" "$(tool_count)" "$DRY_RUN"
}

# --- persistent state: machine facts + first-run flag ----------------------
_state_record() {
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    state_set schema 1
    state_set first_run_done 1
    if [[ -z $(state_get first_seen) ]]; then state_set first_seen "$now"; fi
    state_set last_seen "$now"
    state_set distro_family "${DISTRO_FAMILY:-unknown}"
    if [[ -n ${PM_NAME:-} ]]; then state_set pm_name "$PM_NAME"; fi
    if [[ -n ${PM_BIN:-} ]]; then state_set pm_bin "$PM_BIN"; fi
    if declare -F sudo_privilege_state >/dev/null 2>&1; then
        state_set sudo_state "$(sudo_privilege_state)"
    fi
    return 0
}

_state_save() {
    _state_record
    state_persist || warn "could not save state to $(state_path); continuing."
    return 0
}

# --- --list ----------------------------------------------------------------
do_list() {
    show_header
    local slug name desc f line t group r rc id rest kind pkgs k tag
    while IFS=$'\t' read -r slug name desc; do
        f="$LTI_ROOT/bundles/${slug}.bundle"
        say ""
        say "${C_BOLD}${name}${C_RESET}  [${slug}]${desc:+  — ${desc}}"
        group=core
        while IFS= read -r line || [[ -n $line ]]; do
            t=$(_trim "$line")
            [[ -z $t || $t == '#'* ]] && continue
            case "$t" in
                '[core]')      group=core; continue ;;
                '[optional]')  group=optional; continue ;;
                name:*|description:*) continue ;;
            esac
            [[ $t != *'|'* ]] && continue
            if r=$(bundle_resolve "$DISTRO_FAMILY" "$t"); then rc=0; else rc=$?; fi
            id=${r%%|*}; rest=${r#*|}; kind=${rest%%|*}; pkgs=${rest#*|}
            tag=""; [[ $group == optional ]] && tag="  (optional)"
            k=""; [[ $kind == aur ]] && k=" [aur]"
            if (( rc == 0 )) && ! { [[ $kind == aur && $DISTRO_FAMILY != arch ]]; }; then
                printf '  %-20s -> %s%s%s\n' "$id" "$pkgs" "$k" "$tag"
            else
                printf '  %-20s -> (no package for %s)%s\n' "$id" "$DISTRO_FAMILY" "$tag"
            fi
        done < "$f"
    done < <(bundle_list)
}

# --- --all -----------------------------------------------------------------
do_all() {
    local slug name desc rc=0
    while IFS=$'\t' read -r slug name desc; do
        bundle_run "$slug" || rc=1
    done < <(bundle_list)
    return $rc
}

# --- interactive menu ------------------------------------------------------
menu_loop() {
    local -a slugs=() names=()
    local s n d i choice
    while IFS=$'\t' read -r s n d; do
        slugs+=("$s"); names+=("$n")
    done < <(bundle_list)

    while true; do
        if (( _LTI_FANCY )) && command -v clear >/dev/null 2>&1; then clear; fi
        show_header
        say "Select a toolkit to install:"
        for i in "${!slugs[@]}"; do
            printf '  %2d) %s\n' "$((i + 1))" "${names[i]}"
        done
        say "  ---"
        printf '   a) Install ALL core toolkits\n'
        printf '   d) Toggle dry-run     [%s]\n' "$( ((DRY_RUN)) && echo ON || echo OFF)"
        printf '   o) Toggle optionals   [%s]\n' "$( ((WITH_OPTIONAL)) && echo ON || echo OFF)"
        if declare -F sudo_privilege_state >/dev/null 2>&1 \
           && [[ $(sudo_privilege_state) != root ]]; then
            printf '   s) Set up secure sudo\n'
        fi
        printf '   q) Quit\n'

        if ! read -rp "Select one: " choice; then choice=q; fi
        say ""

        case "$choice" in
            q|Q) say "Bye."; return 0 ;;
            a|A) do_all || true ;;
            s|S) sudo_bootstrap "from menu" || true ;;
            d|D) DRY_RUN=$(( DRY_RUN ^ 1 )); continue ;;
            o|O) WITH_OPTIONAL=$(( WITH_OPTIONAL ^ 1 )); continue ;;
            '')  continue ;;
            *)
                if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#slugs[@]} )); then
                    bundle_run "${slugs[choice - 1]}" || true
                else
                    error "invalid option: '$choice'"
                fi
                ;;
        esac
        printf '\nPress Enter to continue...'
        read -r _ || true
    done
}

main() {
    local action="" want_bundle=""
    while (( $# )); do
        case "$1" in
            -h|--help)        usage; exit 0 ;;
            --list)           action=list ;;
            --all)            action=all ;;
            --with-optional)  WITH_OPTIONAL=1 ;;
            --dry-run)        DRY_RUN=1 ;;
            --yes|-y)         ASSUME_YES=1 ;;
            --bundle)
                shift || true
                (( $# > 0 )) || lti_fatal "--bundle requires a name" 2
                want_bundle=$1; action=bundle ;;
            --bundle=*)       want_bundle=${1#*=}; action=bundle ;;
            --force-family)
                shift || true
                (( $# > 0 )) || lti_fatal "--force-family requires a value" 2
                LTI_FORCE_FAMILY=$1 ;;
            --force-family=*) LTI_FORCE_FAMILY=${1#*=} ;;
            --setup-sudo)     action=setup-sudo ;;
            *) error "unknown option: $1"; usage; exit 2 ;;
        esac
        shift || true
    done
    export DRY_RUN ASSUME_YES WITH_OPTIONAL
    export LTI_FORCE_FAMILY="${LTI_FORCE_FAMILY:-}"

    detect_distro_family
    if [[ ${DISTRO_FAMILY} == unknown ]]; then
        lti_fatal "Could not detect a supported distro (ID='${DISTRO_ID:-?}'). Supported families: ${LTI_SUPPORTED_FAMILIES}. Use --force-family to override." 2
    fi

    # Persistent state: load, then snapshot first-run BEFORE anything persists
    # (a later state_persist flips first_run_done; the decision must not move).
    state_load
    local _first_run=0
    if state_is_first_run; then _first_run=1; fi

    # Pre-flight: only when sudo is genuinely missing and the action needs
    # root. The automatic bootstrap is offered ONCE (first run); on later runs
    # a one-line reminder replaces it. Never for --list / --setup-sudo /
    # --dry-run, so `make check` and parseable --list output are unaffected.
    case "$action" in
        all|bundle|"")
            if (( ! DRY_RUN )) && declare -F sudo_privilege_state >/dev/null 2>&1 \
               && [[ $(sudo_privilege_state) == missing ]]; then
                if (( _first_run )); then
                    sudo_bootstrap "pre-flight: this action needs root" || true
                else
                    warn "sudo is not installed — you need it to install packages. Pick 's' in the menu, or run with --setup-sudo."
                fi
            fi ;;
    esac

    case "$action" in
        list)
            do_list ;;
        setup-sudo)
            pm_init; _state_save; sudo_bootstrap "explicit --setup-sudo" && exit 0 || exit 1 ;;
        all)
            pm_init; _state_save; do_all ;;
        bundle)
            pm_init; _state_save; bundle_run "$want_bundle" ;;
        "")
            pm_init; _state_save; menu_loop ;;
    esac
}

main "$@"
