# Bundle file format

A bundle is a domain toolkit (e.g. Java). One file per bundle in `bundles/`,
named `<slug>.bundle`. The slug is the menu/CLI name (`--bundle java`).

## Grammar

```
# comment              ignored (first non-space char is #)
name: <Human Name>     shown in the menu / summary
description: <text>    shown before install
[core]                 group marker — always installed
[optional]             group marker — installed only with --with-optional / --all
<id> | debian=<pkg> | fedora=<pkg> | arch=<pkg> | suse=<pkg>
```

Rules for a mapping line:

- `<id>` is a stable logical name used in messages/summaries.
- Each `family=value` token is optional. **An omitted family, or an explicit
  `family=-`, means "no package on that distro"** → the tool warns
  `no package mapping for <family>, skipping` and continues the rest of the
  bundle. It never aborts.
- Multiple packages for one tool: join with `+` →
  `debian=openjdk-17-jdk+openjdk-17-source`.
- AUR package (Arch only): `arch=aur:<pkg>`. On any non-Arch family this is
  treated the same as "no package" (skipped with a warning).
- A line with no `|` is malformed: it is logged with its line number and
  skipped — never fatal.
- Lines before the first `[core]`/`[optional]` marker default to the core group.

## Worked example — `bundles/java.bundle`

```
name: Java
description: JDK 17 (LTS), build tools (Maven, Gradle), and Java essentials

[core]
jdk         | debian=openjdk-17-jdk    | fedora=java-17-openjdk-devel | arch=jdk17-openjdk | suse=java-17-openjdk-devel
jdk-source  | debian=openjdk-17-source | fedora=java-17-openjdk-src   | arch=-             | suse=java-17-openjdk-src
maven       | debian=maven             | fedora=maven                 | arch=maven         | suse=maven
gradle      | debian=gradle            | fedora=gradle                | arch=gradle        | suse=gradle

[optional]
visualvm          | debian=visualvm | fedora=visualvm | arch=visualvm              | suse=-
jetbrains-toolbox | debian=-        | fedora=-        | arch=aur:jetbrains-toolbox | suse=-
```

- `jdk-source` has `arch=-` → skipped on Arch only.
- `jetbrains-toolbox` resolves only on Arch (via AUR); skipped elsewhere.
- `visualvm` has `suse=-` → skipped on openSUSE only.

## Java version

Java 17 LTS is the cross-distro default. To target another LTS, change only
the package names in `bundles/java.bundle` (data-only — no code change).

## Status of bundles

`java` is fully populated and verified across all four families. The other
bundles (`python go node devops databases editors`) are **partial /
best-effort**: package names are correct where confident and `-` where
uncertain. Corrections are data-only — edit the `.bundle` file and re-run
`./install.sh --list`.

## Adding a bundle

1. Create `bundles/<slug>.bundle` with `name:` / `description:` and mapping
   lines (use `[optional]` for non-essential tools).
2. `./install.sh --list` to see resolution for your distro.
3. `./install.sh --force-family <f> --dry-run --bundle <slug> --with-optional`
   for the other families.
4. Add coverage in `tests/` if it introduces a new parsing edge case.
