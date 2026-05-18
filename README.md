# linux-toolkit-installer

Install a whole development toolkit with one keypress, on any major Linux
distro. Pick **Java** and it installs the JDK, Maven, and Gradle with the
right package names for *your* distribution — no manual hunting.

Pure Bash, zero external dependencies (just coreutils + your system package
manager). Works on **debian, fedora, arch, and suse** families.

## Quick start

```sh
git clone <this-repo> linux-toolkit-installer
cd linux-toolkit-installer
./install.sh                 # interactive menu
```

Or non-interactively:

```sh
./install.sh --list                  # what would be installed, for your distro
./install.sh --dry-run --bundle java # show every action, change nothing
./install.sh --bundle java           # actually install the Java toolkit
./install.sh --all --with-optional   # everything, including optional extras
```

| Option | Meaning |
|--------|---------|
| `--list` | List bundles and the packages they resolve to on this distro |
| `--bundle <name>` | Install one bundle (e.g. `java`) |
| `--all` | Install every bundle's core group |
| `--with-optional` | Also install `[optional]` tools |
| `--dry-run` | Print actions, change nothing, no root needed |
| `--yes` / `-y` | Skip confirmation prompts |
| `--force-family <f>` | Override distro detection: `debian\|fedora\|arch\|suse` |
| `-h`, `--help` | Usage |

`make install` symlinks `install.sh` into `~/.local/bin/linux-toolkit-installer`.

## Safety

- `--dry-run` mutates nothing and needs no `sudo` — use it to preview.
- Real runs ask for `sudo` up front and show a plan + confirmation first.
- Re-running is safe: already-installed packages are detected and skipped.
- A package with no mapping for your distro is skipped with a warning; the
  rest of the bundle still installs.

## Bundles

Domain toolkits live in `bundles/*.bundle` (plain text, easy to edit).

| Bundle | Status |
|--------|--------|
| `java` | **Stable** — verified across all four families |
| `python` `go` `node` `devops` `databases` `editors` | Partial / best-effort — package names correct where confident, `-` where uncertain. Corrections are data-only. |

See [`docs/BUNDLES.md`](docs/BUNDLES.md) for the file format and how to add a
bundle, [`docs/DISTROS.md`](docs/DISTROS.md) for distro support, and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design.

## Verifying the Java toolkit end to end

Static checks and dry-runs require nothing but Bash:

```sh
make test                                  # bash -n + shellcheck + bats (skips cleanly if absent)
./install.sh --list                        # resolves to openjdk-17-jdk, maven, gradle on debian
./install.sh --force-family arch --dry-run --bundle java --with-optional
```

A real install (changes your system — run it yourself when ready):

```sh
./install.sh --bundle java
java -version && javac -version && mvn -v && gradle -v
./install.sh --bundle java   # re-run: everything reports "already present"
```

## `personal/`

`personal/` holds machine-specific scripts (an NTFS auto-mount) that are **not
part of the tool** and not invoked by `install.sh`. They are kept, unchanged,
only for the original author. See `personal/README.md`.

## License

MIT — see [`LICENSE`](LICENSE). Change it freely if you prefer another license.
