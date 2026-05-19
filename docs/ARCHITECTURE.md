# Architecture

A small, dependency-free Bash tool. Core principle: each `lib/` module has one
job, a stable interface, and is testable in isolation.

## Sourcing order (set by `install.sh`)

```
core.sh  ->  ui.sh  ->  distro.sh  ->  pkg.sh  ->  aur.sh  ->  bundle.sh
```

Each module guards against double-sourcing and is safe to re-source.

| Module | Responsibility | Depends on |
|--------|----------------|------------|
| `lib/core.sh`   | strict mode (`set -euo pipefail`), `LTI_ROOT` resolution (symlink-safe), runtime-flag globals, EXIT cleanup trap, `lti_fatal`, `require_bash4` | — |
| `lib/ui.sh`     | color gating (`[[ -t 1 && -z $NO_COLOR && $TERM != dumb ]]`), `say/info/ok/warn/error`, `banner`, `hr`, `confirm` | core |
| `lib/distro.sh` | `detect_distro_family` from `/etc/os-release` `ID`/`ID_LIKE` → `debian\|fedora\|arch\|suse\|unknown` | core |
| `lib/pkg.sh`    | `pm_detect` (logical `PM_NAME` vs concrete `PM_BIN`), `pm_init/pm_require_privileges/pm_refresh/pm_is_installed/pm_install` over apt/dnf/pacman/zypper; sudo strategy; dry-run | core, ui, distro |
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
   pacman, zypper`.
5. No known PM at all → fatal (exit 2), unless `--dry-run`.

`yum`/`dnf5` reuse the `dnf` command shape; `pm_is_installed` keys off
`PM_NAME` so `rpm -q` still covers all three.

## Data flow

```
install.sh args ─▶ detect_distro_family ─▶ pm_init
                                            │
              bundle file ─▶ bundle_resolve(family,line) ─▶ {native|aur|none|bad}
                                            │
                       pm_is_installed (idempotency) ─▶ plan
                                            │
                 confirm ─▶ pm_refresh ─▶ pm_install / aur_install ─▶ summary
```

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
