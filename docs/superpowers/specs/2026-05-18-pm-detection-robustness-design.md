# Package-Manager Detection Robustness — Design

- **Date:** 2026-05-18
- **Status:** Approved (brainstorming) → pending implementation plan
- **Scope:** Harden package-manager resolution within the existing four distro
  families (`debian`, `fedora`, `arch`, `suse`). No new families.

## Problem

`detect_distro_family()` (`lib/distro.sh`) reliably maps `/etc/os-release` to a
family. Package-manager selection in `pm_init()` (`lib/pkg.sh`) is *inferred from
the family name* and then only existence-checked with a single `command -v`:

- `fedora` always assumes `dnf` → breaks on RHEL/CentOS 7 and Amazon Linux 2
  (which use `yum`); ignores `dnf5` (Fedora 41+).
- `unknown` family → fatal, even when a usable PM (`apt-get`, `pacman`, …) is
  present on the machine.
- The os-release derivative list is finite; a distro outside it with no useful
  `ID_LIKE` → `unknown` → dies.
- It never determines *which PM the machine actually has* — only what the distro
  name implies.

**Goal:** be accurate about the package manager the user actually has
available, keeping the distro name as a disambiguating hint. Stay within the
four families (no `apk`/`xbps`/`eopkg`/etc.).

## Chosen approach — "PM verified, name as hint"

Decouple the *logical* PM from the *concrete binary*; probe `PATH` for the real
binary; keep the distro family as the preference hint and as the single source
of truth for bundle package-name mapping; adopt an available PM (and re-point
the family) when the hinted family's PM is absent or the family is `unknown`;
fail only when no known PM exists.

## 1. Data model

Two distinct concepts replace today's overloaded `PM_NAME`:

- **`PM_NAME`** — logical PM, drives command shape; unchanged set:
  `apt | dnf | pacman | zypper`.
- **`PM_BIN`** — the concrete executable actually invoked:
  - `apt` → first present of: `apt-get`, `apt`
  - `dnf` → first present of: `dnf`, `dnf5`, `yum`
  - `pacman` → `pacman`
  - `zypper` → `zypper`

`yum` and `dnf5` reuse the `dnf` command shape (`<bin> install -y …`,
`<bin> -y makecache`) — both compatible — and `pm_is_installed` keeps using
`rpm -q` (valid for all three). `pacman`/`zypper` shapes unchanged.

`DISTRO_FAMILY` remains the single source of truth consumed by `bundle.sh` for
package-name resolution (`debian=/fedora=/arch=/suse=`). `lib/distro.sh` is
**unchanged** (single responsibility: os-release only). The family re-point on
the "adopt available PM" path happens in `lib/pkg.sh`. `DISTRO_ID` keeps the raw
os-release id (truthful logs); the adoption warning communicates the re-point.

`PM_BIN` is exported alongside `PM_NAME` and `SUDO`.

## 2. Resolution algorithm

New function `pm_detect()` in `lib/pkg.sh`, plus helper
`_pm_first_present <bin...>` (echoes the first binary found via `command -v`,
returns non-zero if none — written `set -e` safe).

- Family → preferred logical PM (unchanged table): `debian→apt`, `fedora→dnf`,
  `arch→pacman`, `suse→zypper`.
- Logical PM → ordered binary candidates as in §1.
- Cross-family adoption priority (fixed): `apt`, `dnf`, `pacman`, `zypper`.

Decision order:

1. **Forced family** (`LTI_FORCE_FAMILY` set): family and its logical PM are
   locked. Resolve `PM_BIN` from that PM's candidate list. If none present and
   not `--dry-run` → `lti_fatal … 2`. In `--dry-run`, `warn` and use the first
   candidate name nominally (printed, never executed). An explicit override is
   never auto-switched. (Preserves the test-harness contract: forced family +
   mock binary present → argv identical to today.)
2. **Known family, its PM present** → use the family's logical PM and the first
   present binary; `DISTRO_FAMILY` unchanged. **Conflict policy:** the family's
   own PM always wins when present, even if other PMs coexist (prevents the
   "`apt` installed on an Arch box" footgun).
3. **Known family, its PM absent, another known PM present** → adopt the present
   PM (by the fixed priority order), set `PM_NAME`/`PM_BIN` accordingly,
   **re-point `DISTRO_FAMILY`** to the adopted PM's family, and emit a stderr
   `warn`: `os-release indicates <orig family> but its package manager is not
   installed; using '<bin>' (<new family>) which is present.`
4. **`unknown` family** → scan the fixed priority order; adopt the first present
   PM and set `DISTRO_FAMILY` to its family.
