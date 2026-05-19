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
- An unrecognized distro (family `unknown`) that still has a supported package
  manager on `PATH` adopts it the same way (priority `apt, dnf, pacman,
  zypper`), also printing a `WARN` to stderr.

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

## Privilege escalation (sudo bootstrap)

When `sudo` is genuinely missing and a real install needs root, the tool offers
to install and configure it for you.  It can also be invoked explicitly at any
time with `--setup-sudo` or menu key `s`.

### Admin group per family

Each distro family has a conventional admin group that grants `sudo` access:

| Family | Admin group | sudoers line |
|--------|-------------|--------------|
| `debian` | `sudo` | `%sudo ALL=(ALL:ALL) ALL` |
| `fedora` | `wheel` | `%wheel ALL=(ALL) ALL` |
| `arch`   | `wheel` | `%wheel ALL=(ALL) ALL` |
| `suse`   | `sudo` | `%sudo ALL=(ALL:ALL) ALL` |

**Arch note:** Arch Linux ships `%wheel` commented out in `/etc/sudoers`.
The bootstrap enables it via a `visudo -cf`-validated, atomically-applied
edit (`install -m 0440 -o root -g root`).  On Debian, Fedora, and openSUSE
the line is already active — the step is a safe no-op.

### How root access is obtained

`su` is used to become root in order to install the `sudo` package.  You type
the **root password directly into `su`**; the tool never reads or stores it.
If `su` is unavailable or declined, the tool prints the exact commands so you
can run them yourself.

### Policy

- **NOPASSWD is never written** — the sudoers entry always requires a password.
- **No `/etc/sudoers.d` drop-in** — the change is made directly to
  `/etc/sudoers`, validated with `visudo -cf`, and applied atomically.

After the bootstrap completes, **log out and back in** (or run
`newgrp <group>`) for the new group membership to take effect in the current
shell.

## Overrides / testing hooks

- `LTI_FORCE_FAMILY=<debian|fedora|arch|suse>` — force the family (also the
  `--force-family` flag). Combine with `--dry-run` to inspect any distro's
  resolution from any machine.
- `OS_RELEASE_PATH=<path>` — read a different os-release file (used by tests).

## Adding a distro to an existing family

Add its `ID` to the matching `case` arm in `_lti_family_of` in
`lib/distro.sh`, then add an `os-release` fixture under
`tests/mocks/os-release/` and a case in `tests/test_distro.bats`.
