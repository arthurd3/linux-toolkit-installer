# Persistent State & First-Run-Aware Sudo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tiny persistent state file so the automatic `sudo` bootstrap is offered only on the first run (a one-line reminder replaces it afterwards), while recording minimal machine facts.

**Architecture:** A new single-purpose `lib/state.sh` (sourced right after `lib/core.sh`, depends only on it) owns a plain `key=value` file at `$LTI_STATE_FILE` else `${XDG_STATE_HOME:-$HOME/.local/state}/linux-toolkit-installer/state`. `install.sh` loads it, snapshots first-run before anything persists, branches the pre-flight (first run → auto `sudo_bootstrap`; later → one `warn`), gates the menu `s)` line on `sudo_privilege_state != root`, and persists once after `pm_init`. State IO never aborts the job and never writes under `--dry-run`/`--list`.

**Tech Stack:** Pure Bash (zero deps, no JSON/`jq`), bats test artifact + an equivalent inline harness, `set -euo pipefail` discipline. Spec: `docs/superpowers/specs/2026-05-19-persistent-state-first-run-design.md`.

---

## Environment note (read before running any verification)

The dev machine is Ubuntu 24.04 with **no `bats` and no `shellcheck`** installed (project convention — see `docs/ARCHITECTURE.md` "Verification convention"):

- `bash -n` is the always-on syntax floor.
- bats logic is validated locally via an **equivalent inline bash harness**; the `.bats` file is the durable artifact for contributors who have bats and for `bash tests/run.sh` (which SKIPs bats cleanly when absent).
- `make check` runs `bash tests/run.sh` + a `--dry-run` smoke across the four forced families and must stay green.
- On this box `sudo` **is** installed and the user is in the `sudo` group, and `apt-get` is present — the behavioural checks below rely on that (they are non-mutating: they quit the menu immediately and never install anything).

Paste this helper once at the repo root (`/home/arthurd3/Desktop/linux-toolkit-installer`) before the steps that use `ltistate`:

```bash
ltistate() {  # usage: ltistate "<VAR=val [VAR=val...]>" '<shell expr>'
  LTI_ROOT="$PWD" env $1 bash -c '
    source "$LTI_ROOT/lib/core.sh"
    source "$LTI_ROOT/lib/state.sh"
    '"$2"'
  ' 2>&1
  echo "rc=$?"
}
```

`LTI_ROOT="$PWD"` is preset so `core.sh` skips its realpath/readlink path; `core.sh` turns on `set -euo pipefail`, so the expression runs under the same strict mode as production. Expressions reference `$LTI_STATE_FILE` (set via the env arg) for the file path so nothing in the real `$HOME` is touched.

---

## File structure

| File | Change | Responsibility |
|------|--------|----------------|
| `lib/state.sh` | create | persistent state: path resolution, load, get/set, first-run predicate, atomic dry-run-safe persist |
| `tests/test_state.bats` | create | unit-tests `lib/state.sh` in isolation (own temp dir; never touches real `$HOME`) |
| `install.sh` | modify | source `state.sh`; snapshot first-run; first-run-aware pre-flight; gate menu `s)`; persist once after `pm_init` |
| `README.md` | modify | document first-run-once behaviour + state file + `LTI_STATE_FILE` |
| `docs/ARCHITECTURE.md` | modify | sourcing order, module table row, persistent-state section, data-flow note |

`tests/test_pkg.bats`, `tests/test_sudo.bats`, and every other existing test are intentionally **not** modified (the bats suites source individual `lib/*.sh`, not `install.sh`, so they stay byte-identical).

---

## Task 1: `lib/state.sh` + its bats suite

**Files:**
- Create: `lib/state.sh`
- Create: `tests/test_state.bats`

- [ ] **Step 1: Write the failing test file**

Create `tests/test_state.bats` with exactly:

```bash
#!/usr/bin/env bats
# tests/test_state.bats — lib/state.sh: path resolution, first-run detection,
# atomic persist, --dry-run no-op, and tolerant load. Never touches the real
# $HOME — every case points LTI_STATE_FILE / XDG_STATE_HOME at a temp dir.

setup() {
    LTI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TDIR"
}

# _st "<VAR=val ...>" '<expr>' : source core+state from the real repo, apply
# the given env, run the expression; stdout+stderr merged; exits expr status.
_st() {
    LTI_ROOT="$LTI_ROOT" env $1 bash -c '
        source "$LTI_ROOT/lib/core.sh"
        source "$LTI_ROOT/lib/state.sh"
        '"$2"'
    ' 2>&1
}

@test "state_path honors LTI_STATE_FILE" {
    run _st "LTI_STATE_FILE=$TDIR/s" 'state_path'
    [ "$status" -eq 0 ]
    [ "$output" = "$TDIR/s" ]
}

@test "state_path falls back to XDG_STATE_HOME" {
    run _st "XDG_STATE_HOME=$TDIR/xdg" 'state_path'
    [ "$output" = "$TDIR/xdg/linux-toolkit-installer/state" ]
}

@test "state_is_first_run true when file absent" {
    run _st "LTI_STATE_FILE=$TDIR/none" 'state_load; if state_is_first_run; then echo FIRST; else echo NOT; fi'
    [ "$status" -eq 0 ]
    [[ "$output" == *FIRST* ]]
}

@test "state_persist writes a 0600 file with the keys; not first-run after" {
    run _st "LTI_STATE_FILE=$TDIR/s" '
        state_set schema 1
        state_set first_run_done 1
        state_set distro_family debian
        if state_persist; then echo SAVED; else echo SAVEFAIL; fi
        echo "MODE=$(stat -c %a "$LTI_STATE_FILE")"
        cat "$LTI_STATE_FILE"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *SAVED* ]]
    [[ "$output" == *"MODE=600"* ]]
    [[ "$output" == *"first_run_done=1"* ]]
    [[ "$output" == *"distro_family=debian"* ]]
    run _st "LTI_STATE_FILE=$TDIR/s" 'state_load; if state_is_first_run; then echo FIRST; else echo NOT; fi'
    [[ "$output" == *NOT* ]]
}

@test "state_persist is a no-op under DRY_RUN=1 (no file created)" {
    run _st "LTI_STATE_FILE=$TDIR/dry DRY_RUN=1" '
        state_set first_run_done 1
        if state_persist; then echo RC0; else echo RC1; fi
        if [ -e "$LTI_STATE_FILE" ]; then echo EXISTS; else echo ABSENT; fi
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *RC0* ]]
    [[ "$output" == *ABSENT* ]]
}

@test "state_load ignores comments and malformed lines; round-trips values" {
    printf '%s\n' '# a comment' 'garbage_no_equals' 'distro_family=arch' '' 'pm_bin=pacman' > "$TDIR/s"
    run _st "LTI_STATE_FILE=$TDIR/s" '
        state_load
        echo "fam=$(state_get distro_family) bin=$(state_get pm_bin) miss=$(state_get nope)"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"fam=arch bin=pacman miss="* ]]
}

@test "first_seen preserved across persists; last_seen changes" {
    _st "LTI_STATE_FILE=$TDIR/s" '
        state_set first_seen 2026-01-01T00:00:00Z
        state_set last_seen  2026-01-01T00:00:00Z
        state_persist'
    run _st "LTI_STATE_FILE=$TDIR/s" '
        state_load
        if [ -z "$(state_get first_seen)" ]; then state_set first_seen NEW; fi
        state_set last_seen 2026-02-02T00:00:00Z
        state_persist
        state_load
        echo "first=$(state_get first_seen) last=$(state_get last_seen)"
    '
    [[ "$output" == *"first=2026-01-01T00:00:00Z last=2026-02-02T00:00:00Z"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

bats is not installed locally; use the inline harness. Paste `ltistate` (from the Environment note), then run:

```bash
T=$(mktemp -d); ltistate "LTI_STATE_FILE=$T/s" 'state_path'; rm -rf "$T"
```

Expected (FAIL — pre-implementation): an error like `bash: line 2: .../lib/state.sh: No such file or directory` and a non-zero `rc=` (the `source` of the missing file aborts under `set -e`). This is the expected red.

- [ ] **Step 3: Create `lib/state.sh`**

Create `lib/state.sh` with exactly:

```bash
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
```

- [ ] **Step 4: Syntax check**

Run:

```bash
bash -n lib/state.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 5: Run the inline equivalents to verify they pass**

