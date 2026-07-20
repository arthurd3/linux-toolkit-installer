# lib/rust.sh — install the Rust toolchain via rustup and verify it builds.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh, lib/pkg.sh, lib/sudo.sh.
# Sourced after lib/sudo.sh in install.sh (uses _sudo_user, and
# pm_require_privileges can bootstrap a missing sudo before any privileged step).
#
# rustup is the official toolchain manager: uniform across distros, trivial to
# update (`rustup update`), and able to switch stable/beta/nightly. We install
# the distro `rustup` package first and fall back to the official installer
# (https://sh.rustup.rs) where no package exists (e.g. older Debian). Then we set
# `stable` as the default toolchain (rustc, cargo, clippy, rustfmt) and add the
# rust-analyzer and rust-src components for editor/IDE support.
#
# Crucial: rustup is PER-USER — it writes to ~/.cargo and ~/.rustup — so every
# rustup/cargo command runs as the invoking user, never under sudo. Only the
# distro package (and curl, if needed) install with root. If the installer is
# itself run as root, we drop to the target user with `sudo -u`.
#
# Rust links final binaries with the system C compiler (cc); if it's missing we
# point the user at `./install.sh --cpp` (we never install it from here).
#
# Public contract:
#   rust_diagnose  read-only: report the toolchain's state + the C-linker dep; rc 1 if unhealthy.
#   rust_setup     interactive: diagnose, then install rustup + stable + components + verify.
# Private helpers:
#   _rust_pkg <family>              distro rustup package name for a family
#   _rust_has <cmd>                 is <cmd> on PATH? (overridable probe; tests redefine)
#   _rust_report <level> <label> [detail]   one colored [OK]/[WARN]/[FAIL] line
#   _rust_probe <label> <cmd...>    report on the first present command (rc 0 if any found)
#   _rust_user_home                 home dir of the invoking (target) user
#   _rust_bin                       an invokable rustup (PATH, else ~/.cargo/bin)
#   _rust_as_user <argv...>         run as the invoking user (drop root); print in --dry-run
#   _rust_install_via_script        official rustup installer fallback (as the user)
#   _rust_ensure_toolchain          install + default the stable toolchain
#   _rust_verify                    rustc/cargo versions + a scratch `cargo build` (best-effort)

[[ -n ${_LTI_RUST_SH:-} ]] && return 0
_LTI_RUST_SH=1

# --- overridable probe ------------------------------------------------------

# Is <cmd> on PATH? Every "is rustup/rustc/cc… present?" decision goes through
# this one seam so tests can force a tool absent without a real one on PATH
# shadowing the mocks (mirrors lib/sudo.sh's _sudo_have_* probes).
_rust_has() { command -v "$1" >/dev/null 2>&1; }

# --- pure helpers -----------------------------------------------------------

# Pure: the distro's rustup package. Same name on every supported family; the
# fallback installer covers distros/versions that don't ship it. Non-zero for an
# unknown family. Ends with return 0.
_rust_pkg() {
    case "$1" in
        debian|fedora|arch|suse) printf 'rustup\n' ;;
        *) return 1 ;;
    esac
    return 0
}

# Print one colored status line. <level> = ok | warn | fail. Returns 0 for ok,
# 1 otherwise so callers tally issues via `|| n=$((n+1))`.
_rust_report() {
    local level=$1 label=$2 detail=${3:-} tag col
    case "$level" in
        ok)   tag='[OK]  '; col=${C_GREEN:-} ;;
        warn) tag='[WARN]'; col=${C_YELLOW:-} ;;
        *)    tag='[FAIL]'; col=${C_RED:-} ;;
    esac
    printf '%s%s%s %s%s\n' "$col" "$tag" "${C_RESET:-}" "$label" "${detail:+ — $detail}"
    [[ $level == ok ]]
}

# Report on the first present of the given commands. OK (with `--version`'s first
# line, or just "present") if any is found, FAIL otherwise. Returns 0 only when
# present. Read-only; safe under set -e.
_rust_probe() {
    local label=$1; shift
    local c ver
    for c in "$@"; do
        if _rust_has "$c"; then
            ver=$("$c" --version 2>/dev/null | head -n1 || true)
            _rust_report ok "$label" "${ver:-$c present}"
            return 0
        fi
    done
    _rust_report fail "$label" "not found (tried: $*)"
    return 1
}

