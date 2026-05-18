# Terminal Header Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain project banner shown by the interactive menu and `--list` with a block-letter `LTI` header plus a distro/family/counts/dry-run info band, keeping the zero-dependency guarantee and the clean plain-text fallback.

**Architecture:** Fully-decoupled. `lib/ui.sh` gets pure presentation (`_header_art`, `header`, `info_band`); `lib/distro.sh` gains a `DISTRO_PRETTY` global; `lib/bundle.sh` gains pure `bundle_count`/`tool_count`; `install.sh` gets a 3-line `show_header` composer that assembles the data and replaces the two project-banner call sites. `banner()`/`hr()` and `bundle_run()`'s contextual banner are untouched.

**Tech Stack:** Pure Bash 4+ (coreutils + system PM only, zero runtime deps). Tests authored as `bats` suites; `bats`/`shellcheck` are optional and absent on this machine.

**Spec:** `docs/superpowers/specs/2026-05-18-terminal-header-polish-design.md`

---

## Contract clarification (resolves spec §2 wording)

The spec §2 prose says `header` renders "...then the info band, then the closing rule", but the `show_header` composer calls `header` and `info_band` **separately**. The authoritative division for implementation is:

- **`header`** (no args) → the identity block only: art (fancy block `LTI` / plain `=== linux-toolkit-installer ===`) + name + tagline, terminated by **one blank line**. No band, no rule.
- **`info_band <distro> <family> <bundles> <tools> <dry_run>`** → the two band lines, **plus** the closing `─` rule **in fancy mode only** (plain mode: no rule).
- **`show_header`** = `header` then `info_band …`. Visual order: art → blank → band → (fancy) rule. This matches both rendering mockups in the spec.

## Verification approach (read once)

`bats` and `shellcheck` are **not installed** on this machine; `tests/run.sh` always runs `bash -n` and prints `SKIPPED` for the other two (still `RESULT: OK`). Per the project's established convention, every task therefore carries:

1. A durable **`.bats`** test (runs for contributors / wherever `bats` exists, via `make test`).
2. An **equivalent inline bash check** that reproduces the test's core assertion and prints `PASS`/`FAIL` — this is what actually runs here. "Verify it fails" = run it *before* implementing (expect `FAIL`/error); "verify it passes" = run it *after* (expect `PASS`).
3. `bash tests/run.sh` must end with `RESULT: OK` (confirms `bash -n` clean).

**Commit hygiene (every commit):** Conventional Commits in English, **no Claude co-author**, directly on `main`, **no push**. The working tree has unrelated untracked files (`tests/mocks/bin/dnf5`, `tests/mocks/bin/yum`) from another spec — **always `git add` explicit paths, never `git add -A`/`.`**.

---

## Task 1: `DISTRO_PRETTY` in `lib/distro.sh`

**Files:**
- Create: `tests/mocks/os-release/nopretty`
- Modify: `lib/distro.sh` (file-header comment; `detect_distro_family`)
- Test: `tests/test_distro.bats` (add cases; existing cases untouched)

- [ ] **Step 1: Create the no-`PRETTY_NAME` fixture**

Create `tests/mocks/os-release/nopretty` with exactly:

```
NAME="Frobnix"
VERSION_ID="9"
ID=debian
ID_LIKE=debian
```

- [ ] **Step 2: Write the failing bats cases**

Append to `tests/test_distro.bats` (keep everything already there; add this helper and these 4 `@test`s at the end):

```bash
# Detect family + pretty name from a given os-release fixture path.
_detect3() {
    OS_RELEASE_PATH="$1" bash -c '
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        detect_distro_family
        printf "%s|%s|%s\n" "$DISTRO_ID" "$DISTRO_FAMILY" "$DISTRO_PRETTY"
    '
}

@test "DISTRO_PRETTY from PRETTY_NAME (ubuntu)" {
    run _detect3 "$MOCKS/ubuntu"
    [ "$status" -eq 0 ]
    [ "$output" = "ubuntu|debian|Ubuntu 24.04 LTS" ]
}

@test "DISTRO_PRETTY falls back to NAME + VERSION_ID" {
    run _detect3 "$MOCKS/nopretty"
    [ "$status" -eq 0 ]
    [ "$output" = "debian|debian|Frobnix 9" ]
}

@test "DISTRO_PRETTY for forced family is the forced id" {
    run bash -c '
        LTI_FORCE_FAMILY=fedora
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/distro.sh"
        detect_distro_family
        printf "%s|%s|%s\n" "$DISTRO_ID" "$DISTRO_FAMILY" "$DISTRO_PRETTY"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "forced:fedora|fedora|forced:fedora" ]
}

@test "DISTRO_PRETTY is 'unknown' when os-release missing" {
    run _detect3 "$MOCKS/does-not-exist"
    [ "$status" -eq 0 ]
    [ "$output" = "|unknown|unknown" ]
}
```

