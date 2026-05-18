# Package-Manager Detection Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the package manager from the binary actually installed (with the distro name only as a hint), instead of inferring it from the distro name and dying when wrong.

**Architecture:** Decouple a logical PM (`PM_NAME` ∈ `apt|dnf|pacman|zypper`, drives command shape + bundle column) from the concrete binary (`PM_BIN`, e.g. `apt-get`/`dnf5`/`yum`). A new `pm_detect()` in `lib/pkg.sh` probes `PATH`, keeps the family as a hint, adopts an available PM (re-pointing `DISTRO_FAMILY`) when the detected family's PM is absent or the family is `unknown`, never auto-switches an explicit `LTI_FORCE_FAMILY`, and is fatal only when no known PM exists. `lib/distro.sh` is untouched.

**Tech Stack:** Pure Bash (zero deps), bats test artifacts, mock PM binaries, os-release fixtures. Spec: `docs/superpowers/specs/2026-05-18-pm-detection-robustness-design.md`.

---

## Environment note (read before running any verification)

The dev machine is Ubuntu 24.04 with **no `bats` and no `shellcheck`** installed. The project convention (see `docs/ARCHITECTURE.md` "Verification convention") is:

- `bash -n` is the always-on syntax floor.
- bats logic is validated locally via an **equivalent inline bash harness** (a shell function you paste once and call); the `.bats` file is the durable artifact for contributors who have bats and for `bash tests/run.sh` (which SKIPs bats cleanly when absent).
- `make check` runs `bash tests/run.sh` + a `--dry-run` smoke across the four forced families and must stay green.

Every test step below therefore gives **both** the bats artifact and a runnable inline command with exact expected output. The inline command is the authoritative local gate.

Paste this helper once at the repo root (`/home/arthurd3/Desktop/linux-toolkit-installer`) before the test steps that use `ltichk`:

```bash
ltichk() {  # usage: ltichk <force:fam|osrel:fixture> "<bins>" [dry=1]
  local mode=$1 bins=$2 dry=${3:-1} t b f="" o=""; t=$(mktemp -d)
  for b in $bins; do [ -n "$b" ] && ln -s "$PWD/tests/mocks/bin/$b" "$t/$b"; done
  case $mode in
    force:*) f=${mode#force:} ;;
    osrel:*) o="$PWD/tests/mocks/os-release/${mode#osrel:}" ;;
  esac
  LTI_ROOT="$PWD" LTI_FORCE_FAMILY="$f" OS_RELEASE_PATH="$o" DRY_RUN="$dry" TMPBIN="$t" \
  bash -c 'source "$LTI_ROOT/lib/core.sh"; source "$LTI_ROOT/lib/ui.sh"; source "$LTI_ROOT/lib/distro.sh"; source "$LTI_ROOT/lib/pkg.sh"; PATH="$TMPBIN"; detect_distro_family; pm_init; echo "NAME=${PM_NAME:-} BIN=${PM_BIN:-} FAM=${DISTRO_FAMILY:-}"' 2>&1
  local rc=$?; rm -rf "$t"; echo "rc=$rc"
}
```

`PATH` is restricted to `$TMPBIN` only *after* the libs are sourced, so probes see exactly the mock binaries you symlinked and nothing from the real system. Sourcing needs no external command because `LTI_ROOT` is preset (skips the realpath/readlink path in `core.sh`).

---

## File structure

| File | Change | Responsibility |
|------|--------|----------------|
| `tests/mocks/bin/yum` | create | argv-capturing mock for `yum` |
| `tests/mocks/bin/dnf5` | create | argv-capturing mock for `dnf5` |
| `lib/pkg.sh` | modify | add resolution helpers + `pm_detect`; rewrite `pm_init`; route `pm_refresh`/`pm_install` through `$PM_BIN`; update header doc |
| `tests/test_pkg_detect.bats` | create | covers `pm_detect` behaviors (new file keeps the existing `tests/test_pkg.bats` pristine as the backward-compat argv guard) |
| `docs/ARCHITECTURE.md` | modify | document `PM_NAME` vs `PM_BIN` + resolution order |
| `docs/DISTROS.md` | modify | document binary candidates, adoption, `unknown` no longer hard-fails |

`tests/test_pkg.bats` and `lib/distro.sh` are intentionally **not** modified.

---

## Task 1: Mock binaries for `yum` and `dnf5`

**Files:**
- Create: `tests/mocks/bin/yum`
- Create: `tests/mocks/bin/dnf5`

- [ ] **Step 1: Create the `yum` mock**

Create `tests/mocks/bin/yum` with exactly:

