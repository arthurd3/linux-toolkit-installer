# lib/state.sh — tiny persistent state: first-run flag + machine facts.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh (lti_register_tmp, DRY_RUN). Nothing else.
#
# A plain key=value text file (one pair per line). Blank lines, '#' comments,
# and lines without '=' are ignored (never fatal). Values are simple scalars
# (no spaces). The file is created 0600. State IO NEVER aborts the real job
# and NEVER writes anything under --dry-run.
#
# Path resolution:
#   $LTI_STATE_FILE  (test/CI seam — exact file)
#   else  ${XDG_STATE_HOME:-$HOME/.local/state}/linux-toolkit-installer/state
#
# Public contract:
#   state_path             echo the resolved path (pure; always rc 0)
#   state_load             read the file into _LTI_STATE (read-only; rc 0)
#   state_get <key>        echo the value (empty if unset; rc 0)
#   state_set <key> <val>  set the value in memory
#   state_is_first_run     rc 0 if first run, rc 1 otherwise
#   state_persist          atomic write; rc 0 ok / 1 fail; no-op if DRY_RUN

[[ -n ${_LTI_STATE_SH:-} ]] && return 0
_LTI_STATE_SH=1

declare -gA _LTI_STATE=()

state_path() {
    if [[ -n ${LTI_STATE_FILE:-} ]]; then
        printf '%s\n' "$LTI_STATE_FILE"
    else
        printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/linux-toolkit-installer/state"
    fi
    return 0
}

state_load() {
    local f line key
    f=$(state_path)
    if [[ ! -f $f ]]; then
        return 0
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -z $line || $line == '#'* || $line != *'='* ]]; then
            continue
        fi
        key=${line%%=*}
        if [[ -n $key ]]; then
            _LTI_STATE[$key]=${line#*=}
        fi
    done < "$f"
    return 0
}

state_get() {
    printf '%s\n' "${_LTI_STATE[$1]:-}"
    return 0
}

state_set() {
    _LTI_STATE[$1]=${2-}
    return 0
}

state_is_first_run() {
    if [[ ${_LTI_STATE[first_run_done]:-} == 1 ]]; then
        return 1
    fi
    return 0
}

state_persist() {
    if (( DRY_RUN )); then
        return 0
    fi
    local f dir tmp key
    f=$(state_path)
    dir=$(dirname -- "$f")
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        return 1
    fi
    if ! tmp=$(mktemp -- "$dir/.state.XXXXXX" 2>/dev/null); then
        return 1
    fi
    lti_register_tmp "$tmp"
    {
        for key in "${!_LTI_STATE[@]}"; do
            printf '%s=%s\n' "$key" "${_LTI_STATE[$key]}"
        done
    } > "$tmp" 2>/dev/null || return 1
    chmod 0600 -- "$tmp" 2>/dev/null || return 1
    if ! mv -f -- "$tmp" "$f" 2>/dev/null; then
        return 1
    fi
    return 0
}