- [ ] **Step 3: Verify it fails (inline equivalent — bats absent)**

Run:

```bash
OS_RELEASE_PATH=tests/mocks/os-release/ubuntu bash -c '
  source lib/core.sh; source lib/distro.sh; detect_distro_family
  [ "${DISTRO_PRETTY:-UNSET}" = "Ubuntu 24.04 LTS" ] && echo PASS || echo "FAIL: got [${DISTRO_PRETTY:-UNSET}]"'
```

Expected: `FAIL: got [UNSET]` (the variable does not exist yet).

- [ ] **Step 4: Implement `DISTRO_PRETTY`**

In `lib/distro.sh`, update the file-header comment block — change the "Sets two globals" section to:

```bash
# Sets three globals:
#   DISTRO_ID      raw ID= from os-release (or "forced:<f>")
#   DISTRO_FAMILY  one of: debian fedora arch suse unknown
#   DISTRO_PRETTY  human label: PRETTY_NAME -> NAME[+VERSION_ID] -> ID -> unknown
#                  (for a forced family this is DISTRO_ID, e.g. "forced:debian")
```

In `detect_distro_family`, change the reset block:

```bash
    DISTRO_ID=""
    DISTRO_FAMILY=""
```

to:

```bash
    DISTRO_ID=""
    DISTRO_FAMILY=""
    DISTRO_PRETTY=""
```

In the forced-family branch, after `DISTRO_FAMILY=$LTI_FORCE_FAMILY` and before `return 0`, add:

```bash
        DISTRO_PRETTY=$DISTRO_ID
```

Change the os-release parse loop's local declaration line:

```bash
    local id="" id_like="" line key val
```

to:

```bash
    local id="" id_like="" pretty="" nm="" ver="" line key val
```

Add three cases to the `case "$key" in` block (alongside `ID)` and `ID_LIKE)`):

```bash
                PRETTY_NAME) pretty=$val ;;
                NAME)        nm=$val ;;
                VERSION_ID)  ver=$val ;;
```

Immediately after the `DISTRO_ID=$id` line, add the fallback chain:

```bash
    if [[ -n $pretty ]]; then
        DISTRO_PRETTY=$pretty
    elif [[ -n $nm ]]; then
        DISTRO_PRETTY=${nm}${ver:+ $ver}
    elif [[ -n $id ]]; then
        DISTRO_PRETTY=$id
    else
        DISTRO_PRETTY=unknown
    fi
```

- [ ] **Step 5: Verify it passes**

Run:

```bash
for fx in 'ubuntu|Ubuntu 24.04 LTS' 'nopretty|Frobnix 9' 'debian|Debian GNU/Linux 12 (bookworm)'; do
  p=${fx%%|*}; want=${fx#*|}
  got=$(OS_RELEASE_PATH=tests/mocks/os-release/$p bash -c 'source lib/core.sh; source lib/distro.sh; detect_distro_family; printf "%s" "$DISTRO_PRETTY"')
  [ "$got" = "$want" ] && echo "PASS $p" || echo "FAIL $p: got [$got] want [$want]"
done
LTI_FORCE_FAMILY=fedora bash -c 'source lib/core.sh; source lib/distro.sh; detect_distro_family; [ "$DISTRO_PRETTY" = "forced:fedora" ] && echo "PASS forced" || echo "FAIL forced: [$DISTRO_PRETTY]"'
OS_RELEASE_PATH=/no/such bash -c 'source lib/core.sh; source lib/distro.sh; detect_distro_family; [ "$DISTRO_PRETTY" = "unknown" ] && echo "PASS missing" || echo "FAIL missing: [$DISTRO_PRETTY]"'
```

Expected: `PASS ubuntu`, `PASS nopretty`, `PASS debian`, `PASS forced`, `PASS missing`.

Then run: `bash tests/run.sh`
Expected: ends with `RESULT: OK (skipped tools are informational, not failures)`.

- [ ] **Step 6: Commit**

```bash
git add lib/distro.sh tests/test_distro.bats tests/mocks/os-release/nopretty
git commit -m "feat(distro): add DISTRO_PRETTY (PRETTY_NAME with fallbacks)"
```

