# lib/cpp.sh — install a complete C/C++ toolchain and verify it end to end.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh, lib/pkg.sh.
# Sourced after lib/sudo.sh in install.sh (so pm_require_privileges can
# bootstrap a missing sudo before any privileged step runs).
#
# Installs the compilers (gcc/g++, clang), the build stack (make, cmake, ninja,
# autotools, pkg-config), the debugger (gdb) and the leak checker (valgrind) —
# the individual packages behind "Development Tools", chosen per distro family.
# We list packages explicitly rather than `dnf group install "Development
# Tools"`: group names are Fedora-specific and space-containing, and rpm/pacman
# cannot report a group as installed, which would defeat idempotency. Explicit
# packages give the same toolchain on every family and re-run cleanly.
#
# After installing, it compiles + links a trivial C and C++ program to prove the
# whole chain works (the manual `echo 'int main(){}' | gcc -x c - -o …` check).
#
# Public contract:
#   cpp_diagnose  read-only: report which toolchain pieces are present; rc 1 if any missing.
#   cpp_setup     interactive: diagnose, then install the toolchain + verify it compiles.
# Private helpers:
#   _cpp_pkgs <family>              space-separated package list for a distro family
#   _cpp_report <level> <label> [detail]   one colored [OK]/[WARN]/[FAIL] line
#   _cpp_probe <label> <cmd...>     report on the first present command (rc 0 if any found)
#   _cpp_install_set <pkg...>       install a set, batch-first with per-package fallback
#   _cpp_verify                     compile+link a trivial C and C++ program (best-effort)

[[ -n ${_LTI_CPP_SH:-} ]] && return 0
_LTI_CPP_SH=1

# --- pure helpers -----------------------------------------------------------

# Pure: the C/C++ toolchain packages for a distro family, as one space-separated
# line. On debian, build-essential pulls gcc/g++/make/libc-dev; on arch,
# base-devel pulls gcc/make/autotools/pkgconf. Names that don't exist on a given
# distro/version are dropped by _cpp_install_set's per-package fallback, never
# fatal. Non-zero for an unknown family. Ends with return 0.
_cpp_pkgs() {
    case "$1" in
        debian) printf '%s\n' 'build-essential gcc g++ make cmake ninja-build autoconf automake libtool pkg-config gdb clang clang-format clang-tidy valgrind' ;;
        fedora) printf '%s\n' 'gcc gcc-c++ make cmake ninja-build autoconf automake libtool pkgconf-pkg-config gdb clang clang-tools-extra valgrind glibc-devel' ;;
        arch)   printf '%s\n' 'base-devel gcc make cmake ninja gdb clang valgrind' ;;
        suse)   printf '%s\n' 'gcc gcc-c++ make cmake ninja autoconf automake libtool pkg-config gdb clang valgrind glibc-devel' ;;
        *)      return 1 ;;
    esac
    return 0
}

# Print one colored status line to stdout. <level> = ok | warn | fail. Returns 0
# for ok, 1 otherwise so callers tally issues via `|| n=$((n+1))`. Mirror of
# _docker_report so the two health reports read identically.
_cpp_report() {
    local level=$1 label=$2 detail=${3:-} tag col
    case "$level" in
        ok)   tag='[OK]  '; col=${C_GREEN:-} ;;
        warn) tag='[WARN]'; col=${C_YELLOW:-} ;;
        *)    tag='[FAIL]'; col=${C_RED:-} ;;
    esac
    printf '%s%s%s %s%s\n' "$col" "$tag" "${C_RESET:-}" "$label" "${detail:+ — $detail}"
    [[ $level == ok ]]
}

# Report on the first present of the given commands: OK with `--version`'s first
# line if any is found, FAIL otherwise. Returns 0 only when present, so callers
# tally with `|| issues=$((issues+1))`. Read-only; always safe under set -e.
_cpp_probe() {
    local label=$1; shift
    local c ver
    for c in "$@"; do
        if command -v "$c" >/dev/null 2>&1; then
            ver=$("$c" --version 2>/dev/null | head -n1 || true)
            _cpp_report ok "$label" "${ver:-$c present}"
            return 0
        fi
    done
    _cpp_report fail "$label" "not found (tried: $*)"
    return 1
}

# --- install ----------------------------------------------------------------