```bash
#!/usr/bin/env bash
echo "yum $*" >> "${LTI_TEST_CAPTURE:-/dev/null}"
exit 0
```

- [ ] **Step 2: Create the `dnf5` mock**

Create `tests/mocks/bin/dnf5` with exactly:

```bash
#!/usr/bin/env bash
echo "dnf5 $*" >> "${LTI_TEST_CAPTURE:-/dev/null}"
exit 0
```

- [ ] **Step 3: Make them executable**

Run:

```bash
chmod +x tests/mocks/bin/yum tests/mocks/bin/dnf5
```

- [ ] **Step 4: Verify they mirror the `dnf` mock**

Run:

```bash
ls -l tests/mocks/bin/dnf tests/mocks/bin/dnf5 tests/mocks/bin/yum
LTI_TEST_CAPTURE=/dev/stdout tests/mocks/bin/yum install -y foo; echo "exit=$?"
LTI_TEST_CAPTURE=/dev/stdout tests/mocks/bin/dnf5 makecache; echo "exit=$?"
```

Expected: all three files have the `x` permission bit; output contains `yum install -y foo` then `exit=0`, and `dnf5 makecache` then `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/mocks/bin/yum tests/mocks/bin/dnf5
git commit -m "test: add yum and dnf5 package-manager mocks"
```

---

## Task 2: Resolution helpers + `pm_detect` + `pm_init` rewrite

**Files:**
- Create: `tests/test_pkg_detect.bats`
- Modify: `lib/pkg.sh` (header lines 1-13; insert helpers + `pm_detect` after `_pm_run` which ends at line 22; replace `pm_init` lines 24-51)

- [ ] **Step 1: Write the failing test file**

Create `tests/test_pkg_detect.bats` with exactly:

```bash
#!/usr/bin/env bats
# Unit tests for lib/pkg.sh resolution (pm_detect): logical PM_NAME vs concrete
# PM_BIN, forced-family lock, cross-family adoption, unknown fallback.
# Nothing real is installed; only mock PM binaries are exposed on a clean PATH.

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# _resolve <mode> <bins> [dry]
#   mode = force:<family> | osrel:<fixture>
#   bins = space-separated mock PM binaries to expose (e.g. "yum")
#   dry  = DRY_RUN (default 1)
# Prints "NAME=<PM_NAME> BIN=<PM_BIN> FAM=<DISTRO_FAMILY>" plus any WARN/FATAL
# (stderr merged). Exits with pm_init's status.
_resolve() {
    local mode=$1 bins=$2 dry=${3:-1} t b f="" o=""
    t="$(mktemp -d)"
    for b in $bins; do
        [ -n "$b" ] && ln -s "$LTI_ROOT/tests/mocks/bin/$b" "$t/$b"
    done
    case "$mode" in
        force:*) f="${mode#force:}" ;;
        osrel:*) o="$LTI_ROOT/tests/mocks/os-release/${mode#osrel:}" ;;
    esac
    LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY="$f" OS_RELEASE_PATH="$o" \
    DRY_RUN="$dry" TMPBIN="$t" bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/ui.sh"
        source "$LTI_ROOT/lib/distro.sh"
        source "$LTI_ROOT/lib/pkg.sh"
        PATH="$TMPBIN"
        detect_distro_family
        pm_init
        echo "NAME=${PM_NAME:-} BIN=${PM_BIN:-} FAM=${DISTRO_FAMILY:-}"
    ' 2>&1
    local rc=$?
    rm -rf "$t"
    return $rc
}

@test "fedora forced, only yum present -> PM_BIN=yum" {
    run _resolve force:fedora yum
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=dnf BIN=yum FAM=fedora"* ]]
}

@test "fedora forced, only dnf5 present -> PM_BIN=dnf5" {
    run _resolve force:fedora dnf5
    [[ "$output" == *"NAME=dnf BIN=dnf5 FAM=fedora"* ]]
}

@test "fedora forced, dnf+dnf5+yum -> prefers dnf" {
    run _resolve force:fedora "dnf dnf5 yum"
    [[ "$output" == *"NAME=dnf BIN=dnf FAM=fedora"* ]]
}

@test "fedora forced, only dnf -> PM_BIN=dnf (backward-compat)" {
    run _resolve force:fedora dnf
    [[ "$output" == *"NAME=dnf BIN=dnf FAM=fedora"* ]]
}

@test "debian forced, only dnf, dry-run -> nominal apt-get, NOT switched" {
    run _resolve force:debian dnf 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=apt BIN=apt-get FAM=debian"* ]]
    [[ "$output" == *"WARN:"* ]]
}

@test "debian forced, only dnf, non-dry-run -> fatal exit 2 (locked)" {
    run _resolve force:debian dnf 0
    [ "$status" -eq 2 ]
    [[ "$output" == *"forced family 'debian'"* ]]
}

@test "os-release debian, only dnf -> adopts dnf, family re-pointed to fedora" {
    run _resolve osrel:debian dnf 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=dnf BIN=dnf FAM=fedora"* ]]
    [[ "$output" == *"WARN: os-release indicates 'debian'"* ]]
}

@test "unknown os-release, apt-get present -> adopts apt/debian" {
    run _resolve osrel:unknown apt-get 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=apt BIN=apt-get FAM=debian"* ]]
}

@test "unknown os-release, no PM, non-dry-run -> fatal exit 2" {
    run _resolve osrel:unknown "" 0
    [ "$status" -eq 2 ]
    [[ "$output" == *"No supported package manager found"* ]]
}

@test "unknown os-release, no PM, dry-run -> warn, nominal apt-get, no crash" {
    run _resolve osrel:unknown "" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=apt BIN=apt-get FAM=debian"* ]]
    [[ "$output" == *"WARN: no supported package manager found"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

bats is not installed locally; use the inline harness. Paste the `ltichk` function from the "Environment note" section, then run:

```bash
ltichk force:fedora yum
```

Expected (FAIL — pre-implementation): a line like `NAME=dnf BIN= FAM=fedora` (note the **empty** `BIN=`, because `PM_BIN` and `pm_detect` do not exist yet) and `rc=0`. The target is `NAME=dnf BIN=yum FAM=fedora`, so this is the expected red.

- [ ] **Step 3: Update the `lib/pkg.sh` header**

In `lib/pkg.sh`, replace the header block (lines 1-13, from `# lib/pkg.sh — package-manager abstraction` through `_LTI_PKG_SH=1`) with:

```bash
# lib/pkg.sh — package-manager abstraction over apt/dnf/pacman/zypper.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh (DISTRO_FAMILY set).
#
# Two concepts:
#   PM_NAME  logical PM (drives command shape + bundle column):
#            apt | dnf | pacman | zypper
#   PM_BIN   concrete executable actually invoked (apt-get, dnf5, yum, ...)
#
# Public contract (bundle.sh depends only on these):
#   pm_detect              resolve PM_NAME + PM_BIN; may re-point DISTRO_FAMILY
#   pm_init                call pm_detect, set SUDO, export PM_NAME/PM_BIN/SUDO
#   pm_require_privileges  validate sudo up front (no-op in --dry-run / root)
#   pm_refresh             update the package index once per run
#   pm_is_installed <pkg>  0 if installed, 1 otherwise (never trips set -e)
#   pm_install <pkg...>    install packages (prints, doesn't run, in --dry-run)

[[ -n ${_LTI_PKG_SH:-} ]] && return 0
_LTI_PKG_SH=1
```

- [ ] **Step 4: Insert resolution helpers + `pm_detect`**

In `lib/pkg.sh`, immediately **after** the `_pm_run()` function (its closing `}`, currently line 22) and **before** `pm_init()`, insert:

```bash

# --- PM resolution: logical PM vs concrete binary ---------------------------

# Logical PM a distro family prefers. Non-zero if family unknown.
_pm_logical_for_family() {
    case "$1" in
        debian) printf 'apt\n' ;;
        fedora) printf 'dnf\n' ;;
        arch)   printf 'pacman\n' ;;
        suse)   printf 'zypper\n' ;;
        *)      return 1 ;;
    esac
}

# Family that owns a logical PM (inverse of the above).
_pm_family_for_logical() {
    case "$1" in
        apt)    printf 'debian\n' ;;
        dnf)    printf 'fedora\n' ;;
        pacman) printf 'arch\n' ;;
        zypper) printf 'suse\n' ;;
        *)      return 1 ;;
    esac
}

# Ordered concrete-binary candidates for a logical PM.
_pm_candidates() {
    case "$1" in
        apt)    printf 'apt-get apt\n' ;;
        dnf)    printf 'dnf dnf5 yum\n' ;;
        pacman) printf 'pacman\n' ;;
        zypper) printf 'zypper\n' ;;
        *)      return 1 ;;
    esac
}

# Echo the first of the given binaries found on PATH; non-zero if none.
# Ends with an explicit return (set -e safe in any caller).
_pm_first_present() {
    local b
    for b in "$@"; do
        if command -v "$b" >/dev/null 2>&1; then
            printf '%s\n' "$b"
            return 0
        fi
    done
    return 1
}

# Scan logical PMs by fixed priority (apt, dnf, pacman, zypper); echo
# "<logical> <bin>" for the first whose binary is present. Non-zero if none.
_pm_any_present() {
    local lp bin
    for lp in apt dnf pacman zypper; do
        # shellcheck disable=SC2046  # intentional word-split of the candidate list
        if bin=$(_pm_first_present $(_pm_candidates "$lp")); then
            printf '%s %s\n' "$lp" "$bin"
            return 0
        fi
    done
    return 1
}

# Resolve PM_NAME + PM_BIN from the distro family (a hint) and what is actually
# installed. May re-point DISTRO_FAMILY when adopting an available PM (never
# for an explicit LTI_FORCE_FAMILY). Fatal only if nothing usable exists and
# not --dry-run.
pm_detect() {
    local hint=${DISTRO_FAMILY:-unknown}
    local logical bin pair

    # 1. Forced family: locked. Resolve its binary; never auto-switch.
    if [[ -n ${LTI_FORCE_FAMILY:-} ]]; then
        logical=$(_pm_logical_for_family "$hint") \
            || lti_fatal "pm_detect: forced family '$hint' has no package manager." 2
        # shellcheck disable=SC2046  # intentional word-split of the candidate list
        if bin=$(_pm_first_present $(_pm_candidates "$logical")); then
            PM_NAME=$logical; PM_BIN=$bin
            return 0
        fi
        if (( DRY_RUN )); then
            PM_NAME=$logical
            PM_BIN=$(_pm_candidates "$logical"); PM_BIN=${PM_BIN%% *}
            warn "package manager for forced family '$hint' not found — continuing because --dry-run (using '$PM_BIN' nominally)."
            return 0
        fi
        lti_fatal "Package manager for forced family '$hint' not found (looked for: $(_pm_candidates "$logical"))." 2
    fi

    # 2. Detected family with its own PM present → use it (family unchanged).
    if logical=$(_pm_logical_for_family "$hint"); then
        # shellcheck disable=SC2046  # intentional word-split of the candidate list
        if bin=$(_pm_first_present $(_pm_candidates "$logical")); then
            PM_NAME=$logical; PM_BIN=$bin
            return 0
        fi
        # 3. Its PM is absent → adopt an available one and re-point family.
        if pair=$(_pm_any_present); then
            PM_NAME=${pair%% *}; PM_BIN=${pair##* }
            DISTRO_FAMILY=$(_pm_family_for_logical "$PM_NAME")
            warn "os-release indicates '$hint' but its package manager is not installed; using '$PM_BIN' ($DISTRO_FAMILY) which is present."
            return 0
        fi
    else
        # 4. Unknown family → adopt the first present PM by priority.
        if pair=$(_pm_any_present); then
            PM_NAME=${pair%% *}; PM_BIN=${pair##* }
            DISTRO_FAMILY=$(_pm_family_for_logical "$PM_NAME")
            info "No recognized distro; using '$PM_BIN' ($DISTRO_FAMILY) found on PATH."
            return 0
        fi
    fi

    # 5. Nothing usable.
    if (( DRY_RUN )); then
        if logical=$(_pm_logical_for_family "$hint"); then
            PM_NAME=$logical
        else
            PM_NAME=apt; DISTRO_FAMILY=debian
        fi
        PM_BIN=$(_pm_candidates "$PM_NAME"); PM_BIN=${PM_BIN%% *}
        warn "no supported package manager found — continuing because --dry-run (using '$PM_BIN' nominally)."
        return 0
    fi
    lti_fatal "No supported package manager found (looked for: apt-get apt dnf dnf5 yum pacman zypper)." 2
}
```

