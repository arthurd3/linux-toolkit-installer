# Linux Toolkit Installer

> **One command. A full dev toolkit. Any major Linux distro.**

<img width="626" height="489" alt="image" src="https://github.com/user-attachments/assets/c1d519be-5bf6-4e67-b028-6ede7d1f4bec" />

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)
![Dependencies: zero](https://img.shields.io/badge/dependencies-zero-brightgreen.svg)
![Distros: debian · fedora · arch · suse](https://img.shields.io/badge/distros-debian%20%C2%B7%20fedora%20%C2%B7%20arch%20%C2%B7%20suse-blue.svg)

Pick **Java** and it installs the JDK, Maven, and Gradle — using the correct
package names for *your* distribution, so you never have to hunt for them
again. It's pure Bash with zero external dependencies (just coreutils and your
system's package manager) and works the same on **Debian, Fedora, Arch, and
openSUSE** family distros.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Using it](#using-it)
- [What gets installed](#what-gets-installed)
- [How it picks the right packages](#how-it-picks-the-right-packages)
- [Safety and re-runs](#safety-and-re-runs)
- [Setting up sudo](#setting-up-sudo)
- [Mounting a disk](#mounting-a-disk)
- [Setting up Docker](#setting-up-docker)
- [Install as a command](#install-as-a-command)
- [Troubleshooting](#troubleshooting)
- [Bundle file format](#bundle-file-format)
- [Docs and contributing](#docs-and-contributing)
- [License](#license)

## What it does

Setting up a new machine usually means looking up the right package name for
every tool, for every distro. This tool removes that step: you pick a toolkit,
it figures out the rest.

- **One keypress** — choose a toolkit from a menu, or name it on the command line.
- **Any major distro** — Debian, Fedora, Arch, and openSUSE families.
- **Zero dependencies** — pure Bash; nothing to install before you start.
- **Safe** — preview everything first; re-running never breaks anything.
- **Data-driven** — toolkits are plain-text files anyone can read and edit.

## Requirements

- A Linux distro in the **debian, fedora, arch, or suse** family.
- **Bash 4+** and coreutils (present on every supported distro by default).
- **`git`** to clone this repository.
- **`sudo`** rights — only for *real* installs. Previews (`--dry-run`) need
  no root at all. If `sudo` is not installed, the tool can set it up for you
  (see [Setting up sudo](#setting-up-sudo) below).
- Nothing else. On Arch, optional extras that come from the AUR use `yay`,
  which the tool bootstraps for you automatically.

## Quick start

```sh
git clone https://github.com/arthurd3/linux-toolkit-installer.git
cd linux-toolkit-installer
./install.sh
```

That's it. With no arguments, `./install.sh` opens an interactive menu — pick
a toolkit by number and you're done. Nothing is changed until you confirm.

Prefer the command line? Skip the menu:

```sh
./install.sh --list                  # what would be installed, for your distro
./install.sh --dry-run --bundle java # show every action, change nothing
./install.sh --bundle java           # actually install the Java toolkit
./install.sh --all --with-optional   # everything, including optional extras
```

## Using it

### Interactive menu

Run `./install.sh` with no arguments. You'll see your distro, a numbered list
of toolkits, and these keys:

| Key | Action |
|-----|--------|
| `1`, `2`, … | Install that toolkit |
| `a` | Install the core group of **all** toolkits |
| `d` | Toggle **dry-run** (preview-only, no changes) on/off |
| `o` | Toggle **optional** extras on/off |
| `m` | Detect and mount a disk (interactive picker) |
| `k` | Install and bring up **Docker** (daemon + sysctl + runtime) |
| `s` | Set up a secure `sudo` privilege path (shown unless you are already root) |
| `q` | Quit |

### Command-line options

| Option | Meaning |
|--------|---------|
| `--list` | List bundles and the packages they resolve to on this distro |
| `--bundle <name>` | Install one toolkit (e.g. `--bundle java`) |
| `--all` | Install every toolkit's core group |
| `--with-optional` | Also install the `[optional]` extras |
| `--dry-run` | Print actions, change nothing, no `sudo` needed |
| `--yes`, `-y` | Skip confirmation prompts |
| `--force-family <f>` | Override distro detection: `debian`, `fedora`, `arch`, or `suse` |
| `--setup-sudo` | Install and securely configure `sudo` (admin group + `visudo`-validated sudoers), then exit |
| `--mount` | Detect and mount a disk interactively, then exit |
| `--docker` | Install and configure Docker (daemon, sysctl, runtime), then exit |
| `-h`, `--help` | Show usage |

### Common examples

```sh
# See exactly what "java" maps to on your current distro
./install.sh --list

# Preview a single toolkit without touching the system (no sudo)
./install.sh --dry-run --bundle java

# Install one toolkit for real
./install.sh --bundle java

# Install everything, optional extras included
./install.sh --all --with-optional

# Inspect how things resolve on a *different* distro, from this machine
./install.sh --force-family fedora --dry-run --list
```

## What gets installed

Toolkits ("bundles") are plain-text files in `bundles/`. Each lists the tools
it provides and the package name for every distro family.

| Toolkit | Core tools | Optional extras | Status |
|---------|------------|-----------------|--------|
| **Java** | JDK 17 (LTS), Maven, Gradle | VisualVM, JetBrains Toolbox | ✅ **Stable** — verified on all 4 families |
| **Python** | Python 3, pip, pipx | venv | Best-effort |
| **Go** | Go toolchain | — | Best-effort |
| **Node / Web** | Node.js, npm | Insomnia, Postman | Best-effort |
| **DevOps / Docker** | Docker, docker-compose | — | Best-effort |
| **Databases** | PostgreSQL, SQLite, Redis | DBeaver | Best-effort |
| **Editors & Terminal** | git, build tools, vim, neovim, kitty, zsh, tmux, ripgrep, fd, bat, fzf, httpie | eza, tldr, VS Code | Best-effort |

**Java** is fully populated and verified across Debian, Fedora, Arch, and
openSUSE. The others are *best-effort*: package names are correct where we're
confident and marked as unavailable where we're not. Fixing or extending them
is **data only** — edit the matching `bundles/*.bundle` file, no code changes.
See [Bundle file format](#bundle-file-format) for the format and how to add your own.

## How it picks the right packages

Your distro is detected automatically from `/etc/os-release` and mapped to one
of four families. The tool then uses whichever supported package manager is
actually installed (`apt`, `dnf`, `pacman`, or `zypper`).

| Family | Package manager (tried in order) | Distros (examples) |
|--------|----------------------------------|--------------------|
| `debian` | `apt-get`, `apt` | Debian, Ubuntu, Mint, Pop!_OS, Raspberry Pi OS, elementary, Kali, Devuan, Zorin |
| `fedora` | `dnf`, `dnf5`, `yum` | Fedora, RHEL, CentOS, Rocky, AlmaLinux, Oracle, Amazon, Scientific |
| `arch` | `pacman` (+ `yay` for AUR) | Arch, Manjaro, EndeavourOS, Garuda, Artix, CachyOS |
| `suse` | `zypper` | openSUSE Leap/Tumbleweed, SLES, SLED |

If your distro isn't recognized, just tell it which family to use:

```sh
./install.sh --force-family debian   # or fedora | arch | suse
```

## Safety and re-runs

- **Preview costs nothing.** `--dry-run` changes nothing and needs no `sudo`.
- **You're always asked first.** A real run requests `sudo` up front, then
  shows the plan and waits for your confirmation (`--yes` skips the prompt).
- **Re-running is safe.** Packages that are already installed are detected and
  skipped, so you can run the same command again with no harm.
- **One missing package won't stop the rest.** If a tool has no package for
  your distro, it's skipped with a warning and the rest of the toolkit still
  installs.

## Setting up sudo

On the **first run**, if `sudo` is not installed and you run a command that
needs root, the tool detects this automatically and offers to set up `sudo`
for you. On later runs it shows a one-line reminder instead (no repeated
prompt) — menu key **`s`** stays available so you can set it up whenever you
want. You can also invoke it any time:

```sh
./install.sh --setup-sudo   # standalone: install & configure, then exit
```

Or press **`s`** from the interactive menu.

**Modes**

| Invocation | Behaviour |
|------------|-----------|
| `--setup-sudo --dry-run` | **Teach mode** — prints the exact commands; changes nothing. Good for reviewing what will happen. |
| `--setup-sudo --yes` | **Automatic** — runs without prompting. |
| `--setup-sudo` (alone) | **Interactive** — asks before each step. |

**What it does**

1. Uses `su` to run as root, so you type the **root password directly into
   `su`** — the tool never reads or stores it.  If `su` is unavailable or you
   decline, it prints the exact commands to run yourself instead.
2. Installs the `sudo` package via the system package manager.
3. Adds your user to the admin group for your distro family:
   `sudo` on Debian/openSUSE, `wheel` on Fedora/Arch.
4. Ensures the group's line is active in `/etc/sudoers`.  On Arch,
   `%wheel` ships commented out — the tool enables it.  On Debian, Fedora, and
   openSUSE it is already active, so this step is a no-op.
5. The sudoers edit is validated with `visudo -cf` on a temporary copy and
   applied atomically with `install -m 0440 -o root -g root`.

**Policy: NOPASSWD is never written. No `/etc/sudoers.d` drop-in is created.**

**State file.** The tool records that it has run — plus the detected distro
family, package manager, and last-seen `sudo` state — in a small `key=value`
file at `${XDG_STATE_HOME:-~/.local/state}/linux-toolkit-installer/state`
(override the location with the `LTI_STATE_FILE` environment variable). It is
created mode `0600`, is never written during `--dry-run` or `--list`, and a
write failure never blocks anything. No secrets are ever stored.

After the bootstrap completes, **log out and back in** (or run
`newgrp <group>`) for the new group membership to take effect.

## Mounting a disk

Press **`m`** in the menu (or run `./install.sh --mount`) to attach an extra
disk. The tool lists the partitions it finds — device, size, filesystem,
label, and whether each is already mounted — and you pick one by number. It
mounts the chosen partition at `/run/media/$USER/<label>` (you can type a
different path), using `ntfs-3g` for NTFS and offering to install it if it is
missing.

```sh
./install.sh --mount             # detect, pick, and mount a disk
./install.sh --mount --dry-run   # just print the mkdir/mount commands
```

The mount lasts for the current session only — it is not added to
`/etc/fstab`, so it does not persist across reboots. Mounting needs root, so
you may be prompted for `sudo` when you confirm.

## Setting up Docker

Installing Docker from a distro package sometimes leaves it unable to start —
the daemon isn't enabled, the `runc` runtime is missing (so BuildKit crash-loops),
IP forwarding is off, or bridge traffic never reaches nftables. Press **`k`** in
the menu (or run `./install.sh --docker`) to install Docker **and** bring it up
correctly in one step. It is idempotent — safe to run on a fresh machine or to
repair a broken install.

### Diagnose first: `--docker-check`

Not sure what's wrong? Run a **read-only health check** (menu key **`c`**, no root
needed) that inspects every layer and tells you exactly what to fix:

```sh
./install.sh --docker-check
```

```text
[OK]   engine  — real Docker on PATH
[FAIL] runtime — no runc/crun — BuildKit and containers will fail to start
[OK]   service — active and enabled on boot
[WARN] group   — you are in 'docker' but THIS shell predates it — run 'newgrp docker' or log out/in
[WARN] module  — br_netfilter not loaded
```

It checks the engine (including whether `docker` is really **Podman's shim**,
common on Fedora), the `runc`/`crun` runtime, the service, socket reachability,
Compose, your `docker` group membership, `ip_forward`, and the kernel modules.
It exits non-zero when it finds problems, so you can use it as a healthcheck.

### Fixing it: `--docker`

`--docker` runs the same diagnosis, then fixes the gaps. It installs your distro's
engine (`moby-engine` on Fedora, `docker.io` on Debian/Ubuntu, `docker` on
Arch/openSUSE) and explicitly ensures `containerd` and `runc`, then:

- writes `/etc/modules-load.d/docker.conf` (`overlay`, `br_netfilter`) and loads them;
- writes `/etc/sysctl.d/99-docker.conf` (`net.ipv4.ip_forward` + bridge-netfilter) and applies it;
- clears any prior start rate-limit (`systemctl reset-failed`) and runs `systemctl enable --now docker`;
- ensures the `docker` group exists and handles membership intelligently — it only
  offers to add you when you're genuinely not a member; if you're already in the
  group but your current shell predates it, it tells you to run `newgrp docker` (or
  re-login) instead of pointlessly re-adding you. (Group membership grants
  root-equivalent access, so it always asks first.)
- warns (without changing anything) if `docker` is Podman's shim rather than real Docker.

```sh
./install.sh --docker             # diagnose, then install + configure + start Docker
./install.sh --docker --dry-run   # show the diagnosis + every command it would run
```

Docker needs root, so you may be prompted for `sudo` when you confirm. To preview
everything first — packages, the exact config files, and the `systemctl`/`sysctl`
commands — use `--dry-run`, which changes nothing.

## Install as a command

To run it from anywhere as `linux-toolkit-installer`:

```sh
make install     # symlinks install.sh into ~/.local/bin/
make uninstall    # removes that symlink
```

If `linux-toolkit-installer` isn't found afterward, add `~/.local/bin` to your
`PATH` (most modern distros already do this).

## Troubleshooting

**"Could not detect a supported distro"**
Your distro wasn't recognized. Re-run with the right family:
`./install.sh --force-family debian` (or `fedora` / `arch` / `suse`).

**It's asking for my `sudo` password**
That's expected for a real install. To look without changing anything, use
`./install.sh --dry-run …` — it never needs root.

**"no package mapping for `<family>`, skipping"**
That particular tool has no package on your distro. It's skipped on purpose;
the rest of the toolkit still installs.

**A package name is wrong or out of date**
No code change needed — edit the relevant `bundles/<name>.bundle` file and
re-run `./install.sh --list` to confirm. See [Bundle file format](#bundle-file-format).

**Docker won't start (`Cannot connect to the Docker daemon`, `failed to find runc binary`)**
The distro package installed but the host wasn't set up. Run `./install.sh --docker`
(or press **`k`**) — it ensures `runc`/`containerd`, sets the required sysctls and
kernel modules, and enables + starts the daemon. See [Setting up Docker](#setting-up-docker).

**`permission denied … /var/run/docker.sock` when running `docker` without sudo**
Run `./install.sh --docker-check`. If it says you're in the `docker` group but this
shell predates it, run `newgrp docker` (or log out and back in) — re-adding yourself
won't help. If it says you're not a member, `./install.sh --docker` can add you.

**I want to see absolutely everything it would do**
`./install.sh --dry-run --all --with-optional`

## Bundle file format

Toolkits are plain-text files in `bundles/`, one per toolkit, named
`<slug>.bundle` (the slug is the `--bundle` name):

```
name: <Human Name>     shown in the menu / summary
description: <text>    shown before install
[core]                 always installed
[optional]             installed only with --with-optional / --all
<id> | debian=<pkg> | fedora=<pkg> | arch=<pkg> | suse=<pkg>
```

- `<id>` is a stable logical name used in messages and the summary.
- Each `family=<pkg>` token is optional. An **omitted family or `family=-`**
  means "no package there" — that tool is skipped with a warning, never fatal.
- Multiple packages for one tool: join with `+`
  (`debian=openjdk-17-jdk+openjdk-17-source`).
- Arch-only AUR package: `arch=aur:<pkg>` (treated as "no package" elsewhere).
- Lines before the first `[core]`/`[optional]` marker default to the core group.

**Adding a toolkit** is data-only — no Bash changes. Create
`bundles/<slug>.bundle`, then check how it resolves:

```sh
./install.sh --list                                  # your distro
./install.sh --force-family fedora --dry-run --bundle <slug> --with-optional
```

Add a case to `tests/` if it introduces a new parsing edge case.

## Docs and contributing

The two reference topics live in this README:
[Bundle file format](#bundle-file-format) and
[How it picks the right packages](#how-it-picks-the-right-packages) (supported
distros). For code style, tests, and the local checks, see
[`CONTRIBUTING.md`](CONTRIBUTING.md).

**Most changes are data, not code** — adding a tool or fixing a package name
is just an edit to a `bundles/*.bundle` file. The local gate is `make check`
(static checks + a dry-run across all four families); it never installs
anything for real.

## License

MIT — see [`LICENSE`](LICENSE). Use, modify, and redistribute freely.