# --- user-scoped execution --------------------------------------------------

# Echo the home directory of the user rustup should install for: the invoking
# user's when we're that user, or the target user's (from passwd) when the
# installer is running as root. Always returns 0.
_rust_user_home() {
    local user
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        user=$(_sudo_user)
        if [[ -n $user && $user != root ]]; then
            getent passwd "$user" 2>/dev/null | cut -d: -f6 || true
            return 0
        fi
    fi
    printf '%s\n' "${HOME:-}"
    return 0
}

# Echo an invokable rustup: the one on PATH, else the per-user ~/.cargo/bin one
# (present right after the official installer, before the shell re-sources PATH).
# Falls back to the bare name (which will fail loudly if truly absent). Always 0.
_rust_bin() {
    local p home
    if p=$(command -v rustup 2>/dev/null); then printf '%s\n' "$p"; return 0; fi
    home=$(_rust_user_home)
    if [[ -n $home && -x $home/.cargo/bin/rustup ]]; then
        printf '%s\n' "$home/.cargo/bin/rustup"; return 0
    fi
    printf 'rustup\n'
    return 0
}

# Run a command as the invoking (non-root) user. rustup/cargo must NOT run under
# root: they write to ~/.cargo + ~/.rustup. When the installer itself runs as
# root (e.g. `sudo ./install.sh`), drop to the target user with `sudo -u -H`.
# In --dry-run, print and change nothing.
_rust_as_user() {
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s (as %s) %s\n' "${C_DIM:-}" "${C_RESET:-}" "$(_sudo_user)" "$*"
        return 0
    fi
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        local user; user=$(_sudo_user)
        if [[ -n $user && $user != root ]]; then
            sudo -u "$user" -H "$@"
            return
        fi
    fi
    "$@"
}

# --- install ----------------------------------------------------------------

# Fallback path: the official rustup installer, run as the invoking user (never
# root). Needs curl; installs it through the PM if missing. Returns non-zero if
# rustup could not be bootstrapped.
_rust_install_via_script() {
    if ! _rust_has curl; then
        pm_require_privileges
        pm_install curl || { error "curl is required for the rustup installer but could not be installed."; return 1; }
    fi
    info "Running the official rustup installer (https://sh.rustup.rs) as $(_sudo_user)…"
    _rust_as_user sh -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
}

# Install + set the stable toolchain as default (as the user). `rustup default
# stable` both installs and selects it, and is idempotent. Some distro packages
# ship only a `rustup-init` shim that must run once first. Returns non-zero if
# the stable toolchain could not be laid down.
_rust_ensure_toolchain() {
    local rustup; rustup=$(_rust_bin)
    if _rust_as_user "$rustup" default stable; then
        return 0
    fi
    if _rust_has rustup-init; then
        _rust_as_user rustup-init -y --no-modify-path || return 1
        _rust_as_user "$rustup" default stable
        return
    fi
    return 1
}

# Best-effort post-setup checks: rustc/cargo versions + a real `cargo build` in a
# scratch crate (the manual `cargo new … && cargo run` check). Runs as the user.
# Never fatal. The caller skips this under --dry-run.
_rust_verify() {
    if _rust_has rustc; then
        ok "rustc: $(_rust_as_user rustc --version 2>/dev/null | head -n1 || true)"
    else
        warn "rustc not on PATH yet — open a new shell or 'source \"\$HOME/.cargo/env\"'."
        return 0
    fi
    _rust_has cargo \
        && ok "cargo: $(_rust_as_user cargo --version 2>/dev/null | head -n1 || true)"

    local tmp
    tmp=$(mktemp -d) || { warn "could not create a temp dir for the build test."; return 0; }
    lti_register_tmp "$tmp"
    printf '%s\n' '[package]' 'name = "smoke"' 'version = "0.1.0"' 'edition = "2021"' '' '[dependencies]' >"$tmp/Cargo.toml"
    mkdir -p "$tmp/src"
    printf 'fn main() { println!("ok"); }\n' >"$tmp/src/main.rs"
    # When running as root for another user, hand the scratch dir to them so the
    # unprivileged `cargo build` can write its target/ there.
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        local u; u=$(_sudo_user)
        [[ -n $u && $u != root ]] && chown -R "$u" "$tmp" 2>/dev/null || true
    fi
    if _rust_as_user env CARGO_TARGET_DIR="$tmp/target" cargo build --quiet --manifest-path "$tmp/Cargo.toml" >/dev/null 2>&1; then
        ok "cargo build works (compiled a scratch crate)."
    else
        warn "cargo build test failed — try 'source \"\$HOME/.cargo/env\"' and re-run '--rust-check'."
    fi
    return 0
}

