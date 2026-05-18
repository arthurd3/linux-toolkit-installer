#!/usr/bin/env bats
# Unit tests for lib/ui.sh — header + info band rendering (presentation only).

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# Render with a forced fancy/plain mode. $1 = 0|1 fancy, rest = function call.
_render() {
    local fancy=$1; shift
    bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        if [ "'"$fancy"'" = 1 ]; then
            _LTI_FANCY=1
            C_RESET=$'"'"'\e[0m'"'"'; C_BOLD=$'"'"'\e[1m'"'"'; C_DIM=$'"'"'\e[2m'"'"'
            C_CYAN=$'"'"'\e[36m'"'"'
        else
            _LTI_FANCY=0
            C_RESET=; C_BOLD=; C_DIM=; C_CYAN=
        fi
        '"$*"'
    '
}

@test "info_band plain: labelled values, no ANSI, no rule" {
    run _render 0 'info_band "Ubuntu 24.04 LTS" debian 7 34 0'
    [ "$status" -eq 0 ]
    [[ "$output" == *"distro: Ubuntu 24.04 LTS"* ]]
    [[ "$output" == *"family: debian"* ]]
    [[ "$output" == *"bundles: 7"* ]]
    [[ "$output" == *"tools: 34"* ]]
    [[ "$output" == *"dry-run: OFF"* ]]
    [[ "$output" != *$'\e['* ]]
    [[ "$output" != *"─"* ]]
}

@test "info_band plain: dry_run=1 renders ON" {
    run _render 0 'info_band "X" debian 1 2 1'
    [[ "$output" == *"dry-run: ON"* ]]
}

@test "info_band fancy: has separators, cyan rule, ANSI" {
    run _render 1 'info_band "Ubuntu 24.04 LTS" debian 7 34 0'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ubuntu 24.04 LTS"* ]]
    [[ "$output" == *"·"* ]]
    [[ "$output" == *"─"* ]]
    [[ "$output" == *$'\e['* ]]
}