---

## Task 2: `bundle_count` + `tool_count` in `lib/bundle.sh`

**Files:**
- Modify: `lib/bundle.sh` (add two pure helpers after `bundle_list`)
- Test: `tests/test_bundle_parse.bats` (add cases; existing untouched)

- [ ] **Step 1: Write the failing bats cases**

Append to `tests/test_bundle_parse.bats`:

```bash
@test "bundle_count and tool_count over a controlled bundles dir" {
    run bash -c '
        tmp=$(mktemp -d)
        mkdir "$tmp/bundles"
        cp "'"$SAMPLE"'" "$tmp/bundles/one.bundle"
        export LTI_ROOT="$tmp"
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT" 2>/dev/null || true
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        printf "%s|%s\n" "$(bundle_count)" "$(tool_count)"
        rm -rf "$tmp"
    '
    [ "$output" = "1|6" ]
}

@test "bundle_count and tool_count are 0 for an empty bundles dir" {
    run bash -c '
        tmp=$(mktemp -d)
        mkdir "$tmp/bundles"
        export LTI_ROOT="$tmp"
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        printf "%s|%s\n" "$(bundle_count)" "$(tool_count)"
        rm -rf "$tmp"
    '
    [ "$output" = "0|0" ]
}
```

Note: `SAMPLE` and `LTI_ROOT` are set by the existing `setup()`; the spurious `source "$LTI_ROOT" 2>/dev/null || true` line is removed — use the corrected helper below.

Replace the first test's body with the corrected, minimal form:

```bash
@test "bundle_count and tool_count over a controlled bundles dir" {
    run bash -c '
        tmp=$(mktemp -d); mkdir "$tmp/bundles"
        cp "'"$SAMPLE"'" "$tmp/bundles/one.bundle"
        export LTI_ROOT="$tmp"
        source "'"$LTI_ROOT"'/lib/core.sh"
        source "'"$LTI_ROOT"'/lib/ui.sh"
        source "'"$LTI_ROOT"'/lib/bundle.sh"
        printf "%s|%s\n" "$(bundle_count)" "$(tool_count)"
        rm -rf "$tmp"
    '
    [ "$output" = "1|6" ]
}
```

(The `core.sh` honors a preset `LTI_ROOT`; `tmp/bundles/one.bundle` is a copy of `tests/fixtures/sample.bundle`, which has exactly 6 tool-definition lines.)

- [ ] **Step 2: Verify it fails (inline equivalent)**

Run:

```bash
tmp=$(mktemp -d); mkdir "$tmp/bundles"; cp tests/fixtures/sample.bundle "$tmp/bundles/one.bundle"
LTI_ROOT="$tmp" bash -c 'source "$LTI_ROOT/lib/core.sh"; source "$LTI_ROOT/lib/ui.sh"; source "$LTI_ROOT/lib/bundle.sh"; type bundle_count >/dev/null 2>&1 && type tool_count >/dev/null 2>&1 && echo "PASS" || echo "FAIL: helpers missing"'
rm -rf "$tmp"
```

Expected: `FAIL: helpers missing`.

- [ ] **Step 3: Implement the helpers**

In `lib/bundle.sh`, immediately after the `bundle_list()` function (after its closing `}` on the line with `shopt -u nullglob`), add:

```bash
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
```

- [ ] **Step 4: Verify it passes**

Run:

```bash
tmp=$(mktemp -d); mkdir "$tmp/bundles"; cp tests/fixtures/sample.bundle "$tmp/bundles/one.bundle"
got=$(LTI_ROOT="$tmp" bash -c 'source "$LTI_ROOT/lib/core.sh"; source "$LTI_ROOT/lib/ui.sh"; source "$LTI_ROOT/lib/bundle.sh"; printf "%s|%s" "$(bundle_count)" "$(tool_count)"')
[ "$got" = "1|6" ] && echo "PASS one" || echo "FAIL one: [$got]"
rm -rf "$tmp"
tmp=$(mktemp -d); mkdir "$tmp/bundles"
got=$(LTI_ROOT="$tmp" bash -c 'source "$LTI_ROOT/lib/core.sh"; source "$LTI_ROOT/lib/ui.sh"; source "$LTI_ROOT/lib/bundle.sh"; printf "%s|%s" "$(bundle_count)" "$(tool_count)"')
[ "$got" = "0|0" ] && echo "PASS empty" || echo "FAIL empty: [$got]"
rm -rf "$tmp"
```