- [ ] **Step 5: Replace `pm_init`**

In `lib/pkg.sh`, replace the entire current `pm_init()` function (currently lines 24-51, from `pm_init() {` through its closing `}` that contains `export PM_NAME SUDO`) with:

```bash
pm_init() {
    pm_detect    # sets PM_NAME, PM_BIN; may re-point DISTRO_FAMILY

    # sudo prefix; real validation deferred to pm_require_privileges.
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
    export PM_NAME PM_BIN SUDO
}
```

- [ ] **Step 6: Syntax check**

Run:

```bash
bash -n lib/pkg.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 7: Run the resolution checks to verify they pass**

Re-paste `ltichk` if needed (it sources the modified `lib/pkg.sh` fresh each call), then run each line and compare to the expected result:

```bash
ltichk force:fedora yum            # NAME=dnf BIN=yum FAM=fedora     rc=0
ltichk force:fedora dnf5           # NAME=dnf BIN=dnf5 FAM=fedora    rc=0
ltichk force:fedora "dnf dnf5 yum" # NAME=dnf BIN=dnf FAM=fedora     rc=0
ltichk force:fedora dnf            # NAME=dnf BIN=dnf FAM=fedora     rc=0
ltichk force:debian dnf 1          # NAME=apt BIN=apt-get FAM=debian + WARN  rc=0
ltichk force:debian dnf 0          # FATAL ... forced family 'debian' ...    rc=2
ltichk osrel:debian dnf 1          # NAME=dnf BIN=dnf FAM=fedora + WARN os-release indicates 'debian'  rc=0
ltichk osrel:unknown apt-get 1     # NAME=apt BIN=apt-get FAM=debian rc=0
ltichk osrel:unknown "" 0          # FATAL No supported package manager found  rc=2
ltichk osrel:unknown "" 1          # NAME=apt BIN=apt-get FAM=debian + WARN no supported package manager  rc=0
```

Expected: each line's stdout contains the `NAME=… BIN=… FAM=…` shown (and the noted `WARN:`/`FATAL:` text), with the noted `rc=`. All ten must match. If bats is available, also run `bats tests/test_pkg_detect.bats` and expect all tests to pass.

- [ ] **Step 8: Confirm existing suite untouched (backward-compat)**

The existing `tests/test_pkg.bats` still uses the old literal-binary `pm_refresh`/`pm_install` (changed in Task 3); after Task 2 those functions are unchanged, so argv is identical. Sanity-check the resolver picks the canonical binary when present:

```bash
ltichk force:debian apt-get        # NAME=apt BIN=apt-get FAM=debian rc=0
ltichk force:arch pacman           # NAME=pacman BIN=pacman FAM=arch rc=0
ltichk force:suse zypper           # NAME=zypper BIN=zypper FAM=suse rc=0
bash tests/run.sh
```

Expected: the three `ltichk` lines match; `bash tests/run.sh` ends with `RESULT: OK` (shellcheck/bats SKIPPED lines are informational, not failures).

- [ ] **Step 9: Commit**

```bash
git add lib/pkg.sh tests/test_pkg_detect.bats
git commit -m "feat: resolve package manager from installed binary, not distro name"
```

---

## Task 3: Route `pm_refresh` / `pm_install` through `$PM_BIN`

**Files:**
- Modify: `lib/pkg.sh` (`pm_refresh`, `pm_install` — currently lines 69-83 and 105-117)
- Modify: `tests/test_pkg_detect.bats` (add an argv test)

- [ ] **Step 1: Add the failing argv test**

Append this test to the end of `tests/test_pkg_detect.bats`:

```bash
@test "pm_install/pm_refresh argv use resolved PM_BIN (fedora/yum)" {
    local t; t="$(mktemp -d)"
    ln -s "$LTI_ROOT/tests/mocks/bin/yum" "$t/yum"
    run env LTI_ROOT="$LTI_ROOT" LTI_FORCE_FAMILY=fedora DRY_RUN=1 TMPBIN="$t" \
        bash -c '
            source "$LTI_ROOT/lib/core.sh"
            source "$LTI_ROOT/lib/ui.sh"
            source "$LTI_ROOT/lib/distro.sh"
            source "$LTI_ROOT/lib/pkg.sh"
            PATH="$TMPBIN"
            detect_distro_family; pm_init
            pm_refresh
            pm_install foo bar
        '
    rm -rf "$t"
    [[ "$output" == *"[dry-run] sudo yum -y makecache"* ]]
    [[ "$output" == *"[dry-run] sudo yum install -y foo bar"* ]]
}
```

- [ ] **Step 2: Run it to verify it fails**

Inline equivalent (bats not installed):

```bash
t=$(mktemp -d); ln -s "$PWD/tests/mocks/bin/yum" "$t/yum"
LTI_ROOT="$PWD" LTI_FORCE_FAMILY=fedora DRY_RUN=1 TMPBIN="$t" bash -c '
  source "$LTI_ROOT/lib/core.sh"; source "$LTI_ROOT/lib/ui.sh"
  source "$LTI_ROOT/lib/distro.sh"; source "$LTI_ROOT/lib/pkg.sh"
  PATH="$TMPBIN"; detect_distro_family; pm_init; pm_refresh; pm_install foo bar'