Paste `ltistate` if needed, then run each block and compare:

```bash
T=$(mktemp -d)
ltistate "LTI_STATE_FILE=$T/s" 'state_path'
# expected: $T/s   then   rc=0

ltistate "XDG_STATE_HOME=$T/xdg" 'state_path'
# expected: $T/xdg/linux-toolkit-installer/state   then   rc=0

ltistate "LTI_STATE_FILE=$T/none" 'state_load; if state_is_first_run; then echo FIRST; else echo NOT; fi'
# expected: FIRST   rc=0

ltistate "LTI_STATE_FILE=$T/s" 'state_set schema 1; state_set first_run_done 1; state_set distro_family debian; state_persist; echo "MODE=$(stat -c %a "$LTI_STATE_FILE")"; cat "$LTI_STATE_FILE"'
# expected: MODE=600, plus lines schema=1 / first_run_done=1 / distro_family=debian (any order)   rc=0

ltistate "LTI_STATE_FILE=$T/s" 'state_load; if state_is_first_run; then echo FIRST; else echo NOT; fi'
# expected: NOT   rc=0

ltistate "LTI_STATE_FILE=$T/dry DRY_RUN=1" 'state_set first_run_done 1; if state_persist; then echo RC0; else echo RC1; fi; if [ -e "$LTI_STATE_FILE" ]; then echo EXISTS; else echo ABSENT; fi'
# expected: RC0   ABSENT   rc=0

printf '%s\n' '# c' 'nokey' 'distro_family=arch' '' 'pm_bin=pacman' > "$T/s2"
ltistate "LTI_STATE_FILE=$T/s2" 'state_load; echo "fam=$(state_get distro_family) bin=$(state_get pm_bin) miss=$(state_get nope)"'
# expected: fam=arch bin=pacman miss=   rc=0

rm -rf "$T"
```

Expected: every block matches the noted output and `rc=0`. If a contributor has bats, also run `bats tests/test_state.bats` and expect all 7 tests to pass.

- [ ] **Step 6: Full harness picks up the new file**

Run:

```bash
bash tests/run.sh
```

Expected: ends with `RESULT: OK`. The `== bash -n ==` block now lists `ok    lib/state.sh`; `shellcheck`/`bats` show `SKIPPED` (informational, not failures).

- [ ] **Step 7: Commit**

```bash
git add lib/state.sh tests/test_state.bats
git commit -m "feat(state): add lib/state.sh persistent state module"
```

---

## Task 2: Wire `install.sh` (source, snapshot, pre-flight, menu gate, persist)

**Files:**
- Modify: `install.sh` (source line 30; helpers after `show_header` line 65; `main()` lines 153, 183-207; menu line 126)

- [ ] **Step 1: Source `lib/state.sh` right after `core.sh`**

In `install.sh`, replace:

```bash
source "$LTI_ROOT/lib/core.sh"
source "$LTI_ROOT/lib/ui.sh"
```

with:

```bash
source "$LTI_ROOT/lib/core.sh"
source "$LTI_ROOT/lib/state.sh"
source "$LTI_ROOT/lib/ui.sh"
```

- [ ] **Step 2: Add `_state_record` / `_state_save` after `show_header`**

In `install.sh`, find the `show_header` function (it ends with its closing `}` on line 65, immediately before the `# --- --list` comment on line 67). Insert the following **between** that closing `}` and the `# --- --list ---...` comment line:

```bash

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
```

- [ ] **Step 3: Load state + snapshot first-run in `main()`**

In `install.sh` `main()`, find this block (lines 180-184):

```bash
    detect_distro_family
    if [[ ${DISTRO_FAMILY} == unknown ]]; then
        lti_fatal "Could not detect a supported distro (ID='${DISTRO_ID:-?}'). Supported families: ${LTI_SUPPORTED_FAMILIES}. Use --force-family to override." 2
    fi

```

Replace it with (adds the load + a first-run snapshot taken **before** anything can persist):

