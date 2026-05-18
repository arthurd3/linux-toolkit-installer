# lib/ui.sh — color gating, message helpers, banner, confirm.
# Sourced (never executed). Safe to source more than once.

[[ -n ${_LTI_UI_SH:-} ]] && return 0
_LTI_UI_SH=1

# Colors and box-drawing only when stdout is a TTY, NO_COLOR is unset, and
# TERM is usable. Plain ASCII otherwise (pipes, CI, dumb terminals).
_lti_color_enabled() {
    [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]
}

if _lti_color_enabled; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
    _LTI_FANCY=1
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
    _LTI_FANCY=0
fi

# --- messages (warn/error to stderr so stdout stays clean for --list) -------
say()   { printf '%s\n' "$*"; }
info()  { printf '%s%s%s\n' "$C_BLUE" "$*" "$C_RESET"; }

ok() {
    local mark='[OK]'
    (( _LTI_FANCY )) && mark='✓'
    printf '%s%s %s%s\n' "$C_GREEN" "$mark" "$*" "$C_RESET"
}

warn()  { printf '%sWARN: %s%s\n'  "$C_YELLOW" "$*" "$C_RESET" >&2; }
error() { printf '%sERROR: %s%s\n' "$C_RED"    "$*" "$C_RESET" >&2; }

# --- horizontal rule --------------------------------------------------------
hr() {
    local w=${1:-50} bar ch='-'
    (( _LTI_FANCY )) && ch='─'
    bar=$(printf '%*s' "$w" '')
    printf '%s\n' "${bar// /$ch}"
}

# --- banner (box-drawing, ASCII fallback) -----------------------------------
banner() {
    local line width=50 tl tr bl br h v bar
    if (( _LTI_FANCY )); then
        tl='╔'; tr='╗'; bl='╚'; br='╝'; h='═'; v='║'
    else
        tl='+'; tr='+'; bl='+'; br='+'; h='-'; v='|'
    fi
    bar=$(printf '%*s' "$width" ''); bar=${bar// /$h}
    printf '%s%s%s%s%s\n' "$C_CYAN" "$tl" "$bar" "$tr" "$C_RESET"
    for line in "$@"; do
        printf '%s%s%s %-*s %s%s%s\n' \
            "$C_CYAN" "$v" "$C_RESET" "$((width - 2))" "$line" \
            "$C_CYAN" "$v" "$C_RESET"
    done
    printf '%s%s%s%s%s\n' "$C_CYAN" "$bl" "$bar" "$br" "$C_RESET"
}

# --- info band (distro/family/counts/mode; pure — formats its args) ---------
# info_band <distro> <family> <bundles> <tools> <dry_run0|1>
# Fancy: two coloured lines + a closing cyan rule. Plain: two ASCII lines.
info_band() {
    local distro=${1:-unknown} family=${2:-unknown}
    local bundles=${3:-0} tools=${4:-0} dry=${5:-0}
    local mode=OFF
    (( dry )) && mode=ON
    if (( _LTI_FANCY )); then
        printf '  %sdistro%s  %s%s%s  ·  %sfamily%s  %s%s%s\n' \
            "$C_DIM" "$C_RESET" "$C_BOLD" "$distro" "$C_RESET" \
            "$C_DIM" "$C_RESET" "$C_BOLD" "$family" "$C_RESET"
        printf '  %sbundles%s %s%s%s  ·  %s%s%s tools  ·  %sdry-run%s %s%s%s\n' \
            "$C_DIM" "$C_RESET" "$C_BOLD" "$bundles" "$C_RESET" \
            "$C_BOLD" "$tools" "$C_RESET" \
            "$C_DIM" "$C_RESET" "$C_BOLD" "$mode" "$C_RESET"
        local bar
        bar=$(printf '%*s' 50 '')
        printf '%s%s%s\n' "$C_CYAN" "${bar// /─}" "$C_RESET"
    else
        printf 'distro: %s   family: %s\n' "$distro" "$family"
        printf 'bundles: %s   tools: %s   dry-run: %s\n' "$bundles" "$tools" "$mode"
    fi
}

# --- yes/no prompt ----------------------------------------------------------
# Returns 0 for yes. Auto-yes under --yes or --dry-run. Use in a conditional.
confirm() {
    local prompt=${1:-Continue?} ans
    if (( ASSUME_YES )) || (( DRY_RUN )); then
        return 0
    fi
    printf '%s [y/N] ' "$prompt"
    if ! read -r ans; then
        ans=''
    fi
    [[ $ans == [yY] || $ans == [yY][eE][sS] ]]
}
