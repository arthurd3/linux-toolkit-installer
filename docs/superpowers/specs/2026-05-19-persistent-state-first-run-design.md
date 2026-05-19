# Persistent State & First-Run-Aware Sudo — Design

- **Date:** 2026-05-19
- **Status:** Approved (brainstorming) → pending implementation plan
- **Scope:** Add a small persistent state file so the tool knows whether it
  has run before. Use it to make the sudo offer first-run-aware: auto-offer the
  sudo bootstrap only on the first run; on later runs show a one-line warning
  instead, while keeping the `s)` menu entry available whenever sudo is not
  usable. The file also records minimal machine facts (detected family /
  package manager / last-seen sudo state) for transparency and future use.

## Problem

Today the sudo bootstrap is offered on **every** run when sudo is missing:

- The startup pre-flight (`install.sh` ~lines 188–194) calls
  `sudo_bootstrap` on every install/menu run whenever
  `sudo_privilege_state == missing`.
- The interactive menu prints `s) Set up secure sudo` (`install.sh:126`)
  unconditionally on every render.

There is no persistent state anywhere in the project — it is deliberately
zero-dependency and stateless. The result is that a user without sudo is
re-prompted by the automatic bootstrap on every single invocation, which is
nagging rather than helpful.

**Goal:** the automatic offer fires **once** (first run). After that, a
non-intrusive one-line warning replaces it when sudo is still missing, and the
`s)` menu entry stays available so the user can still trigger setup on demand —
never a dead end. Back this with a tiny persistent state file that also records
the detected machine facts, while preserving the zero-dependency guarantee and
the hard "dry-run / `--list` mutate nothing" invariants.

**Non-goals:** an install-history ledger; saved user preferences (dry-run /
optionals / forced-family restored next run); using the recorded family/PM to
skip re-detection; schema migration logic; file locking; any runtime
dependency (no JSON/`jq`).

## Chosen approach — dedicated `lib/state.sh` module

A new single-purpose module owns all state IO, mirroring the project's existing
modular pattern (`lib/distro.sh`, `lib/sudo.sh`). The path is overridable via
`LTI_STATE_FILE`, exactly paralleling the existing `OS_RELEASE_PATH` /
`LTI_ROOT` / `LTI_FORCE_FAMILY` test seams. The `install.sh` orchestrator does
the thin wiring (snapshot first-run, branch the pre-flight, gate the menu line,
persist once). The state file is a plain `key=value` text file — no JSON, no
`jq` — so zero-dependency holds. State IO **never** aborts the real job and
**never** writes under `--dry-run` or `--list`.

Alternatives rejected: folding state into `lib/core.sh` (bloats the
always-loaded base module, breaks single-responsibility, hard to unit-test in
isolation); inlining in `install.sh` (the orchestrator is not a logic home, and
the `bats` suites source `lib/*.sh`, not `install.sh`, so it would be
untestable in the project's pattern).

## 1. The state file

- **Path** (resolved by `state_path`, pure, always `return 0`):
  `${LTI_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/linux-toolkit-installer/state}`
- **Format:** flat `key=value`, one per line. `#` comments and blank lines
  ignored; a line without `=` is skipped (never fatal — same parse ethos as
  `bundle_resolve` / malformed bundle lines). Values are simple scalars
  (no quoting, no spaces in recorded values).
- **Mode:** created `0600` (user-private; principle of least exposure — it
  contains only machine facts, never secrets).
- **Keys:**
  - `schema=1` — reserved for future migration (no migration logic now).
  - `first_run_done=1` — presence + value `1` means "not the first run".
  - `first_seen=<UTC ISO8601>` — written once; preserved on later persists.
  - `last_seen=<UTC ISO8601>` — updated every persist.
  - `distro_family=<debian|fedora|arch|suse>` — informational only.
  - `pm_name=<apt|dnf|pacman|zypper>` / `pm_bin=<…>` — informational; set only
    after `pm_init` ran (carried forward otherwise).
  - `sudo_state=<root|missing|present>` — last-seen privilege state.

  Timestamps via `date -u +%Y-%m-%dT%H:%M:%SZ` (coreutils — zero-dep).
  Recorded `distro_family`/`pm_*` are **informational only**: detection always
  runs fresh every invocation; the file is never used to bypass detection
  (hardware/distro can change).

## 2. Module `lib/state.sh`

Sourced in `install.sh` immediately after `lib/core.sh` (its only dependency is
core's helpers). Source order becomes:
`core → state → ui → distro → pkg → sudo → aur → bundle`.
Double-source-guarded with `_LTI_STATE_SH` (the project's `_LTI_SUDO_SH`
pattern). In-memory model is one global associative array `_LTI_STATE`
(`declare -gA`; bash 4.3+, consistent with the existing `local -n` nameref use
— all four families ship bash 5.x). Public contract:

- `state_path` — pure; echo the resolved path. Always `return 0`.
- `state_load` — if the file exists, parse safe lines into `_LTI_STATE`
  (skip blank / `#` / no-`=` lines). Read-only; safe to call on any action,
  including `--list` / `--dry-run`. Always `return 0`.
- `state_get <key>` — echo `${_LTI_STATE[key]:-}`. `return 0`.
- `state_set <key> <value>` — set `_LTI_STATE[key]` in memory.
- `state_is_first_run` — `return 0` (true) if the file is absent **or**
  `first_run_done` is not `1`; else `return 1`. Explicit returns (`set -e`
  safe).
- `state_persist` — **first line: if `(( DRY_RUN ))` then `return 0` without
  writing** (the hard "dry-run mutates nothing" invariant). Otherwise:
  `mkdir -p` the parent dir; write all `_LTI_STATE` pairs to a `mktemp` in that
  same dir (registered with `lti_register_tmp` for EXIT cleanup); `chmod 0600`;
  atomic `mv -f` into place. On any failure → `return 1` (caller warns once;
  **never fatal**). On success → `return 0`.

All functions follow the project's `set -e` discipline (every branch ends in an
explicit `return 0/1`; no bare failing probe as the last command).

Note: `lib/core.sh`'s `_lti_cleanup` already probes `-e` (file **or** dir,
fixed in commit `33a1fce`), so a registered state *file* (not a dir) is cleaned
correctly — the implementation must not regress that to `-d`.

