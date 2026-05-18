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
| `lib/pkg.sh`    | `pm_init/pm_require_privileges/pm_refresh/pm_is_installed/pm_install` over apt/dnf/pacman/zypper; sudo strategy; dry-run | core, ui, distro |
| `lib/aur.sh`    | Arch-only `yay` bootstrap (hardened: mktemp + EXIT trap) and `aur_install` | core, ui, pkg |
| `lib/bundle.sh` | parse `*.bundle`, `bundle_resolve` (pure), `bundle_run`, summary accounting | core, ui, pkg, aur |

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