```bash
    detect_distro_family
    if [[ ${DISTRO_FAMILY} == unknown ]]; then
        lti_fatal "Could not detect a supported distro (ID='${DISTRO_ID:-?}'). Supported families: ${LTI_SUPPORTED_FAMILIES}. Use --force-family to override." 2
    fi

    # Persistent state: load, then snapshot first-run BEFORE anything persists
    # (a later state_persist flips first_run_done; the decision must not move).
    state_load
    local _first_run=0
    if state_is_first_run; then _first_run=1; fi

```

- [ ] **Step 4: First-run-aware pre-flight**

In `install.sh` `main()`, replace the entire pre-flight block (lines 185-194):

```bash
    # Pre-flight: only offer the bootstrap when sudo is genuinely missing and
    # the action will need root. Never for --list / --setup-sudo / --dry-run,
    # so `make check` and parseable --list output are unaffected.
    case "$action" in
        all|bundle|"")
            if (( ! DRY_RUN )) && declare -F sudo_privilege_state >/dev/null 2>&1 \
               && [[ $(sudo_privilege_state) == missing ]]; then
                sudo_bootstrap "pre-flight: this action needs root" || true
            fi ;;
    esac
```

with:

```bash
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
```

- [ ] **Step 5: Persist once on the real-action arms**

In `install.sh` `main()`, replace the dispatch block (lines 196-207):

```bash
    case "$action" in
        list)
            do_list ;;
        setup-sudo)
            pm_init; sudo_bootstrap "explicit --setup-sudo" && exit 0 || exit 1 ;;
        all)
            pm_init; do_all ;;
        bundle)
            pm_init; bundle_run "$want_bundle" ;;
        "")
            pm_init; menu_loop ;;
    esac
```