rm -rf "$t"
```

Expected (FAIL — pre-implementation): output shows `[dry-run] sudo dnf -y makecache` and `[dry-run] sudo dnf install -y foo bar` (literal `dnf`, **not** `yum`, because `pm_refresh`/`pm_install` still hardcode the binary). Target is `yum`.

- [ ] **Step 3: Rewrite `pm_refresh`**

In `lib/pkg.sh`, replace the entire current `pm_refresh()` function (currently lines 69-83) with:

```bash
pm_refresh() {
    (( PM_REFRESHED )) && return 0
    local cmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    case "$PM_NAME" in
        apt)    cmd=( $SUDO "$PM_BIN" update ) ;;
        dnf)    cmd=( $SUDO "$PM_BIN" -y makecache ) ;;
        pacman) cmd=( $SUDO "$PM_BIN" -Sy --noconfirm ) ;;
        zypper) cmd=( $SUDO "$PM_BIN" --non-interactive refresh ) ;;
        *) error "pm_refresh: pm_init not called"; return 1 ;;
    esac
    info "Refreshing package index ($PM_BIN)..."
    _pm_run "${cmd[@]}"
    PM_REFRESHED=1
}
```

- [ ] **Step 4: Rewrite `pm_install`**

In `lib/pkg.sh`, replace the entire current `pm_install()` function (currently lines 105-117) with:

```bash
pm_install() {
    (( $# > 0 )) || return 0
    local cmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    case "$PM_NAME" in
        apt)    cmd=( $SUDO env DEBIAN_FRONTEND=noninteractive "$PM_BIN" install -y "$@" ) ;;
        dnf)    cmd=( $SUDO "$PM_BIN" install -y "$@" ) ;;
        pacman) cmd=( $SUDO "$PM_BIN" -S --needed --noconfirm "$@" ) ;;
        zypper) cmd=( $SUDO "$PM_BIN" --non-interactive install "$@" ) ;;
        *) error "pm_install: pm_init not called"; return 1 ;;
    esac
    _pm_run "${cmd[@]}"
}
```

`pm_is_installed` is intentionally left unchanged (it keys off `PM_NAME`; `rpm -q` already covers `dnf`/`dnf5`/`yum`).

- [ ] **Step 5: Syntax check**

Run:

```bash
bash -n lib/pkg.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 6: Run the argv test to verify it passes**

