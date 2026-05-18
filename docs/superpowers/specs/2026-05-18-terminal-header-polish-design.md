# Terminal Header Polish — Design

- **Date:** 2026-05-18
- **Status:** Approved (brainstorming) → pending implementation plan
- **Scope:** Replace the project-identity banner shown by the interactive menu
  and `--list` with a block-letter header plus an info band. Header + info band
  only — the menu list body and `--list` package output are **unchanged**.

## Problem

The project identity is currently a 50-column box drawn by `banner()`
(`lib/ui.sh`), called as
`banner "linux-toolkit-installer" "Distro: <id> (family: <fam>)"` from
`menu_loop()` and `do_list()` (`install.sh`), and as
`banner "Toolkit: <name>" …` from `bundle_run()` (`lib/bundle.sh`). It is
functional but plain, and surfaces little context (raw `DISTRO_ID`, family).

**Goal:** a striking, "big letters" header for the project name plus a compact
info band (distro, family, bundle/tool counts, dry-run state) — prettier but
not heavy — while preserving the zero-dependency guarantee and the clean
plain-text fallback that pipes/CI/`--list` rely on.

**Non-goals:** restyling the numbered menu list, restyling `--list` package
lines, changing `bundle_run()`'s contextual `"Toolkit: <name>"` banner,
changing bundle data/format, or adding any runtime dependency.

## Chosen approach — dedicated, fully-decoupled `header`

A new `header` is added to `lib/ui.sh` as pure presentation; the dynamic data
it needs is computed by the libraries that own it (`distro.sh`, `bundle.sh`)
and assembled by a thin composer in the `install.sh` orchestrator. `banner()`
and `hr()` are left exactly as they are (still used by `bundle_run()` and
`_bundle_summary()`). The block-letter art is a static string baked into
`lib/ui.sh` — never generated — so the zero-dependency guarantee holds. All
fancy glyphs/colour are gated by the existing single TTY predicate
`_LTI_FANCY`; the plain branch is ASCII-only and stays grep/parse-friendly.

## 1. Rendering

Output goes to **stdout**, exactly like `banner()` today (no stream change;
`--list` consumers already skip a header block, and the plain form below is
shorter than the old `+---+` box).

### Fancy mode (`_LTI_FANCY=1`)

Block-letter `LTI` (ANSI-Shadow style), with the name + tagline to the right of
rows 3–4:

```
 ██╗     ████████╗██╗
 ██║     ╚══██╔══╝██║
 ██║        ██║   ██║   linux-toolkit-installer
 ███████╗   ██║   ██║   one-keypress dev toolkits
 ╚══════╝   ╚═╝   ╚═╝

  distro  Ubuntu 24.04  ·  family  debian
  bundles 7  ·  34 tools  ·  dry-run OFF
 ────────────────────────────────────────────────
```

Colour mapping (reusing the existing `C_*` palette only — no new colour
infrastructure):

- Art rows 1–5: `C_CYAN` + `C_BOLD`.
- Name + tagline (rows 3–4, right side): `C_DIM`.
- Info-band labels (`distro`, `family`, `bundles`, `tools`, `dry-run`):
  `C_DIM`; values: `C_BOLD`.
- `·` separators and the closing `─` rule (width 50, matching `hr()`'s
  default and the legacy banner width): `C_CYAN`.

### Plain mode (`_LTI_FANCY=0` — piped, CI, `NO_COLOR`, `TERM=dumb`, `--list | …`)

No block glyphs, no colour, no box-drawing, no `─` rule — ASCII only:

```
=== linux-toolkit-installer ===
one-keypress dev toolkits for any Linux distro

distro: Ubuntu 24.04   family: debian
bundles: 7   tools: 34   dry-run: OFF
```

The `=== … ===` line is the plain delimiter (no trailing rule); the block
closes with a single blank line.

The name (`linux-toolkit-installer`) and tagline strings are fixed constants in
`lib/ui.sh`.

## 2. Components

Net change is additive; nothing existing is removed.

- **`lib/ui.sh`** — add:
  - `header` — no arguments. Renders art (fancy block / plain `=== … ===`) +
    name + tagline + blank line, then the info band, then (fancy only) the
    closing `─` rule. Reads only its own ambient state (`_LTI_FANCY`, `C_*`).
  - `info_band <distro> <family> <bundles> <tools> <dry_run>` — pure: formats
    exactly the values passed in (same ethos as the pure `bundle_resolve`).
    `dry_run` is `0|1`, mapped to `OFF|ON`.
  - Private `_header_art` for the static glyph block.
  - `banner()` and `hr()` are **untouched**.
- **`lib/distro.sh`** — add a third global `DISTRO_PRETTY`, set by
  `detect_distro_family`. Fallback chain: `PRETTY_NAME` → `NAME` + `VERSION_ID`
  → `DISTRO_ID` → `unknown`. For a forced family it is `DISTRO_ID`
  (`forced:<family>`). Documented in the file header beside `DISTRO_ID` /
  `DISTRO_FAMILY`. os-release parsing reuses the existing key/quote-strip loop.
- **`lib/bundle.sh`** — add two pure helpers:
  - `bundle_count` — number of `*.bundle` files (same `nullglob` glob as
    `bundle_list`); zero bundles → `0`.
  - `tool_count` — sum, across all bundles, of tool-definition lines
    (non-empty, non-comment, not a `[group]` marker, not `name:`/`description:`,
    contains `|`). Family-independent — "tools defined", not "resolvable for
    this distro" — which is stable, cheap (no resolve loop) and honest.
  - Both end with explicit `return 0` (the project's `set -e`-safe discipline:
    a failed final probe must not abort a caller).
