# Supported distros

The tool targets four package-manager families. Your distro is mapped to a
family from `/etc/os-release`.

| Family | Package manager (binary, in order tried) | Detected from `ID` / `ID_LIKE` (examples) |
|--------|------------------------------------------|-------------------------------------------|
| `debian` | `apt-get`, `apt` | debian, ubuntu, linuxmint, pop, raspbian, elementary, kali, devuan, zorin |
| `fedora` | `dnf`, `dnf5`, `yum` | fedora, rhel, centos, rocky, almalinux, ol, amzn, scientific |
| `arch`   | `pacman` (+ `yay` for AUR) | arch, manjaro, endeavouros, garuda, artix, cachyos |
| `suse`   | `zypper`  | opensuse-leap, opensuse-tumbleweed, sles, sled, suse |

## Detection logic (`lib/distro.sh`)

1. If `LTI_FORCE_FAMILY` is set, it wins (must be one of the four families).
2. Read `ID` from `/etc/os-release`; map it to a family.
3. If `ID` is unrecognized, try each token of `ID_LIKE` in order.
4. If nothing matches → `unknown`. `lib/pkg.sh` then tries to adopt whatever
   supported package manager is actually on `PATH` (priority `apt, dnf,
   pacman, zypper`) and re-points the family accordingly. Only if no known
   package manager exists does the tool exit with code `2` (unless
   `--dry-run`).

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

## Per-family commands

| | refresh | install | is-installed |
|--|--|--|--|
| debian | `apt-get update` | `DEBIAN_FRONTEND=noninteractive apt-get install -y` | `dpkg-query -W -f='${Status}'` + grep `ok installed` |
| fedora | `dnf -y makecache` | `dnf install -y` | `rpm -q` |
| arch   | `pacman -Sy --noconfirm` | `pacman -S --needed --noconfirm` | `pacman -Qq` |
| suse   | `zypper --non-interactive refresh` | `zypper --non-interactive install` | `rpm -q` |

Privileged commands are prefixed with `sudo` (nothing if already root).

The first column shows the canonical binary; the actually-invoked binary is
whatever `pm_detect` resolved (`PM_BIN`) — e.g. `yum`/`dnf5` for `fedora`.

## Overrides / testing hooks

- `LTI_FORCE_FAMILY=<debian|fedora|arch|suse>` — force the family (also the
  `--force-family` flag). Combine with `--dry-run` to inspect any distro's
  resolution from any machine.
- `OS_RELEASE_PATH=<path>` — read a different os-release file (used by tests).

## Adding a distro to an existing family

Add its `ID` to the matching `case` arm in `_lti_family_of` in
`lib/distro.sh`, then add an `os-release` fixture under
`tests/mocks/os-release/` and a case in `tests/test_distro.bats`.