```bash
t=$(mktemp -d); ln -s "$PWD/tests/mocks/bin/yum" "$t/yum"
LTI_ROOT="$PWD" LTI_FORCE_FAMILY=fedora DRY_RUN=1 TMPBIN="$t" bash -c '
  source "$LTI_ROOT/lib/core.sh"; source "$LTI_ROOT/lib/ui.sh"
  source "$LTI_ROOT/lib/distro.sh"; source "$LTI_ROOT/lib/pkg.sh"
  PATH="$TMPBIN"; detect_distro_family; pm_init; pm_refresh; pm_install foo bar'
rm -rf "$t"
```

Expected (PASS): output contains `[dry-run] sudo yum -y makecache` and `[dry-run] sudo yum install -y foo bar`.

- [ ] **Step 7: Backward-compat — existing `tests/test_pkg.bats` argv unchanged**

The existing suite asserts exact argv for the four forced families with the canonical binary. Reproduce its assertions inline (on this Ubuntu box `apt-get` is real; `dnf`/`pacman`/`zypper` are absent so the dry-run nominal canonical name is used — identical to the old behavior):

```bash
_dry() { LTI_FORCE_FAMILY="$1" DRY_RUN=1 bash -c '
  source "'"$PWD"'/lib/core.sh"; source "'"$PWD"'/lib/ui.sh"
  source "'"$PWD"'/lib/distro.sh"; source "'"$PWD"'/lib/pkg.sh"
  detect_distro_family; pm_init; '"$2"'' 2>/dev/null; }
_dry debian 'pm_install foo bar'
_dry fedora 'pm_install foo bar'
_dry arch   'pm_install foo bar'
_dry suse   'pm_install foo bar'
_dry debian 'pm_refresh'
_dry arch   'pm_refresh'
```

Expected, in order, exactly:

```
[dry-run] sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y foo bar
[dry-run] sudo dnf install -y foo bar
[dry-run] sudo pacman -S --needed --noconfirm foo bar
[dry-run] sudo zypper --non-interactive install foo bar
[dry-run] sudo apt-get update
[dry-run] sudo pacman -Sy --noconfirm
```

These are byte-identical to what `tests/test_pkg.bats` asserts, confirming backward compatibility.

- [ ] **Step 8: Full harness + smoke**

Run:

```bash
bash tests/run.sh
make check
```

Expected: `bash tests/run.sh` ends with `RESULT: OK`. `make check` ends with `check: OK` (each of `debian fedora arch suse` prints `OK`).

- [ ] **Step 9: Commit**

```bash
git add lib/pkg.sh tests/test_pkg_detect.bats
git commit -m "feat: invoke the resolved PM_BIN in pm_refresh and pm_install"
```

---

## Task 4: Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/DISTROS.md`

- [ ] **Step 1: Update the `lib/pkg.sh` row in `docs/ARCHITECTURE.md`**

Replace this line (currently line 19):