Expected: `PASS one`, `PASS empty`.

Then run: `bash tests/run.sh`
Expected: ends with `RESULT: OK`.

- [ ] **Step 5: Commit**

```bash
git add lib/bundle.sh tests/test_bundle_parse.bats
git commit -m "feat(bundle): add pure bundle_count and tool_count helpers"
```

---

## Task 3: `info_band` in `lib/ui.sh`

**Files:**
- Modify: `lib/ui.sh` (add `info_band` after `banner()`; leave `banner`/`hr` untouched)
- Test: `tests/test_ui.bats` (new file)

- [ ] **Step 1: Write the failing bats file**

Create `tests/test_ui.bats`:

```bash
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
```

- [ ] **Step 2: Verify it fails (inline equivalent)**

Run:

```bash
bash -c 'source lib/core.sh; source lib/ui.sh; type info_band >/dev/null 2>&1 && echo PASS || echo "FAIL: info_band missing"'
```

Expected: `FAIL: info_band missing`.

- [ ] **Step 3: Implement `info_band`**

In `lib/ui.sh`, after the `banner()` function's closing `}` (line ~61) and before the `# --- yes/no prompt ---` comment, add:

```bash
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
```

- [ ] **Step 4: Verify it passes**

Run:

```bash
bash -c 'source lib/core.sh; source lib/ui.sh; _LTI_FANCY=0; C_RESET=; C_BOLD=; C_DIM=; C_CYAN=; info_band "Ubuntu 24.04 LTS" debian 7 34 0' \
 | { out=$(cat);
     case "$out" in
       *"distro: Ubuntu 24.04 LTS"*"family: debian"*) ;; *) echo "FAIL line1"; exit;; esac
     case "$out" in *"bundles: 7"*"tools: 34"*"dry-run: OFF"*) ;; *) echo "FAIL line2"; exit;; esac
     case "$out" in *$'\e['*|*"─"*) echo "FAIL: ansi/rule leaked in plain"; exit;; esac
     echo "PASS plain"; }
bash -c 'source lib/core.sh; source lib/ui.sh; _LTI_FANCY=1; C_RESET=$'"'"'\e[0m'"'"'; C_BOLD=$'"'"'\e[1m'"'"'; C_DIM=$'"'"'\e[2m'"'"'; C_CYAN=$'"'"'\e[36m'"'"'; info_band X debian 1 2 1' \
 | { out=$(cat);
     case "$out" in *"dry-run"*"ON"*) ;; *) echo "FAIL fancy ON"; exit;; esac
     case "$out" in *"·"*"─"*) echo "PASS fancy";; *) echo "FAIL fancy sep/rule";; esac; }
```

Expected: `PASS plain` then `PASS fancy`.

Then run: `bash tests/run.sh`
Expected: ends with `RESULT: OK`.

- [ ] **Step 5: Commit**

```bash
git add lib/ui.sh tests/test_ui.bats
git commit -m "feat(ui): add pure info_band renderer (fancy + plain)"
```

---

## Task 4: `_header_art` + `header` in `lib/ui.sh`

**Files:**
- Modify: `lib/ui.sh` (add `_header_art` and `header` before `info_band`)
- Test: `tests/test_ui.bats` (add cases)

- [ ] **Step 1: Write the failing bats cases**

Append to `tests/test_ui.bats`:

```bash
@test "header plain: === wordmark + tagline, no block glyph, no ANSI" {
    run _render 0 'header'
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== linux-toolkit-installer ==="* ]]
    [[ "$output" == *"one-keypress dev toolkits for any Linux distro"* ]]
    [[ "$output" != *"█"* ]]
    [[ "$output" != *$'\e['* ]]
}

@test "header fancy: block glyph + name + short tagline + ANSI" {
    run _render 1 'header'
    [ "$status" -eq 0 ]
    [[ "$output" == *"█"* ]]
    [[ "$output" == *"linux-toolkit-installer"* ]]
    [[ "$output" == *"one-keypress dev toolkits"* ]]
    [[ "$output" == *$'\e['* ]]
}
```

- [ ] **Step 2: Verify it fails (inline equivalent)**

Run:

```bash
bash -c 'source lib/core.sh; source lib/ui.sh; type header >/dev/null 2>&1 && echo PASS || echo "FAIL: header missing"'
```

Expected: `FAIL: header missing`.

- [ ] **Step 3: Implement `_header_art` and `header`**

In `lib/ui.sh`, directly above the `# --- info band` comment added in Task 3, insert:

```bash
# --- project header (block-letter wordmark; ASCII fallback) -----------------
# Static art only — never generated, preserving the zero-dep guarantee.
_header_art() {
    if (( _LTI_FANCY )); then
        printf '%s%s ██╗     ████████╗██╗%s\n'                       "$C_CYAN" "$C_BOLD" "$C_RESET"
        printf '%s%s ██║     ╚══██╔══╝██║%s\n'                       "$C_CYAN" "$C_BOLD" "$C_RESET"
        printf '%s%s ██║        ██║   ██║%s   %slinux-toolkit-installer%s\n' \
            "$C_CYAN" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
        printf '%s%s ███████╗   ██║   ██║%s   %sone-keypress dev toolkits%s\n' \
            "$C_CYAN" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
        printf '%s%s ╚══════╝   ╚═╝   ╚═╝%s\n'                       "$C_CYAN" "$C_BOLD" "$C_RESET"
    else
        printf '=== linux-toolkit-installer ===\n'
        printf 'one-keypress dev toolkits for any Linux distro\n'
    fi
}

# header — the project identity block, terminated by one blank line.
# No arguments. Companion: info_band (called separately by show_header).
header() {
    _header_art
    printf '\n'
}
```

- [ ] **Step 4: Verify it passes**

Run:

```bash
bash -c 'source lib/core.sh; source lib/ui.sh; _LTI_FANCY=0; C_RESET=; C_BOLD=; C_DIM=; C_CYAN=; header' \
 | { out=$(cat);
     case "$out" in *"=== linux-toolkit-installer ==="*"one-keypress dev toolkits for any Linux distro"*) ;; *) echo "FAIL plain content"; exit;; esac
     case "$out" in *"█"*|*$'\e['*) echo "FAIL: glyph/ansi leaked in plain"; exit;; esac
     echo "PASS header plain"; }
bash -c 'source lib/core.sh; source lib/ui.sh; _LTI_FANCY=1; C_RESET=$'"'"'\e[0m'"'"'; C_BOLD=$'"'"'\e[1m'"'"'; C_DIM=$'"'"'\e[2m'"'"'; C_CYAN=$'"'"'\e[36m'"'"'; header' \
 | { out=$(cat);
     case "$out" in *"█"*"linux-toolkit-installer"*"one-keypress dev toolkits"*) echo "PASS header fancy";; *) echo "FAIL fancy content";; esac; }
```

Expected: `PASS header plain` then `PASS header fancy`.

Then run: `bash tests/run.sh`
Expected: ends with `RESULT: OK`.

- [ ] **Step 5: Commit**

```bash
git add lib/ui.sh tests/test_ui.bats
git commit -m "feat(ui): add block-letter header with ASCII fallback"
```

---

## Task 5: `show_header` composer + call-site swap in `install.sh`

**Files:**
- Modify: `install.sh` (add `show_header`; swap two `banner` calls)

- [ ] **Step 1: Add the `show_header` composer**

In `install.sh`, directly above the `# --- --list ---` comment line (just before `do_list()`), add:

```bash
# --- project header (block art + info band) --------------------------------
show_header() {
    header
    info_band "$DISTRO_PRETTY" "$DISTRO_FAMILY" \
              "$(bundle_count)" "$(tool_count)" "$DRY_RUN"
}
```

- [ ] **Step 2: Swap the `--list` call site**

In `do_list()`, replace this exact line:

```bash
    banner "linux-toolkit-installer" "Distro: ${DISTRO_ID:-?}  (family: ${DISTRO_FAMILY})"
```

with:

```bash
    show_header
```

- [ ] **Step 3: Swap the menu call site**

In `menu_loop()`, replace this exact line:

```bash
        banner "linux-toolkit-installer" "Distro: ${DISTRO_ID:-?}  (family: ${DISTRO_FAMILY})"
```

with:

```bash
        show_header
```