with (adds `_state_save` after `pm_init` on every arm except `list`; `_state_save` is a no-op writer under `--dry-run` by `state_persist`'s own guard):

```bash
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
```

- [ ] **Step 6: Gate the menu `s)` line**

In `install.sh` `menu_loop`, replace this single line (line 126):

```bash
        printf '   s) Set up secure sudo\n'
```

with:

```bash
        if declare -F sudo_privilege_state >/dev/null 2>&1 \
           && [[ $(sudo_privilege_state) != root ]]; then
            printf '   s) Set up secure sudo\n'
        fi
```

(The `s|S)` case arm further down is left unchanged — it is already a no-op when root because `sudo_bootstrap` returns 0 immediately for the `root` state.)

- [ ] **Step 7: Syntax check**

Run:

```bash
bash -n install.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 8: Verify the first-run vs later-run pre-flight branch**

`install.sh` runs `main "$@"` at end-of-file, so it cannot be sourced; this check exercises the **real** `state.sh` + `sudo.sh` functions and the **real** snapshot logic, with only `sudo_bootstrap`/`warn` observed, by running the exact conditional copied from Step 4. Run:

```bash
T=$(mktemp -d)
_pf() {  # $1 = LTI_STATE_FILE ; prints which branch fired
  LTI_ROOT="$PWD" env "LTI_STATE_FILE=$1" DRY_RUN=0 bash -c '
    source "$LTI_ROOT/lib/core.sh"; source "$LTI_ROOT/lib/state.sh"
    source "$LTI_ROOT/lib/ui.sh";   source "$LTI_ROOT/lib/distro.sh"
    source "$LTI_ROOT/lib/pkg.sh";  source "$LTI_ROOT/lib/sudo.sh"
    _sudo_is_root(){ return 1; }; _sudo_have_sudo(){ return 1; }
    sudo_bootstrap(){ echo BOOTSTRAP_CALLED; }
    state_load
    _first_run=0; if state_is_first_run; then _first_run=1; fi
    if (( ! DRY_RUN )) && declare -F sudo_privilege_state >/dev/null 2>&1 \
       && [[ $(sudo_privilege_state) == missing ]]; then
        if (( _first_run )); then
            sudo_bootstrap "pre-flight: this action needs root" || true
        else
            warn "sudo is not installed — you need it to install packages. Pick '\''s'\'' in the menu, or run with --setup-sudo."
        fi
    fi' 2>&1
}
echo "--- first run (absent state) ---"; _pf "$T/none"
printf 'first_run_done=1\n' > "$T/seen"
echo "--- later run (first_run_done=1) ---"; _pf "$T/seen"
rm -rf "$T"
```

Expected:
- first run → a line `BOOTSTRAP_CALLED`, and **no** `sudo is not installed` text.
- later run → `WARN: sudo is not installed — you need it to install packages. Pick 's' in the menu, or run with --setup-sudo.` and **no** `BOOTSTRAP_CALLED`.

Then confirm `install.sh` contains that exact conditional (so the check above mirrors production):

```bash
grep -n "you need it to install packages" install.sh
grep -n "if (( _first_run )); then" install.sh
```

Expected: each prints exactly one matching line.

- [ ] **Step 9: Verify the end-to-end state lifecycle (non-mutating)**

These quit the menu immediately (`q`) — nothing is installed, no `sudo` prompt (the menu only renders, then returns):

```bash
T=$(mktemp -d)

# (a) first menu run writes a 0600 state file with the expected keys
printf 'q\n' | LTI_STATE_FILE="$T/s" ./install.sh >/dev/null 2>&1
echo "MODE=$(stat -c %a "$T/s")"
grep -E '^(first_run_done=1|distro_family=debian|pm_name=apt|pm_bin=apt-get|sudo_state=present|schema=1)$' "$T/s" | sort

# (b) the s) line shows when sudo is present (not root)
printf 'q\n' | LTI_STATE_FILE="$T/s" ./install.sh 2>/dev/null | grep -q 's) Set up secure sudo' && echo "S-SHOWN OK"

# (c) --dry-run writes nothing
printf 'q\n' | LTI_STATE_FILE="$T/dry" ./install.sh --dry-run >/dev/null 2>&1
[ ! -e "$T/dry" ] && echo "DRYRUN NO-WRITE OK"

# (d) --list never persists and stays clean
LTI_STATE_FILE="$T/list" ./install.sh --force-family debian --dry-run --list >/dev/null 2>&1
[ ! -e "$T/list" ] && echo "LIST NO-WRITE OK"
LTI_STATE_FILE="$T/list" ./install.sh --force-family debian --dry-run --list 2>/dev/null | grep -c 's) Set up secure sudo'

rm -rf "$T"
```

Expected, in order:
- `MODE=600`
- the six lines `distro_family=debian`, `first_run_done=1`, `pm_bin=apt-get`, `pm_name=apt`, `schema=1`, `sudo_state=present` (sorted)
- `S-SHOWN OK`
- `DRYRUN NO-WRITE OK`
- `LIST NO-WRITE OK`
- `0` (the menu `s)` line never appears in `--list` output)

- [ ] **Step 10: Full harness + hermetic `make check`**

Run:

```bash
bash tests/run.sh
CT=$(mktemp -d); LTI_STATE_FILE="$CT/s" make check; [ ! -e "$CT/s" ] && echo "CHECK NO-WRITE OK"; rm -rf "$CT"
```

Expected: `bash tests/run.sh` → `RESULT: OK`. `make check` → every family prints `OK` and it ends `check: OK`, then `CHECK NO-WRITE OK` (it runs `--dry-run`, so `state_persist` no-ops and no file is created).

- [ ] **Step 11: Commit**

```bash
git add install.sh
git commit -m "feat(install): first-run-aware sudo offer backed by lib/state.sh"
```

---

## Task 3: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: README — first-run wording in "Setting up sudo"**

In `README.md`, replace:

```
If `sudo` is not installed and you run a command that needs root, the tool
detects this automatically and offers to set up `sudo` for you. You can also
invoke it any time:
```

with:

```
On the **first run**, if `sudo` is not installed and you run a command that
needs root, the tool detects this automatically and offers to set up `sudo`
for you. On later runs it shows a one-line reminder instead (no repeated
prompt) — menu key **`s`** stays available so you can set it up whenever you
want. You can also invoke it any time:
```

- [ ] **Step 2: README — document the state file**

In `README.md`, replace:

```
**Policy: NOPASSWD is never written. No `/etc/sudoers.d` drop-in is created.**
```

with:

```
**Policy: NOPASSWD is never written. No `/etc/sudoers.d` drop-in is created.**