```
| `lib/pkg.sh`    | `pm_init/pm_require_privileges/pm_refresh/pm_is_installed/pm_install` over apt/dnf/pacman/zypper; sudo strategy; dry-run | core, ui, distro |
```

with:

```
| `lib/pkg.sh`    | `pm_detect` (logical `PM_NAME` vs concrete `PM_BIN`), `pm_init/pm_require_privileges/pm_refresh/pm_is_installed/pm_install` over apt/dnf/pacman/zypper; sudo strategy; dry-run | core, ui, distro |
```

- [ ] **Step 2: Add a resolution section to `docs/ARCHITECTURE.md`**

Insert the following block immediately **before** the `## Data flow` line (currently line 23), followed by a blank line:

```
## Package-manager resolution (`lib/pkg.sh`)

The distro family is a *hint*; the package manager is chosen from what is
actually installed.

- `PM_NAME` — logical PM, drives command shape: `apt | dnf | pacman | zypper`.
- `PM_BIN` — the concrete binary invoked. Candidates, in order:
  - `apt` → `apt-get`, `apt`
  - `dnf` → `dnf`, `dnf5`, `yum`
  - `pacman` → `pacman`
  - `zypper` → `zypper`

`pm_detect` resolution order:

1. `LTI_FORCE_FAMILY` set → that family and its PM are locked (never
   auto-switched); a missing binary is fatal unless `--dry-run`.
2. Detected family whose PM is present → use it.
3. Detected family whose PM is absent but another known PM is present → adopt
   the present one and re-point `DISTRO_FAMILY` to its family (a `WARN` is
   printed; this changes which `*.bundle` column applies).
4. `unknown` family → adopt the first present PM by priority `apt, dnf,
   pacman, zypper`.
5. No known PM at all → fatal (exit 2), unless `--dry-run`.

`yum`/`dnf5` reuse the `dnf` command shape; `pm_is_installed` keys off
`PM_NAME` so `rpm -q` still covers all three.

```

- [ ] **Step 3: Update the family table in `docs/DISTROS.md`**

Replace the table block (currently lines 6-11):

```
| Family | Package manager | Detected from `ID` / `ID_LIKE` (examples) |
|--------|-----------------|-------------------------------------------|
| `debian` | `apt-get` | debian, ubuntu, linuxmint, pop, raspbian, elementary, kali, devuan, zorin |
| `fedora` | `dnf`     | fedora, rhel, centos, rocky, almalinux, ol, amzn, scientific |
| `arch`   | `pacman` (+ `yay` for AUR) | arch, manjaro, endeavouros, garuda, artix, cachyos |
| `suse`   | `zypper`  | opensuse-leap, opensuse-tumbleweed, sles, sled, suse |
```

with:

```
| Family | Package manager (binary, in order tried) | Detected from `ID` / `ID_LIKE` (examples) |
|--------|------------------------------------------|-------------------------------------------|
| `debian` | `apt-get`, `apt` | debian, ubuntu, linuxmint, pop, raspbian, elementary, kali, devuan, zorin |
| `fedora` | `dnf`, `dnf5`, `yum` | fedora, rhel, centos, rocky, almalinux, ol, amzn, scientific |
| `arch`   | `pacman` (+ `yay` for AUR) | arch, manjaro, endeavouros, garuda, artix, cachyos |
| `suse`   | `zypper`  | opensuse-leap, opensuse-tumbleweed, sles, sled, suse |
```

- [ ] **Step 4: Update the `unknown` outcome in `docs/DISTROS.md`**

Replace item 4 under "## Detection logic" (currently lines 18-19):

```
4. If nothing matches → `unknown`; `install.sh` exits with code `2` and a
   message listing the supported families and the `--force-family` override.
```

with:

```
4. If nothing matches → `unknown`. `lib/pkg.sh` then tries to adopt whatever
   supported package manager is actually on `PATH` (priority `apt, dnf,
   pacman, zypper`) and re-points the family accordingly. Only if no known
   package manager exists does the tool exit with code `2` (unless
   `--dry-run`).
```

- [ ] **Step 5: Add a resolution section to `docs/DISTROS.md`**

Insert the following block immediately **before** the `## Per-family commands` line (currently line 22), followed by a blank line:

```
## Package-manager resolution (`lib/pkg.sh`)

The family is only a hint. `pm_detect` picks the package manager from what is
installed:

- It probes `PATH` for the family's binary candidates in order — for
  `fedora`: `dnf` → `dnf5` → `yum` (all RPM-based, identical command shape).
- `LTI_FORCE_FAMILY` is never auto-switched: if its package manager is
  missing, that is fatal (exit 2) unless `--dry-run`.
- If a detected (os-release) family's package manager is absent but another
  supported one is present, that one is adopted and the family is re-pointed
  (a `WARN` explains the switch — it changes which `*.bundle` column applies).

```

