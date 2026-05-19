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
- [Install as a command](#install-as-a-command)
- [Troubleshooting](#troubleshooting)
- [Docs and contributing](#docs-and-contributing)
- [The personal/ directory](#the-personal-directory)
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
| `s` | Set up a secure `sudo` privilege path |
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
See [`docs/BUNDLES.md`](docs/BUNDLES.md) for the format and how to add your own.

## How it picks the right packages

Your distro is detected automatically from `/etc/os-release` and mapped to one
of four families. The tool then uses whichever supported package manager is
actually installed (`apt`, `dnf`, `pacman`, or `zypper`).

If your distro isn't recognized, just tell it which family to use:

```sh
./install.sh --force-family debian   # or fedora | arch | suse
```

The full distro list and the package-manager resolution details are in
[`docs/DISTROS.md`](docs/DISTROS.md).

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

If `sudo` is not installed and you run a command that needs root, the tool
detects this automatically and offers to set up `sudo` for you. You can also
invoke it any time:

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

After the bootstrap completes, **log out and back in** (or run
`newgrp <group>`) for the new group membership to take effect.

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
re-run `./install.sh --list` to confirm. See [`docs/BUNDLES.md`](docs/BUNDLES.md).

**I want to see absolutely everything it would do**
`./install.sh --dry-run --all --with-optional`

## Docs and contributing

| Document | What's in it |
|----------|--------------|
| [`docs/BUNDLES.md`](docs/BUNDLES.md) | Bundle file format; how to add a toolkit |
| [`docs/DISTROS.md`](docs/DISTROS.md) | Supported distros; package-manager resolution |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Design and module layout |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Style, tests, and the local checks |

**Most changes are data, not code** — adding a tool or fixing a package name
is just an edit to a `bundles/*.bundle` file. The local gate is `make check`
(static checks + a dry-run across all four families); it never installs
anything for real.

## The personal/ directory

`personal/` holds machine-specific scripts (an NTFS auto-mount) kept by the
original author. They are **not part of the tool**, are never called by
`install.sh`, and you can ignore or delete them. See `personal/README.md`.

## License

MIT — see [`LICENSE`](LICENSE). Use, modify, and redistribute freely.
