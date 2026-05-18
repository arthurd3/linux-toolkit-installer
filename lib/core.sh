# lib/core.sh — strict-mode policy, root resolution, globals, cleanup trap.
# Sourced (never executed). Safe to source more than once.

[[ -n ${_LTI_CORE_SH:-} ]] && return 0
_LTI_CORE_SH=1

# Strict mode for the whole tool. Fallible probes must wrap themselves in
# `set +e` / `|| true` (see lib/pkg.sh pm_is_installed).
set -euo pipefail

# --- bare fatal (used before lib/ui.sh is available) -------------------------
lti_fatal() {
    printf 'FATAL: %s\n' "$1" >&2
    exit "${2:-1}"
}

require_bash4() {
    if [[ -z ${BASH_VERSINFO:-} || ${BASH_VERSINFO[0]} -lt 4 ]]; then
        lti_fatal "Bash 4+ is required (found ${BASH_VERSION:-unknown})." 2
    fi
}
require_bash4

# --- realpath (pure bash, resolves symlinks; coreutils readlink only) --------
_lti_realpath() {
    local p=$1 target
    while [[ -L $p ]]; do
        target=$(readlink "$p")
        if [[ $target == /* ]]; then
            p=$target
        else
            p=$(cd -P -- "$(dirname -- "$p")" && pwd)/$target
        fi
    done
    printf '%s\n' "$(cd -P -- "$(dirname -- "$p")" && pwd)/$(basename -- "$p")"
}

# LTI_ROOT = repo root (parent of this lib/ dir). Overridable via env.
if [[ -z ${LTI_ROOT:-} ]]; then
    _lti_self=$(_lti_realpath "${BASH_SOURCE[0]}")
    LTI_ROOT=$(cd -P -- "$(dirname -- "$_lti_self")/.." && pwd)
fi
export LTI_ROOT

# --- runtime flags (env-overridable; arg parsing in install.sh sets these) ---
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${WITH_OPTIONAL:=0}"
: "${PM_REFRESHED:=0}"
: "${SUDO:=}"
export DRY_RUN ASSUME_YES WITH_OPTIONAL PM_REFRESHED SUDO

# --- temp-dir registry + EXIT cleanup ---------------------------------------
_LTI_TMPDIRS=()

lti_register_tmp() {
    _LTI_TMPDIRS+=("$1")
}

_lti_cleanup() {
    local d
    for d in ${_LTI_TMPDIRS[@]+"${_LTI_TMPDIRS[@]}"}; do
        [[ -n $d && -d $d ]] && rm -rf -- "$d"
    done
}
trap _lti_cleanup EXIT