## 3. Wiring in `install.sh`

Additive except for the pre-flight block and the one menu line.

- **Source:** add `source "$LTI_ROOT/lib/state.sh"` right after the
  `lib/core.sh` source.
- **Snapshot (in `main()`, after `detect_distro_family` and the unknown-family
  fatal):** `state_load`; capture `_first_run` as `0|1` from
  `state_is_first_run` **before** anything can persist, so a later
  `state_persist` flipping `first_run_done` cannot change the decision
  mid-run.
- **Pre-flight** — replace the current `case "$action" in all|bundle|"")`
  block. Keeping the existing `declare -F sudo_privilege_state` backward-compat
  guard:
  - compute `_sstate=$(sudo_privilege_state)`;
  - if `(( ! DRY_RUN )) && [[ $_sstate == missing ]]`:
    - **first run** (`_first_run == 1`) → `sudo_bootstrap "pre-flight: this
      action needs root" || true` (today's behavior, now first-run only);
    - **later run** → a single
      `warn "sudo is not installed — you need it to install packages. Pick 's'
      in the menu, or run with --setup-sudo."` (no auto-prompt).
  - Never fires for `list` / `setup-sudo` / `--dry-run` (unchanged exclusion).
- **Menu `s)` line (`install.sh:126`):** print
  `   s) Set up secure sudo` only when
  `declare -F sudo_privilege_state >/dev/null 2>&1 &&
  [[ $(sudo_privilege_state) != root ]]` — i.e. hidden only when already root
  (pointless there); shown for `missing` **and** `present` (still useful when
  sudo exists but the user is not yet in the admin group). The `s|S)` case arm
  stays unconditional (a no-op as root: `sudo_bootstrap` returns 0 immediately).
- **Persist:** a small `_state_record` fills `_LTI_STATE` (`schema=1`,
  `first_run_done=1`, `first_seen` only if currently empty else preserved,
  `last_seen=<now>`, `distro_family`, `pm_name`/`pm_bin` if `PM_*` set,
  `sudo_state` from `sudo_privilege_state` when available). Then
  `state_persist || warn "could not save state to $(state_path); continuing."`
  is called once, **after `pm_init`**, on the real-action arms `all` /
  `bundle` / `""` (menu) / `setup-sudo` — **never on `list`**. Under
  `--dry-run` the call still happens but `state_persist` no-ops by its own
  guard (the guard is the single source of truth; the `list` arm simply never
  calls it, keeping `--list` stdout pristine).

## 4. Data flow

```
detect_distro_family
  └─ unknown? → fatal (unchanged)
state_load                          (read-only; safe on every action)
_first_run = state_is_first_run     (snapshot 0|1)
pre-flight (all|bundle|""):
  sudo missing & !dry-run ?
    first run → sudo_bootstrap (auto, as today)
    else      → warn one line (no prompt)
dispatch:
  list                → do_list                         (NO persist, NO warn)
  setup-sudo|all|
  bundle|"" (menu)    → pm_init → _state_record
                         → state_persist (no-op if dry-run) → action
```

## 5. Error handling & edge cases

- **No / corrupt file:** `state_load` yields empty `_LTI_STATE`;
  `state_is_first_run` is true; treated as first run; never fatal. Malformed
  lines skipped silently.
- **Unwritable path** (mkdir/mv fails): `state_persist` returns 1; caller emits
  one `warn` and proceeds — the install / menu is **never** blocked by state
  IO.
- **`--dry-run`:** `state_persist` returns 0 without writing (guard). No file
  is created. `make check` (which runs `--dry-run`) writes nothing and is
  unaffected.
- **`--list`:** `state_load` may run (read-only, harmless); `state_persist` is
  never called on this arm; no warnings on the list path → stdout stays
  parseable.
- **First-run + bootstrap installs sudo:** `_first_run` is snapshotted before
  pre-flight, so the decision is stable; `sudo_state` is recorded at persist
  time and reflects the real post-bootstrap state.
- **Concurrent runs:** atomic `mv -f` ⇒ last writer wins; acceptable — state is
  advisory, no locking (YAGNI).
- **`set -e`/`pipefail`:** `$(state_path)` / `$(sudo_privilege_state)` are safe
  because those functions always `return 0`; all probes use explicit returns.
- **stdout/stderr discipline:** the new warning is `warn` → stderr (consistent
  with the project's `--list`-parseable rule); state IO prints nothing on
  stdout.

## 6. Tests & verification

Convention unchanged: static + in-repo simulation, no real installs; real
mutating filesystem writes under the real `$HOME` are avoided via
`LTI_STATE_FILE`; no CI (removed). Mirrors the existing "source the libs and
assert on output/status" `bats` pattern.

- `bash -n` on every changed file — `tests/run.sh` already globs `lib/*.sh`, so
  `lib/state.sh` is picked up automatically.
- `shellcheck` on changed libs when installed (SKIP-tolerant; unchanged harness
  behavior).
- **New `tests/test_state.bats`:**
  - `state_path`: default = XDG fallback; honors `LTI_STATE_FILE`; honors
    `XDG_STATE_HOME`.
  - `state_is_first_run`: true when the file is absent; false after a persist
    that set `first_run_done=1`.
  - `state_persist`: creates the file with the expected keys, mode `0600`;
    **is a no-op when `DRY_RUN=1`** (file not created).
  - `state_load`: ignores `#` and no-`=` lines; round-trips
    `set → persist → load → get`; `first_seen` preserved across two persists
    while `last_seen` changes.
  - Harness uses `mktemp -d` + `LTI_STATE_FILE="$tmp/state"`; sources libs from
    the real repo path (the project's "inline-bats-equivalent — source libs
    from the real repo, env var only for the path" gotcha); never touches the
    real `$HOME`.
- Existing suites stay **byte-identical**: `lib/state.sh` is new (only its own
  test sources it); the `bats` suites source individual `lib/*.sh`, not
  `install.sh`, so the `install.sh` wiring does not affect `test_pkg.bats`
  (argv guard), `test_sudo.bats`, etc.
- `bash tests/run.sh` → `RESULT: OK`.
- `make check` (forced-family `--dry-run --all --yes` across the four families)
  stays green: `state_persist` no-ops under `--dry-run`, so no files are
  written and behavior is unchanged; `--list` plain output remains parseable.
- Dev box has neither `bats` nor `shellcheck` → logic validated via the
  project's equivalent inline bash harness, as already done; real `bats` runs
  where a contributor has it. Real mutating runs (writing under a real `$HOME`)
  deferred to the user.

## Backward compatibility

`lib/state.sh` is purely additive. The pre-flight refactor preserves first-run
behavior **identically** (first run + missing sudo → the same automatic
`sudo_bootstrap`). The only behavioral changes are intended: later runs warn
instead of re-prompting, and `s)` is hidden only when already root. The
`declare -F sudo_privilege_state` guard keeps the pre-flight sane even if
`sudo.sh`/`state.sh` were not sourced (defensive; `install.sh` does source
both). The install-path argv asserted by `test_pkg.bats` and `make check` is
untouched.

## Out of scope (YAGNI)

- Install-history ledger.
- Saved user preferences (dry-run / optionals / forced-family restore).
- Using recorded `distro_family`/`pm_*` to skip re-detection.
- Schema migration logic (`schema=1` reserved only).
- File locking / multi-writer coordination beyond atomic `mv`.
- Any encryption (no secrets are ever stored).
- Any runtime dependency (no JSON/`jq`).

## Commit & memory

On completion: Conventional Commits in English, no Claude co-author, directly
on `main`, no auto-push (surface the delta). Store the learning in Qdrant under
the project namespace (`linux_toolkit_installer_architecture` /
`linux_toolkit_installer_conventions`).
