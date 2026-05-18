# Contributing

## Style

- Pure Bash 4+, **zero external dependencies** in `lib/` and `install.sh`
  (no fzf/whiptail/zenity/jq). Only coreutils + the system package manager.
- `set -euo pipefail` is set by `lib/core.sh`. Wrap fallible probes
  (`if cmd; then`, `|| true`, explicit `return`) — see `docs/ARCHITECTURE.md`.
- Color/box-drawing must stay gated on
  `[[ -t 1 && -z $NO_COLOR && $TERM != dumb ]]` (handled in `lib/ui.sh`).
- 4-space indent, LF, no trailing whitespace (`.editorconfig`).
- Keep each `lib/` module single-purpose with a stable interface.

## Most changes are data, not code

Adding tools or fixing a package name = editing a `bundles/*.bundle` file.
No Bash changes needed. See `docs/BUNDLES.md`.

## Before opening a PR

```sh
make lint     # shellcheck (skips cleanly if not installed)
make test     # bash -n + shellcheck + bats
make check    # the above + dry-run --all across all four families
```

`make check` must pass. CI runs the same on `ubuntu-latest` and never installs
a real package (dry-run only).

## Adding tests

- New parsing edge case → add to `tests/fixtures/sample.bundle` +
  `tests/test_bundle_parse.bats`.
- New distro `ID` → `tests/mocks/os-release/` fixture +
  `tests/test_distro.bats`.
- New package-manager behavior → `tests/test_pkg.bats` (use the mocks in
  `tests/mocks/bin/`; never invoke a real package manager in tests).

## Verification convention

In-repo verification is static + simulated (`bash -n`, shellcheck, bats with a
mocked PM, `--dry-run`). Real mutating installs are the user's call and are
documented, not automated.