# Install a set of packages resiliently. One batch transaction is fast and is
# the norm; if it fails (usually a single name absent on this distro/version),
# fall back to per-package installs so the rest still land. Mirrors the batch-
# then-isolate strategy of _run_collection (lib/bundle.sh). Non-fatal by design:
# the caller re-checks the essential compiler afterward. Always returns 0.
_cpp_install_set() {
    local -a pkgs=( "$@" ) failed=()
    (( ${#pkgs[@]} )) || return 0
    if pm_install "${pkgs[@]}"; then
        return 0
    fi
    warn "batch install failed — retrying package-by-package to isolate it."
    local p
    for p in "${pkgs[@]}"; do
        pm_install "$p" || { failed+=("$p"); warn "  skipped '$p' (not available on this distro?)."; }
    done
    (( ${#failed[@]} )) && warn "skipped ${#failed[@]} unavailable package(s): ${failed[*]}"
    return 0
}

# Compile + link a trivial C and C++ program end to end — proof the toolchain
# actually works, not just that binaries are on PATH (the manual
# `echo 'int main(){}' | gcc -x c - -o …` check). Best-effort: warns, never
# fatal. The caller skips this under --dry-run (nothing was installed).
_cpp_verify() {
    local tmp cc_bin cxx_bin
    tmp=$(mktemp -d) || { warn "could not create a temp dir for the compile test."; return 0; }
    lti_register_tmp "$tmp"

    cc_bin=$(command -v gcc || command -v cc || true)
    if [[ -n $cc_bin ]] \
        && printf 'int main(void){return 0;}\n' | "$cc_bin" -x c - -o "$tmp/smoke_c" 2>/dev/null \
        && [[ -x $tmp/smoke_c ]]; then
        ok "C compiles and links (via $(basename "$cc_bin"))."
    else
        warn "C compile/link test failed — check your gcc/cc install."
    fi

    cxx_bin=$(command -v g++ || command -v c++ || true)
    if [[ -n $cxx_bin ]] \
        && printf 'int main(){return 0;}\n' | "$cxx_bin" -x c++ - -o "$tmp/smoke_cxx" 2>/dev/null \
        && [[ -x $tmp/smoke_cxx ]]; then
        ok "C++ compiles and links (via $(basename "$cxx_bin"))."
    else
        warn "C++ compile/link test failed — check your g++/c++ install."
    fi
    return 0
}

# --- public entrypoints -----------------------------------------------------

# Read-only health report: which toolchain pieces are present, with versions.
# No root, changes nothing. Returns 0 if the toolchain looks complete, 1 if any
# piece is missing (so `--cpp-check` can signal completeness via exit code).
cpp_diagnose() {
    banner "C/C++ toolchain health"
    local issues=0

    _cpp_probe "cc      " gcc cc   || issues=$((issues + 1))
    _cpp_probe "c++     " g++ c++   || issues=$((issues + 1))
    _cpp_probe "make    " make      || issues=$((issues + 1))
    _cpp_probe "cmake   " cmake     || issues=$((issues + 1))
    _cpp_probe "ninja   " ninja     || issues=$((issues + 1))
    _cpp_probe "gdb     " gdb       || issues=$((issues + 1))
    _cpp_probe "clang   " clang     || issues=$((issues + 1))
    _cpp_probe "valgrind" valgrind  || issues=$((issues + 1))

    say ""
    if (( issues == 0 )); then
        ok "C/C++ toolchain looks complete — no issues found."
    else
        warn "$issues item(s) missing — run './install.sh --cpp' to install them."
    fi
    (( issues == 0 ))
}

cpp_setup() {
    banner "Set up C/C++ toolchain"

    local family=${DISTRO_FAMILY:-unknown} pkgs
    if ! pkgs=$(_cpp_pkgs "$family"); then
        error "Unsupported distro family '$family' for the C/C++ toolchain."
        return 1
    fi

    # Diagnose first so the user sees what's missing before we touch anything.
    cpp_diagnose || true
    say ""

    info "This will install the C/C++ toolchain:"
    say  "  - packages: $pkgs"
    say  "  - then compile + link a trivial C and C++ program to verify it"
    say  ""
    confirm "Install the C/C++ toolchain now?" || return 0

    pm_require_privileges          # no-op under root/dry-run; bootstraps sudo
    pm_refresh || warn "package index refresh failed; continuing."

    # shellcheck disable=SC2086  # intentional word-split of the package list
    _cpp_install_set $pkgs

    # A working C compiler is the whole point — fail loudly if it didn't land.
    if (( ! DRY_RUN )) && ! command -v gcc >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
        error "No C compiler on PATH after install — check the messages above."
        return 1
    fi

    # Verify (real mode only — nothing was installed under --dry-run).
    (( DRY_RUN )) || _cpp_verify
    ok "C/C++ toolchain is ready."
    return 0
}