(Leave `bundle_run()`'s `banner "Toolkit: $name" …` in `lib/bundle.sh` **unchanged**.)

- [ ] **Step 4: Verify integration (inline; bats absent)**

Run:

```bash
bash -n install.sh && echo "syntax ok"
./install.sh --force-family debian --list 2>/dev/null | head -5
```

Expected: `syntax ok`, then the first lines are the **plain** header (piped → non-fancy):

```
=== linux-toolkit-installer ===
one-keypress dev toolkits for any Linux distro

distro: Debian ...   family: debian
```

Then assert the band reflects real counts and no ANSI leaked into the pipe:

```bash
out=$(./install.sh --force-family debian --list 2>/dev/null)
case "$out" in
  *"=== linux-toolkit-installer ==="*"distro: forced:debian"*"family: debian"*"bundles: 7"*) echo "PASS list-header" ;;
  *) echo "FAIL list-header"; printf '%s\n' "$out" | head -8 ;;
esac
case "$out" in *$'\e['*) echo "FAIL: ANSI leaked into --list pipe" ;; *) echo "PASS no-ansi" ;; esac
```

Expected: `PASS list-header`, `PASS no-ansi`. (`DISTRO_PRETTY` for a forced family is `forced:debian`; `bundles: 7` is the real bundle count in `bundles/`.)

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "feat(install): show block header + info band on menu and --list"
```

---

## Task 6: Full-suite verification + memory

**Files:** none (verification + Qdrant only)

- [ ] **Step 1: Run the full local gate**

Run: `bash tests/run.sh`
Expected: `bash -n` block all `ok`; `shellcheck` and `bats` `SKIPPED`; final `RESULT: OK (skipped tools are informational, not failures)`.

- [ ] **Step 2: Run `make check` (4-family dry-run smoke)**

Run: `make check`
Expected: exits 0; the dry-run runs for `--force-family` debian/fedora/arch/suse all succeed (this exercises `bundle_run`, whose `banner` is unchanged; no package is installed).

- [ ] **Step 3: Eyeball the fancy header in a real terminal**

Run (in an interactive TTY, not piped): `./install.sh --force-family debian` then press `q` Enter.
Expected: block-letter `LTI` in cyan, `linux-toolkit-installer` / `one-keypress dev toolkits` beside it, the info band (`distro … · family …`, `bundles 7 · NN tools · dry-run OFF`) and a cyan rule; pressing `d` toggles `dry-run OFF`→`ON` live.

- [ ] **Step 4: Confirm clean, scoped tree**

Run: `git status --short`
Expected: only the unrelated pre-existing `?? tests/mocks/bin/dnf5` and `?? tests/mocks/bin/yum` remain untracked; nothing else uncommitted. Run `git log --oneline -6` and confirm 5 new commits (Tasks 1–5), author `arthurd3`, no `Co-Authored-By` trailer (`git log -5 --format='%b' | grep -i co-authored-by` → empty).

- [ ] **Step 5: Record in Qdrant + surface push delta**

Store the implementation outcome in Qdrant under the project namespace (`linux_toolkit_installer_architecture`): the new `header`/`info_band`/`_header_art` in `ui.sh`, `DISTRO_PRETTY` in `distro.sh`, `bundle_count`/`tool_count` in `bundle.sh`, `show_header` in `install.sh`, the `nopretty` fixture, `tool_count(sample.bundle)=6`, and that `make check` stayed green. Then report to the user how many commits `main` is ahead of `origin/main` (no push — their decision).

---

## Self-Review

**1. Spec coverage:**
- Rendering fancy/plain (spec §1) → Tasks 3 (`info_band`) + 4 (`header`); exact glyphs/`===` asserted.
- `header`/`info_band` pure, `banner`/`hr` untouched (spec §2) → Tasks 3–4; `bundle_run` banner explicitly left alone in Task 5 Step 3.
- `DISTRO_PRETTY` fallback chain incl. forced + missing (spec §2/§4) → Task 1 (4 cases).
- `bundle_count`/`tool_count` pure, family-independent, `return 0` (spec §2/§4) → Task 2.
- `show_header` composer + 2 call-site swaps, no `ui→bundle` upward call (spec §2) → Task 5.
- Single `_LTI_FANCY` gate; stdout; no rule in plain; optionals omitted (spec §1/§3/§4) → encoded in Task 3/4 code and asserted (`no ─ in plain`).
- Verification convention incl. new `nopretty` fixture, `make check` green (spec §5) → Tasks 1 & 6.
- Commit/memory convention (spec) → every task's commit step + Task 6.
No spec requirement is left without a task.

**2. Placeholder scan:** No `TBD`/`TODO`/"similar to"/"add error handling" — every code and test step is complete and concrete. (Task 2 Step 1 intentionally shows the corrected helper in full rather than referencing it.)

**3. Type/name consistency:** `header` (no args), `info_band <distro> <family> <bundles> <tools> <dry_run>`, `_header_art`, `bundle_count`, `tool_count`, `show_header`, `DISTRO_PRETTY`, fixture `tests/mocks/os-release/nopretty` — names and signatures are identical across Tasks 1–6 and match the spec.