# --- public entrypoints -----------------------------------------------------

# Read-only health report: rustup/rustc/cargo/clippy/rustfmt/rust-analyzer, plus
# the C-linker dependency. No root, changes nothing. Returns 0 if healthy, 1 if
# any piece is missing (so `--rust-check` can signal via exit code).
rust_diagnose() {
    banner "Rust toolchain health"
    local issues=0

    _rust_probe "rustup  " rustup                     || issues=$((issues + 1))
    _rust_probe "rustc   " rustc                       || issues=$((issues + 1))
    _rust_probe "cargo   " cargo                       || issues=$((issues + 1))
    _rust_probe "clippy  " cargo-clippy clippy-driver  || issues=$((issues + 1))
    _rust_probe "rustfmt " rustfmt                     || issues=$((issues + 1))
    _rust_probe "analyzer" rust-analyzer               || issues=$((issues + 1))

    # Rust links final binaries with the system C compiler. Warn (don't hard-
    # fail) if it's absent — the C/C++ module provides it.
    if _rust_has cc || _rust_has gcc; then
        _rust_report ok "linker  " "C linker (cc) present" || true
    else
        _rust_report warn "linker  " "no 'cc' — Rust needs it to link; run './install.sh --cpp' first" || issues=$((issues + 1))
    fi

    say ""
    if (( issues == 0 )); then
        ok "Rust toolchain looks complete — no issues found."
    else
        warn "$issues item(s) missing — run './install.sh --rust' to install them."
    fi
    (( issues == 0 ))
}

rust_setup() {
    banner "Set up Rust toolchain"

    local family=${DISTRO_FAMILY:-unknown} pkg user
    if ! pkg=$(_rust_pkg "$family"); then
        error "Unsupported distro family '$family' for the Rust toolchain."
        return 1
    fi
    user=$(_sudo_user)

    # Diagnose first so the user sees what's missing before we touch anything.
    rust_diagnose || true
    say ""

    if _rust_has rustup; then
        info "rustup is already installed — ensuring the stable toolchain + components."
    else
        info "This will install Rust via rustup (the official toolchain manager):"
        say  "  - package:    $pkg  (falls back to https://sh.rustup.rs if unavailable)"
        say  "  - toolchain:  stable — rustc, cargo, clippy, rustfmt"
        say  "  - components: rust-analyzer, rust-src"
        say  "  - installs into ~/.cargo + ~/.rustup for ${user} (per-user, not system-wide)"
    fi
    say ""
    confirm "Install / update the Rust toolchain now?" || return 0

    # 1. Ensure the rustup binary: distro package first, official script fallback.
    if ! _rust_has rustup; then
        pm_require_privileges       # no-op under root/dry-run; bootstraps sudo
        pm_refresh || warn "package index refresh failed; continuing."
        if ! pm_install "$pkg"; then
            warn "the '$pkg' package is unavailable here — using the official rustup installer."
            _rust_install_via_script || { error "Could not install rustup."; return 1; }
        fi
    fi

    # 2. Install + default to the stable toolchain (as the user, never root).
    if ! _rust_ensure_toolchain; then
        error "Could not install the stable Rust toolchain. Try: source \"\$HOME/.cargo/env\" && rustup default stable"
        return 1
    fi

    # 3. Editor/analysis components (clippy + rustfmt are in the default profile).
    _rust_as_user "$(_rust_bin)" component add rust-analyzer rust-src \
        || warn "could not add the rust-analyzer/rust-src components (continuing)."

    ok "Rust toolchain is set up (stable, with rust-analyzer + rust-src)."
    info "Open a new shell, or run:  source \"\$HOME/.cargo/env\"  to put cargo/rustc on PATH now."
    if ! _rust_has cc && ! _rust_has gcc; then
        warn "No C linker (cc) found — Rust needs it to link binaries. Run './install.sh --cpp'."
    fi

    # 4. Verify (real mode only — nothing was installed under --dry-run).
    (( DRY_RUN )) || _rust_verify
    return 0
}
