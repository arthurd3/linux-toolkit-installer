# lib/bundle.sh — parse bundle files, resolve packages per distro family,
# run a bundle, account for the result.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/pkg.sh, lib/aur.sh (arch only),
#             DISTRO_FAMILY / DISTRO_ID set by detect_distro_family.
#
# Bundle file grammar (see the "Bundle file format" section in README.md):
#   #comment            ignored
#   name: <Name>        header
#   description: <text> header
#   [core] / [optional] group markers (default before any marker = core)
#   <id> | debian=<p> | fedora=<p> | arch=<p> | suse=<p>
#       omitted family or `=-`  -> no package for that family (skip + warn)
#       value `a+b`             -> multiple packages
#       value `aur:<p>`         -> AUR package (arch only)

[[ -n ${_LTI_BUNDLE_SH:-} ]] && return 0
_LTI_BUNDLE_SH=1

_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

_join() {
    # $1 = separator, rest = items
    local sep=$1; shift
    (( $# == 0 )) && { printf '%s' '-'; return 0; }
    local out=$1; shift
    local x
    for x in "$@"; do out+="${sep}${x}"; done
    printf '%s' "$out"
}

# bundle_resolve <family> <mapping-line>
# Always prints: <id>|<kind>|<pkgs>   (kind = native|aur|none|bad)
# Exit: 0 resolved | 1 no mapping | 2 malformed
bundle_resolve() {
    local family=$1 line=$2
    local -a parts=()
    IFS='|' read -ra parts <<< "$line"
    local id; id=$(_trim "${parts[0]:-}")
    if [[ -z $id || ${#parts[@]} -lt 2 ]]; then
        printf '%s|bad|\n' "${id:-?}"
        return 2
    fi
    local i tok key val famval=""
    for (( i = 1; i < ${#parts[@]}; i++ )); do
        tok=$(_trim "${parts[i]}")
        [[ -z $tok || $tok != *=* ]] && continue
        key=$(_trim "${tok%%=*}")
        val=$(_trim "${tok#*=}")
        [[ $key == "$family" ]] && famval=$val
    done
    if [[ -z $famval || $famval == "-" ]]; then
        printf '%s|none|\n' "$id"
        return 1
    fi
    local kind=native
    if [[ $famval == aur:* ]]; then
        kind=aur
        famval=${famval#aur:}
    fi
    printf '%s|%s|%s\n' "$id" "$kind" "${famval//+/ }"
    return 0
}

# bundle_header <file>  ->  "<name>|<description>"
bundle_header() {
    local file=$1 line t name="" desc=""
    while IFS= read -r line || [[ -n $line ]]; do
        t=$(_trim "$line")
        [[ -z $t || $t == '#'* ]] && continue
        case "$t" in
            name:*)        name=$(_trim "${t#name:}") ;;
            description:*)  desc=$(_trim "${t#description:}") ;;
        esac
    done < "$file"
    printf '%s|%s\n' "$name" "$desc"
}

# bundle_list -> "<slug>\t<name>\t<description>" per bundle file
bundle_list() {
    local f base hdr name desc
    shopt -s nullglob
    for f in "$LTI_ROOT"/bundles/*.bundle; do
        base=$(basename "$f" .bundle)
        hdr=$(bundle_header "$f")
        name=${hdr%%|*}; desc=${hdr#*|}
        printf '%s\t%s\t%s\n' "$base" "${name:-$base}" "$desc"
    done
    shopt -u nullglob
}

# bundle_count -> number of bundle files (0 if none).
bundle_count() {
    local f n=0
    shopt -s nullglob
    for f in "$LTI_ROOT"/bundles/*.bundle; do
        n=$((n + 1))
    done
    shopt -u nullglob
    printf '%s' "$n"
    return 0
}

# tool_count -> total tool-definition lines across all bundles.
# A tool line is non-empty, not a comment, not a [group] marker, not a
# name:/description: header, and contains a '|'. Family-independent.
tool_count() {
    local f line t n=0
    shopt -s nullglob
    for f in "$LTI_ROOT"/bundles/*.bundle; do
        while IFS= read -r line || [[ -n $line ]]; do
            t=$(_trim "$line")
            [[ -z $t || $t == '#'* ]] && continue
            case "$t" in
                '[core]'|'[optional]'|name:*|description:*) continue ;;
            esac
            [[ $t != *'|'* ]] && continue
            n=$((n + 1))
        done < "$f"
    done
    shopt -u nullglob
    printf '%s' "$n"
    return 0
}

# Resolve a bundle path from a slug or a file path.
bundle_path() {
    local arg=$1
    if [[ -f $arg ]]; then printf '%s' "$arg"; return 0; fi
    local p="$LTI_ROOT/bundles/${arg}.bundle"
    if [[ -f $p ]]; then printf '%s' "$p"; return 0; fi
    return 1
}

# Install one collection, attributing per-id failures on batch failure.
# Globals used: _RUN_INSTALLED _RUN_FAILED (name arrays of ids)
_run_collection() {
    local kind=$1; shift
    (( $# == 0 )) && return 0
    local installer=pm_install
    [[ $kind == aur ]] && installer=aur_install

    # Args arrive as: id::pkg1 pkg2 :: id2::pkgA ...   (one entry per id)
    local -a ids=() flat=()
    local entry id pkgs p
    for entry in "$@"; do
        id=${entry%%::*}
        pkgs=${entry#*::}
        ids+=("$id")
        for p in $pkgs; do flat+=("$p"); done
    done

    if "$installer" "${flat[@]}"; then
        _RUN_INSTALLED+=("${ids[@]}")
        return 0
    fi

    warn "batch install failed — retrying per tool to attribute failures"
    for entry in "$@"; do
        id=${entry%%::*}
        pkgs=${entry#*::}
        # shellcheck disable=SC2086  # pkgs is a deliberate word list
        if "$installer" $pkgs; then
            _RUN_INSTALLED+=("$id")
        else
            _RUN_FAILED+=("$id")
        fi
    done
    return 1
}

# bundle_run <file-or-slug>
# Honors WITH_OPTIONAL, DRY_RUN, ASSUME_YES. Returns 0 ok / 1 a tool failed /
# 2 fatal (bundle missing). Prints a summary.
bundle_run() {
    local file
    if ! file=$(bundle_path "$1"); then
        error "bundle not found: $1"
        return 2
    fi

    local hdr name desc
    hdr=$(bundle_header "$file")
    name=${hdr%%|*}; desc=${hdr#*|}
    [[ -z $name ]] && name=$(basename "$file" .bundle)

    banner "Toolkit: $name" "Distro: ${DISTRO_ID:-?}  (family: ${DISTRO_FAMILY:-?})"
    [[ -n $desc ]] && say "$desc"
    say ""

    local group=core line t lineno=0
    local -a plan_native=() plan_aur=()
    local -a sk_already=() sk_nopkg=() _RUN_INSTALLED=() _RUN_FAILED=()
    local res rc id rest kind pkgs p allinst

    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        t=$(_trim "$line")
        [[ -z $t || $t == '#'* ]] && continue
        case "$t" in
            '[core]')      group=core; continue ;;
            '[optional]')  group=optional; continue ;;
            name:*|description:*) continue ;;
        esac
        if [[ $t != *'|'* ]]; then
            warn "$name line $lineno: malformed line, skipped"
            continue
        fi
        if [[ $group == optional && ${WITH_OPTIONAL:-0} -ne 1 ]]; then
            continue
        fi

        if res=$(bundle_resolve "${DISTRO_FAMILY:-unknown}" "$t"); then rc=0; else rc=$?; fi
        id=${res%%|*}; rest=${res#*|}; kind=${rest%%|*}; pkgs=${rest#*|}

        if (( rc == 2 )); then
            warn "$name line $lineno: malformed line, skipped"
            continue
        fi
        if (( rc == 1 )); then
            warn "$id: no package mapping for ${DISTRO_FAMILY:-unknown}, skipping"
            sk_nopkg+=("$id")
            continue
        fi
        if [[ $kind == aur && ${DISTRO_FAMILY:-} != arch ]]; then
            warn "$id: AUR-only, no ${DISTRO_FAMILY:-unknown} package, skipping"
            sk_nopkg+=("$id")
            continue
        fi

        allinst=1
        for p in $pkgs; do
            if ! pm_is_installed "$p"; then allinst=0; break; fi
        done
        if (( allinst )); then
            sk_already+=("$id")
            continue
        fi

        if [[ $kind == aur ]]; then
            plan_aur+=("${id}::${pkgs}")
        else
            plan_native+=("${id}::${pkgs}")
        fi
    done < "$file"

    # --- preview ---
    say "Plan for ${name}:"
    local e
    if (( ${#plan_native[@]} + ${#plan_aur[@]} > 0 )); then
        for e in ${plan_native[@]+"${plan_native[@]}"} ${plan_aur[@]+"${plan_aur[@]}"}; do
            say "  install  ${e%%::*}  (${e#*::})"
        done
    else
        say "  (nothing to install)"
    fi
    (( ${#sk_already[@]} > 0 )) && say "  present  $(_join ', ' ${sk_already[@]+"${sk_already[@]}"})"
    (( ${#sk_nopkg[@]}  > 0 )) && say "  no-pkg   $(_join ', ' ${sk_nopkg[@]+"${sk_nopkg[@]}"})"
    say ""

    if (( ${#plan_native[@]} + ${#plan_aur[@]} == 0 )); then
        ok "Nothing to do for ${name}."
        _bundle_summary "$name" sk_already sk_nopkg _RUN_INSTALLED _RUN_FAILED
        return 0
    fi

    if ! confirm "Install ${name} now?"; then
        warn "Aborted by user; nothing changed."
        return 0
    fi

    pm_require_privileges
    pm_refresh

    if (( ${#plan_aur[@]} > 0 )); then
        aur_ensure_helper || warn "yay unavailable; AUR tools may fail"
    fi
    (( ${#plan_native[@]} > 0 )) && { _run_collection native "${plan_native[@]}" || true; }
    (( ${#plan_aur[@]}    > 0 )) && { _run_collection aur    "${plan_aur[@]}"    || true; }

    _bundle_summary "$name" sk_already sk_nopkg _RUN_INSTALLED _RUN_FAILED
    (( ${#_RUN_FAILED[@]} == 0 ))
}

# _bundle_summary <name> <already-arr> <nopkg-arr> <installed-arr> <failed-arr>
_bundle_summary() {
    local title=$1
    local -n _a=$2 _n=$3 _i=$4 _f=$5
    say ""
    hr 50
    say "Summary: ${title}"
    say "  installed (${#_i[@]}): $(_join ', ' ${_i[@]+"${_i[@]}"})"
    say "  already   (${#_a[@]}): $(_join ', ' ${_a[@]+"${_a[@]}"})"
    say "  no-pkg    (${#_n[@]}): $(_join ', ' ${_n[@]+"${_n[@]}"})"
    say "  failed    (${#_f[@]}): $(_join ', ' ${_f[@]+"${_f[@]}"})"
    (( DRY_RUN )) && say "  (--dry-run: nothing was changed)"
    hr 50
}