**State file.** The tool records that it has run — plus the detected distro
family, package manager, and last-seen `sudo` state — in a small `key=value`
file at `${XDG_STATE_HOME:-~/.local/state}/linux-toolkit-installer/state`
(override the location with the `LTI_STATE_FILE` environment variable). It is
created mode `0600`, is never written during `--dry-run` or `--list`, and a
write failure never blocks anything. No secrets are ever stored.
```

- [ ] **Step 3: README — menu table `s` row**

In `README.md`, replace:

```
| `s` | Set up a secure `sudo` privilege path |
```

with:

```
| `s` | Set up a secure `sudo` privilege path (shown unless you are already root) |
```

- [ ] **Step 4: ARCHITECTURE — sourcing order**

In `docs/ARCHITECTURE.md`, replace:

```
core.sh  ->  ui.sh  ->  distro.sh  ->  pkg.sh  ->  sudo.sh  ->  aur.sh  ->  bundle.sh
```

with:

```
core.sh  ->  state.sh  ->  ui.sh  ->  distro.sh  ->  pkg.sh  ->  sudo.sh  ->  aur.sh  ->  bundle.sh
```

- [ ] **Step 5: ARCHITECTURE — module table row**

In `docs/ARCHITECTURE.md`, find the `lib/core.sh` table row:

```
| `lib/core.sh`   | strict mode (`set -euo pipefail`), `LTI_ROOT` resolution (symlink-safe), runtime-flag globals, EXIT cleanup trap, `lti_fatal`, `require_bash4` | — |
```

Insert this new row immediately **after** it (its own line):

```
| `lib/state.sh`  | persistent state: `key=value` file at `$LTI_STATE_FILE` else `${XDG_STATE_HOME:-~/.local/state}/linux-toolkit-installer/state` (0600); first-run flag + machine facts; no-op under `--dry-run`; never fatal | core |
```

- [ ] **Step 6: ARCHITECTURE — persistent-state section**

In `docs/ARCHITECTURE.md`, insert the following block immediately **before** the `## Data flow` line, followed by a blank line:

```
## Persistent state (`lib/state.sh`)

A tiny `key=value` file records that the tool has run and what it last saw:
`schema`, `first_run_done`, `first_seen`, `last_seen`, `distro_family`,
`pm_name`, `pm_bin`, `sudo_state`. Path: `$LTI_STATE_FILE`, else
`${XDG_STATE_HOME:-$HOME/.local/state}/linux-toolkit-installer/state`
(created `0600`).

- Detection always runs fresh; the recorded `distro_family`/`pm_*` are
  informational only — never used to skip detection.
- The automatic `sudo` bootstrap is offered only on the **first run**
  (`first_run_done` unset). Later runs show a one-line reminder instead while
  `sudo` is still missing; menu key `s` stays available unless you are root.
- `state_persist` is a no-op under `--dry-run` and is never called on
  `--list`, so `make check` and parseable `--list` output are unaffected. A
  write failure prints one `warn` and never blocks the run.

```

- [ ] **Step 7: ARCHITECTURE — data-flow note**

In `docs/ARCHITECTURE.md`, replace:

```
`pm_require_privileges` also re-invokes the bootstrap if `sudo -v` fails after
a fresh install.
```

with:

```
`pm_require_privileges` also re-invokes the bootstrap if `sudo -v` fails after
a fresh install. The pre-flight bootstrap fires only on the first recorded run
(`lib/state.sh`); later runs show a one-line reminder instead.
```

- [ ] **Step 8: Verify docs**

Run:

```bash
grep -n "LTI_STATE_FILE" README.md docs/ARCHITECTURE.md
grep -n "lib/state.sh" docs/ARCHITECTURE.md
bash tests/run.sh
```

Expected: `grep` shows the new mentions in both files (README has the `LTI_STATE_FILE` line; ARCHITECTURE shows the sourcing-order, table row, and section); `bash tests/run.sh` ends with `RESULT: OK`.

- [ ] **Step 9: Commit**

```bash
git add README.md docs/ARCHITECTURE.md
git commit -m "docs: document the persistent state file and first-run sudo offer"
```

---

## Task 4: Final verification & memory

- [ ] **Step 1: Full gate**

Run:

```bash
bash -n install.sh lib/*.sh tests/run.sh && echo "syntax OK"
bash tests/run.sh
CT=$(mktemp -d); LTI_STATE_FILE="$CT/s" make check; [ ! -e "$CT/s" ] && echo "CHECK NO-WRITE OK"; rm -rf "$CT"
```

Expected: `syntax OK`; `bash tests/run.sh` → `RESULT: OK`; `make check` → `check: OK` (each of `debian fedora arch suse` prints `OK`); `CHECK NO-WRITE OK`.

- [ ] **Step 2: Re-run the behavioural scenarios once more**

Re-run Task 1 Step 5 (all inline blocks), Task 2 Step 8 (first vs later branch), and Task 2 Step 9 (a–d). Confirm every expected line still matches.

- [ ] **Step 3: Confirm commit hygiene (do NOT push)**

Run:

```bash
git log --oneline -5
git log --format='%b' -4 | grep -i co-authored-by && echo "PROBLEM: co-author trailer" || echo "OK: no co-author trailer"
git status --porcelain
git rev-list --count origin/main..HEAD
```

Expected: the four feature commits (`feat(state)`, `feat(install)`, `docs:`, plus the earlier spec `docs:`) present in English Conventional-Commit style; `OK: no co-author trailer`; clean working tree (empty `git status --porcelain`); a non-zero unpushed count is reported — **do not push**; surface the delta to the user and let them decide.

- [ ] **Step 4: Store the learning in Qdrant**

Use `mcp__qdrant-memory__qdrant-store` with metadata `project="linux-toolkit-installer"`, `collection="linux_toolkit_installer_architecture"` (and a `linux_toolkit_installer_gotchas` entry if a reusable pattern emerged). Record: `lib/state.sh` public contract and the `$LTI_STATE_FILE`→`$XDG_STATE_HOME` path order; the first-run snapshot taken before any persist; the first-run-aware pre-flight (auto once → `warn` after); `s)` gated on `sudo_privilege_state != root`; `state_persist`'s `if (( DRY_RUN )); then return 0; fi` guard (set-e-safe, not `(( DRY_RUN )) && return 0`); persist after `pm_init` on all/bundle/menu/setup-sudo, never on `list`; existing bats suites stay byte-identical because they source `lib/*.sh` not `install.sh`; and the final commit SHAs (not pushed).

---

## Self-review (completed during planning)

- **Spec coverage:** §1 file (path/format/mode/keys) → Task 1 Step 3 + Task 1 tests. §2 module contract (`state_path/load/get/set/is_first_run/persist`) → Task 1 Step 3, asserted Task 1 Step 5. §3 wiring (source, snapshot, pre-flight branch, `s)` gate, persist after `pm_init`, never on `list`) → Task 2 Steps 1-6, verified Steps 8-10. §4 data flow → Task 2 Steps 3-6 ordering. §5 error/edge (absent/corrupt load, unwritable→one warn, dry-run/list no write, first-run snapshot stable, stderr discipline) → `state.sh` code + Task 1 Steps 5 (dry-run no-op, tolerant load) + Task 2 Step 9 (c,d). §6 tests/verification → Task 1 + Task 2 Steps 8-10 + Task 4. Backward compatibility → Task 2 Step 10 (`tests/run.sh`/`make check`) + no existing test modified. Docs → Task 3. Commit & memory → Task 4.
- **Placeholder scan:** none — every step has exact paths, full code, exact commands and expected output.
- **Type/name consistency:** `_LTI_STATE`, `_LTI_STATE_SH`, `state_path/state_load/state_get/state_set/state_is_first_run/state_persist`, `_state_record/_state_save`, `_first_run`, key names (`schema/first_run_done/first_seen/last_seen/distro_family/pm_name/pm_bin/sudo_state`) are used identically across the module, the wiring, the tests, and the docs.
- **`set -e` audit:** every test-guarded return uses `if … then … fi` (`state_load`, `state_is_first_run`, `state_persist` DRY_RUN guard, `_state_record`); the double-source guard uses the same `[[ … ]] && return 0` idiom already proven under active `set -e` in `lib/sudo.sh`; `_state_save` uses `state_persist || warn …` then `return 0`.