- [ ] **Step 6: Note the binary vs canonical name under the commands table**

In `docs/DISTROS.md`, immediately **after** the line:

```
Privileged commands are prefixed with `sudo` (nothing if already root).
```

insert a blank line then:

```
The first column shows the canonical binary; the actually-invoked binary is
whatever `pm_detect` resolved (`PM_BIN`) — e.g. `yum`/`dnf5` for `fedora`.
```

- [ ] **Step 7: Verify docs render and nothing else broke**

Run:

```bash
grep -n "PM_BIN" docs/ARCHITECTURE.md docs/DISTROS.md
bash tests/run.sh
```

Expected: `grep` shows the new `PM_BIN` mentions in both files; `bash tests/run.sh` ends with `RESULT: OK`.

- [ ] **Step 8: Commit**

```bash
git add docs/ARCHITECTURE.md docs/DISTROS.md
git commit -m "docs: document PM_NAME vs PM_BIN resolution and adoption"
```

---

## Task 5: Final verification & memory

- [ ] **Step 1: Full gate**

Run:

```bash
bash -n install.sh lib/*.sh tests/run.sh && echo "syntax OK"
bash tests/run.sh
make check
```

Expected: `syntax OK`; `bash tests/run.sh` → `RESULT: OK`; `make check` → `check: OK`.

- [ ] **Step 2: Re-run every resolution scenario one last time**

Paste `ltichk` (from the Environment note) and run all ten lines from Task 2 Step 7 plus the three from Step 8; confirm every one matches its expected `NAME=/BIN=/FAM=`, `WARN:`/`FATAL:`, and `rc=`.

- [ ] **Step 3: Confirm commit hygiene**

Run:

```bash
git log --oneline -6
git log --format='%b' -5 | grep -i co-authored-by && echo "PROBLEM: co-author trailer" || echo "OK: no co-author trailer"
git status --porcelain
git rev-list --count origin/main..HEAD
```

Expected: the Task 1-4 commits are present in English Conventional-Commit style; `OK: no co-author trailer`; clean working tree; the unpushed-commit count is reported (do **not** push — surface the delta to the user and let them decide).

- [ ] **Step 4: Store the learning in Qdrant**

Use `mcp__qdrant-memory__qdrant-store` with metadata `project="linux-toolkit-installer"`, `collection="linux_toolkit_installer_architecture"` (and a second entry under `linux_toolkit_installer_conventions` if a reusable pattern emerged). Record: the `PM_NAME` (logical) vs `PM_BIN` (concrete) split; `pm_detect` order (forced-locked → family-PM → adopt+re-point+WARN → unknown adopt → fatal); fedora `dnf›dnf5›yum`; `pm_is_installed` unchanged because it keys on `PM_NAME`; the PATH-isolation test idiom (restrict `PATH` only after sourcing, with `LTI_ROOT` preset); and that `tests/test_pkg.bats` was deliberately kept as the untouched backward-compat argv guard while new behavior lives in `tests/test_pkg_detect.bats`.

---

## Self-review (completed during planning)

- **Spec coverage:** §1 data model → Task 2 Steps 3-5. §2 algorithm (all 5 cases incl. forced-lock) → Task 2 Step 4 + tests Step 1/7. §3 call sites → Task 2 Step 5 + Task 3 Steps 3-4. §4 error handling → encoded in `pm_detect` (fatal/exit 2, stderr `warn`, `set -e`-safe explicit returns). §5 tests/verification → Task 1, Task 2 Step 1, Task 3 Step 1, Tasks 4-5. Backward compatibility → Task 2 Step 8 + Task 3 Step 7. Docs → Task 4. Commit & memory → Task 5.
- **Placeholder scan:** none — every step has exact paths, full code, and exact expected output.
- **Type/name consistency:** `PM_NAME`, `PM_BIN`, `pm_detect`, `_pm_logical_for_family`, `_pm_family_for_logical`, `_pm_candidates`, `_pm_first_present`, `_pm_any_present` are used identically across all tasks; the bats helper `_resolve`/`ltichk` env contract (`LTI_ROOT`, `LTI_FORCE_FAMILY`, `OS_RELEASE_PATH`, `DRY_RUN`, `TMPBIN`) is consistent.
- **Spec consistency fix applied:** the forced-vs-adoption contradiction was corrected in the spec (commit `39656b9`) before this plan; Task 2's tests encode the corrected rule (forced = locked; adoption only for os-release-detected families).