- **`install.sh`** — add a 3-line composer `show_header` (the orchestrator is
  the correct layer for data assembly):
  ```sh
  show_header() {
      header
      info_band "$DISTRO_PRETTY" "$DISTRO_FAMILY" \
                "$(bundle_count)" "$(tool_count)" "$DRY_RUN"
  }
  ```
  Replace the `banner "linux-toolkit-installer" …` call in `menu_loop()`
  (~line 108) and `do_list()` (~line 60) with `show_header`. `bundle_run()`'s
  `banner "Toolkit: <name>" …` (`lib/bundle.sh` ~line 158) is **unchanged**.

There is no `ui.sh → bundle.sh` upward call: `info_band` is pure and receives
the counts as arguments from `show_header`. Layering stays clean and every
piece is unit-testable in isolation.

## 3. Data flow & live updates

- `main()` already fatal-exits on an unknown family before any header is shown,
  so `DISTRO_PRETTY`/`DISTRO_FAMILY` are always populated when `header` runs;
  `info_band` still guards with `${…:-unknown}` defensively.
- `menu_loop()` re-renders every iteration (`clear` + header), so toggling `d`
  (dry-run) / `o` (optionals) updates the band immediately. `bundle_count` /
  `tool_count` are recomputed each render — trivial cost (stat ~7 files, read
  ~70 lines); no caching (YAGNI).
- `optionals` is **deliberately omitted** from the band to match the approved
  preview and keep it light; adding it later is a one-line change.

## 4. Error handling & edge cases

- Missing/unreadable os-release → `DISTRO_PRETTY` falls back to `DISTRO_ID`
  then `unknown`; never errors. (Unreachable for a usable run because unknown
  family is fatal earlier — defensive only.)
- Zero bundles → `bundles: 0   tools: 0`; helpers still `return 0`.
- `set -e`/`pipefail`: `$(bundle_count)` / `$(tool_count)` are safe because the
  helpers return 0; all probes follow the project's explicit-return discipline.
- stdout/stderr discipline preserved: header is informational → stdout (as
  `banner` is today); `warn`/`error` remain on stderr. `--list` stdout stays
  parseable (plain mode emits no colour/box/rule).
- Single-predicate gating: every fancy glyph, colour, and the `─` rule are
  governed only by the existing `_LTI_FANCY` — `NO_COLOR`, non-TTY, dumb term,
  and piped `--list` all yield the ASCII form automatically.

## 5. Tests & verification

Convention unchanged: static + in-repo simulation, no real installs; real
mutating installs deferred to the user; no CI (removed). Mirrors the existing
"source the libs and assert on output/status" bats pattern.

- `bash -n` on every changed file — already enforced by `tests/run.sh`'s
  zero-dep floor.
- `shellcheck` on the changed libs when installed (SKIP-tolerant; unchanged
  harness behaviour).
- New / extended `bats`:
  - `test_distro.bats`: `DISTRO_PRETTY` from a `PRETTY_NAME` fixture; the
    `NAME`+`VERSION_ID` fallback (fixture without `PRETTY_NAME`);
    `forced:<f>` path sets `DISTRO_PRETTY=forced:<f>`.
  - `test_bundle_parse.bats`: `bundle_count` and `tool_count` are exact
    integers against `tests/fixtures/` (`sample.bundle`).
  - New UI test: with `_LTI_FANCY=0`, `header` output contains
    `=== linux-toolkit-installer ===`, the `distro:` / `bundles:` lines, and
    **no** ANSI escape and **no** `█`; with `_LTI_FANCY=1`, it contains the
    block glyph and a cyan escape. `info_band` asserted pure for fixed args
    (incl. `dry_run` 0→`OFF`, 1→`ON`).
- An os-release fixture without `PRETTY_NAME` may need to be added under
  `tests/mocks/os-release/` for the fallback case (existing `ubuntu` /
  `opensuse` fixtures are confirmed to carry `PRETTY_NAME` for the happy path).
- `make check` (forced-family dry-run smoke across the four families) stays
  green: it exercises `bundle_run` (whose `banner` is unchanged); `--list`
  plain output remains parseable.
- Dev machine has neither `shellcheck` nor `bats` → logic validated via the
  project's equivalent bash harness, as already done; real `bats` runs where a
  contributor has it.

## Backward compatibility

`banner()` / `hr()` signatures and behaviour are unchanged, so `bundle_run()`
and `_bundle_summary()` render identically. `--list` stdout stays parseable
(plain mode is colourless/box-free). `DISTRO_PRETTY` is a new global —
additive, no existing consumer affected. The argv asserted by `bats` and
`make check` is untouched (the install path is not modified at all).

## Out of scope (YAGNI)

- Restyling the numbered menu list or `--list` package lines.
- Changing `bundle_run()`'s `"Toolkit: <name>"` banner.
- `optionals` in the info band (one-line future add).
- Any runtime dependency (`figlet`/`toilet`) or generated art.
- Bundle data/format changes; new distro families.

## Commit & memory

On completion: Conventional Commits in English, no Claude co-author, directly
on `main`, no auto-push (surface the delta). Store the learning in Qdrant under
the project namespace (`linux_toolkit_installer_architecture` /
`linux_toolkit_installer_conventions`).
