# Architecture

A small, dependency-free Bash tool. Core principle: each `lib/` module has one
job, a stable interface, and is testable in isolation.

## Sourcing order (set by `install.sh`)

```
core.sh  ->  state.sh  ->  ui.sh  ->  distro.sh  ->  pkg.sh  ->  sudo.sh  ->  aur.sh  ->  bundle.sh
```

Each module guards against double-sourcing and is safe to re-source.

| Module | Responsibility | Depends on |
|--------|----------------|------------|
| `lib/core.sh`   | strict mode (`set -euo pipefail`), `LTI_ROOT` resolution (symlink-safe), runtime-flag globals, EXIT cleanup trap, `lti_fatal`, `require_bash4` | — |
| `lib/state.sh`  | persistent state: `key=value` file at `$LTI_STATE_FILE` else `${XDG_STATE_HOME:-~/.local/state}/linux-toolkit-installer/state` (0600); first-run flag + machine facts; no-op under `--dry-run`; never fatal | core |
| `lib/ui.sh`     | color gating (`[[ -t 1 && -z $NO_COLOR && $TERM != dumb ]]`), `say/info/ok/warn/error`, `banner`, `hr`, `confirm` | core |
| `lib/distro.sh` | `detect_distro_family` from `/etc/os-release` `ID`/`ID_LIKE` → `debian\|fedora\|arch\|suse\|unknown` | core |
| `lib/pkg.sh`    | `pm_detect` (logical `PM_NAME` vs concrete `PM_BIN`), `pm_init/pm_require_privileges/pm_refresh/pm_is_installed/pm_install` over apt/dnf/pacman/zypper; sudo strategy; dry-run; shared pure helper `_pm_install_argv` | core, ui, distro |
| `lib/sudo.sh`   | privilege bootstrap: detect root/missing/present; install `sudo` via `su`; configure admin group + `visudo`-validated sudoers; teach/auto/interactive modes | core, ui, distro, pkg |
| `lib/aur.sh`    | Arch-only `yay` bootstrap (hardened: mktemp + EXIT trap) and `aur_install` | core, ui, pkg |
| `lib/bundle.sh` | parse `*.bundle`, `bundle_resolve` (pure), `bundle_run`, summary accounting | core, ui, pkg, aur |

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
   pacman, zypper` (a `WARN` is printed to stderr).
5. No known PM at all → fatal (exit 2), unless `--dry-run`.

`yum`/`dnf5` reuse the `dnf` command shape; `pm_is_installed` keys off
`PM_NAME` so `rpm -q` still covers all three.

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

## Data flow

```
install.sh args ─▶ detect_distro_family ─▶ pm_init
                                            │
                       [sudo missing?] ─▶ sudo_bootstrap (pre-flight or --setup-sudo)
                                            │
              bundle file ─▶ bundle_resolve(family,line) ─▶ {native|aur|none|bad}
                                            │
                       pm_is_installed (idempotency) ─▶ plan
                                            │
                 confirm ─▶ pm_refresh ─▶ pm_install / aur_install ─▶ summary
```

`sudo_bootstrap` is invoked in two places: (1) at startup pre-flight — only
when `sudo` is genuinely missing, the action is not `--list`/`--dry-run`, and
you are not already root; (2) explicitly via `--setup-sudo` or menu key `s`.
`pm_require_privileges` also re-invokes the bootstrap if `sudo -v` fails after
a fresh install. The pre-flight bootstrap fires only on the first recorded run
(`lib/state.sh`); later runs show a one-line reminder instead.

## `set -e` foot-guns (deliberate handling)

- `pm_is_installed` always ends each branch with an explicit `return 0/1`
  (never lets a failing probe be the last command) — safe in any caller.
- `(( ... ))` arithmetic tests are only used inside `if`/`&&`/`||`.
- `shift || true` in arg parsing; `read ... || true` for EOF.
- Fallible probes use `if cmd; then` rather than bare `cmd`.

## Verification convention

Static + logic simulation lives in-repo (`bash -n`, shellcheck, bats with a
mocked package manager, `--dry-run`). Real, mutating installs are deferred to
the user (documented in the README).
