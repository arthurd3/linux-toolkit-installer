# personal/ — user-specific utilities (NOT part of the general tool)

These scripts are **hardcoded to a specific machine** (user `arthurd3`, device
`/dev/sda1`, mount point `/run/media/arthurd3/ThuzinMemoria`, Arch Linux). They
are **not** invoked by `install.sh` and are **not** portable.

They are kept here, unchanged, only so the original author can still use them.
Run them manually, at your own risk, and only after editing the hardcoded paths
for your own system.

| File | What it does |
|------|--------------|
| `mount-thuzin.sh` | Mounts an NTFS partition (`/dev/sda1`) at a fixed personal path. |
| `mount-disc.txt` | The mount commands the old `script.sh` used to print. |

## Not implemented

The old menu had an empty option *"When restart your pc shutdown your docker
containers"*. It was never implemented and no behavior is fabricated here. If
desired later, it belongs as a generalized, opt-in feature in the core tool —
not as a hardcoded personal script.