5. **No known PM present** → not `--dry-run`:
   `lti_fatal "no supported package manager found (looked for: apt-get apt dnf
   dnf5 yum pacman zypper)" 2`. In `--dry-run`: `warn`, fall back to the
   os-release family if it was a known one else `debian`/`apt-get`, purely so
   dry-run can print; nothing is executed.

## 3. Public contract / call sites

- `pm_init()` calls `pm_detect()`, then sets and exports `PM_NAME`, `PM_BIN`,
  `SUDO`. The current inline family→name→bin→`command -v` block is replaced.
- `pm_refresh()` and `pm_install()` substitute the literal binary with
  `$PM_BIN` (command shape still switched by `PM_NAME`; the `dnf` shape now
  covers `dnf`/`dnf5`/`yum`).
- `pm_is_installed()` unchanged (switches on `PM_NAME`: dpkg-query / rpm -q /
  pacman -Qq — valid for every binary within its logical family).
- `pm_require_privileges()` unchanged.
- Public function names and their documented header contract stay the same;
  `PM_BIN` is added to the documented exports.

## 4. Error handling & edge cases

- Forced family with absent binary, non-dry-run → fatal (respect override).
- No PM at all, non-dry-run → fatal with the explicit "looked for" list.
- Multiple PMs across families with a *known* family → family's PM wins.
- `yum`/`dnf5` command compatibility pinned to the `dnf` shape (`install -y`,
  `-y makecache`); documented.
- stdout/stderr discipline preserved: all adoption/fallback notices go to
  stderr so `--list` stdout stays parseable.
- `set -e` safety: every probe via `if command -v …; then`; explicit `return`
  on every branch; no failing probe left as the last command (matches the
  project's documented discipline).

## 5. Tests & verification

Convention unchanged: static + in-repo simulation, no real installs; real
mutating installs deferred to the user; no CI (removed).

- New mock binaries `tests/mocks/bin/yum` and `tests/mocks/bin/dnf5`, mirroring
  the existing `dnf` mock (capture argv to `$LTI_TEST_CAPTURE`, exit 0).
  Existing os-release fixtures suffice.
- New `tests/test_pkg.bats` cases (each builds a temp `PATH` containing only the
  desired mock binaries):
  - fedora forced, only `yum` present → `PM_BIN=yum`, argv `yum install -y …` /
    `yum -y makecache`.
  - fedora forced, only `dnf5` present → `dnf5`.
  - fedora forced, `dnf`+`dnf5`+`yum` present → picks `dnf` (preference order).
  - os-release `debian` fixture, only `dnf` present (no apt) → adopts dnf,
    `DISTRO_FAMILY` switches to fedora, warn on stderr. Adoption applies only
    to os-release-detected families — never to `LTI_FORCE_FAMILY`.
  - debian *forced*, only `dnf` present: non-dry-run → fatal exit 2 (override
    locked, never adopts); `--dry-run` → warn + nominal `apt-get`, no switch.
  - `unknown` os-release fixture + `apt-get` present → adopts apt/debian.
  - `unknown` + no PM, non-dry-run → fatal, exit 2.
  - `unknown` + no PM, `--dry-run` → warn, prints, no crash.
  - Regression: forced debian/fedora/arch/suse with the standard mock present →
    argv byte-identical to the current suite (backward-compat guard).
- Static: `bash -n` on all sources always. `shellcheck`/`bats` run if installed;
  dev machine has neither → logic validated via the project's equivalent bash
  harness, as already done.
- `make check` (forced-family dry-run smoke across the four families) stays
  green — unchanged because the standard binaries resolve identically.
- Docs: `docs/ARCHITECTURE.md` and `docs/DISTROS.md` updated to document
  `PM_NAME` vs `PM_BIN`, probe order, the adopt-with-warning rule, and fedora
  `dnf › dnf5 › yum`.

## Backward compatibility

With the standard binary present, the resolver picks exactly the same binary as
today (`apt-get`/`dnf`/`pacman`/`zypper`), so the argv that `bats` asserts and
that `make check` smoke-tests is **unchanged**. Only the new behaviors
(`yum`/`dnf5`, cross-family adoption, `unknown`) add cases.

## Out of scope (YAGNI)

- New distro families / package managers (`apk`, `xbps`, `eopkg`, `nix`, …).
- Interactive "which PM do you want?" prompts.
- Changing bundle data or the bundle file format.
- Touching `lib/distro.sh` detection logic.

## Commit & memory

On completion: Conventional Commits in English, no Claude co-author, directly on
`main`, no auto-push (surface the delta). Store the learning in Qdrant under the
project namespace (`linux_toolkit_installer_architecture` /
`linux_toolkit_installer_conventions`).
