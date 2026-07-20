# lib/docker.sh — install & repair Docker so the daemon comes up healthy.
# Sourced (never executed). Safe to source more than once.
# Depends on: lib/core.sh, lib/ui.sh, lib/distro.sh, lib/pkg.sh.
# Sourced after lib/sudo.sh in install.sh (so pm_require_privileges can
# bootstrap a missing sudo before any privileged step runs).
#
# Installs the distro's Docker engine plus the runtime bits whose absence
# crash-loops dockerd/BuildKit (containerd, runc), then configures the host so
# the service actually starts: loads the overlay + br_netfilter kernel modules,
# sets the IP-forward / bridge-netfilter sysctls, clears any prior systemd
# start rate-limit, and enables + starts docker. Optionally adds the invoking
# user to the 'docker' group. Idempotent: also repairs an already-installed but
# broken Docker (missing runc, daemon down, forwarding off).
#
# Zero external deps beyond base tools already assumed by the toolkit
# (systemctl, sysctl, modprobe, install) plus the packages it installs.
#
# Public contract:
#   docker_diagnose  read-only: report every layer's state + its fix; rc 1 if unhealthy.
#   docker_setup     interactive: diagnose, then install + configure + enable Docker.
# Private helpers:
#   _docker_core_pkg <family>        engine package name for a distro family
#   _docker_sysctl_lines             body of /etc/sysctl.d/99-docker.conf
#   _docker_modules_lines            body of /etc/modules-load.d/docker.conf
#   _docker_engine_kind              none | docker (real) | podman (shim on PATH)
#   _docker_runtime                  runc | crun | none
#   _docker_group_state <user>       missing | absent | inactive | active
#   _docker_module_loaded <mod>      0 if the kernel module is loaded
#   _docker_sysctl_get <key>         echo a sysctl value (unprivileged read)
#   _docker_report <level> <label> [detail]   one colored [OK]/[WARN]/[FAIL] line
#   _docker_run <argv...>            run, or (in --dry-run) print, a command
#   _docker_write_conf <mode> <dest> <content>  write file as root (teach in dry-run)
#   _docker_verify                   post-setup health checks (best-effort)

[[ -n ${_LTI_DOCKER_SH:-} ]] && return 0
_LTI_DOCKER_SH=1

# --- pure helpers -----------------------------------------------------------

# Pure: the distro's Docker engine package. runc/containerd are ensured
# separately (they are the pieces whose absence broke dockerd). Mirrors
# bundles/devops.bundle. Non-zero for an unknown family. Ends with return 0.
_docker_core_pkg() {
    case "$1" in
        debian) printf 'docker.io\n' ;;
        fedora) printf 'moby-engine\n' ;;
        arch)   printf 'docker\n' ;;
        suse)   printf 'docker\n' ;;
        *)      return 1 ;;
    esac
    return 0
}

# Pure: sysctl drop-in body. ip_forward lets Docker route container traffic;
# the bridge-nf-call keys make bridged traffic traverse iptables/nftables
# (they require br_netfilter loaded first). Always returns 0.
_docker_sysctl_lines() {
    printf '%s\n' \
        '# Managed by linux-toolkit-installer (docker_setup).' \
        'net.ipv4.ip_forward = 1' \
        'net.bridge.bridge-nf-call-iptables = 1' \
        'net.bridge.bridge-nf-call-ip6tables = 1'
    return 0
}

# Pure: modules-load drop-in body. overlay = Docker's default storage driver;
# br_netfilter backs the bridge sysctls above. Always returns 0.
_docker_modules_lines() {
    printf '%s\n' \
        '# Managed by linux-toolkit-installer (docker_setup).' \
        'overlay' \
        'br_netfilter'
    return 0
}

# --- diagnosis probes (read-only, no root, set -e safe) ---------------------

# Which 'docker' is on PATH: none | docker (real engine) | podman (podman-docker
# shim, common on Fedora — `docker` there just wraps Podman). Always returns 0.
_docker_engine_kind() {
    if ! command -v docker >/dev/null 2>&1; then
        printf 'none\n'; return 0
    fi
    if docker --version 2>&1 | grep -qi podman; then
        printf 'podman\n'
    else
        printf 'docker\n'
    fi
    return 0
}

# OCI runtime present: runc | crun | none. Always returns 0.
_docker_runtime() {
    if command -v runc >/dev/null 2>&1; then
        printf 'runc\n'
    elif command -v crun >/dev/null 2>&1; then
        printf 'crun\n'
    else
        printf 'none\n'
    fi
    return 0
}

# Membership state of <user> in the 'docker' group. Always returns 0, echoing:
#   missing  = no 'docker' group exists
#   absent   = group exists but <user> is not a member
#   inactive = <user> is a configured member, but THIS shell/process predates the
#              change (needs 'newgrp docker' or re-login) — the permission-denied
#              case where re-running usermod does nothing
#   active   = member and effective in this process
_docker_group_state() {
    local user=$1
    if ! getent group docker >/dev/null 2>&1; then
        printf 'missing\n'; return 0
    fi
    if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        printf 'absent\n'; return 0
    fi
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi
    return 0
}

# 0 if kernel module <mod> is currently loaded, 1 otherwise (never trips set -e).
_docker_module_loaded() {
    if lsmod 2>/dev/null | grep -qw "$1"; then return 0; fi
    return 1
}

# Echo a sysctl value (empty if unreadable). Unprivileged read. Always returns 0.
_docker_sysctl_get() {
    sysctl -n "$1" 2>/dev/null || true
    return 0
}

# Print one colored status line to stdout. <level> = ok | warn | fail. Returns 0
# for ok, 1 otherwise so callers tally issues via `|| n=$((n+1))`.
_docker_report() {
    local level=$1 label=$2 detail=${3:-} tag col
    case "$level" in
        ok)   tag='[OK]  '; col=${C_GREEN:-} ;;
        warn) tag='[WARN]'; col=${C_YELLOW:-} ;;
        *)    tag='[FAIL]'; col=${C_RED:-} ;;
    esac
    printf '%s%s%s %s%s\n' "$col" "$tag" "${C_RESET:-}" "$label" "${detail:+ — $detail}"
    [[ $level == ok ]]
}

# Run a command, or (in --dry-run) print it and change nothing. Mirror of
# _pm_run (lib/pkg.sh) so teach-mode output is consistent across the toolkit.
_docker_run() {
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "${C_DIM:-}" "${C_RESET:-}" "$*"
        return 0
    fi
    "$@"
}

# Write <content> to <dest> with mode <mode>, as root. In --dry-run, teach the
# write (path + content) and touch nothing. Otherwise stage the content in a
# registered temp file and install(1) it into place (atomic, correct mode).
_docker_write_conf() {
    local mode=$1 dest=$2 content=$3 tmp pfx=""
    if (( DRY_RUN )); then
        [[ -n ${SUDO:-} ]] && pfx="$SUDO "
        say "  ${pfx}install -m $mode <content> $dest"
        say "$content"
        return 0
    fi
    tmp=$(mktemp)
    lti_register_tmp "$tmp"
    printf '%s\n' "$content" >"$tmp"
    local -a cmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    cmd=( $SUDO install -m "$mode" "$tmp" "$dest" )
    _docker_run "${cmd[@]}"
}

# Best-effort post-setup checks. Never fatal; always returns 0.
_docker_verify() {
    if systemctl is-active --quiet docker; then
        ok "Docker service is active."
    else
        warn "Docker service is not active yet; check 'systemctl status docker'."
    fi

    local rt=""
    if command -v runc >/dev/null 2>&1; then
        rt=runc
    elif command -v crun >/dev/null 2>&1; then
        rt=crun
    fi
    if [[ -n $rt ]]; then
        ok "OCI runtime present: $rt."
    else
        warn "no 'runc'/'crun' runtime found — BuildKit/containers will fail to start."
    fi

    # Probe with $SUDO: right after setup the invoking shell is not yet in the
    # 'docker' group (needs re-login), so a plain `docker info` would fail on
    # socket permissions and misreport a healthy daemon as down.
    local -a infocmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    infocmd=( $SUDO docker info )
    if "${infocmd[@]}" >/dev/null 2>&1; then
        ok "Docker daemon is responding ('docker info' succeeded)."
    else
        warn "'docker info' failed — check the daemon: journalctl -u docker -n 50"
    fi
    return 0
}

# --- public entrypoints -----------------------------------------------------

# Read-only health report: inspect every layer of the Docker stack and print
# what is wrong + how to fix it. No root, changes nothing. Returns 0 if healthy,
# 1 if any issue was found (so `--docker-check` can signal health via exit code).
docker_diagnose() {
    banner "Docker health"
    local user issues=0
    user=$(_sudo_user)

    # 1. Engine — real Docker vs Podman shim vs absent.
    case "$(_docker_engine_kind)" in
        none)   _docker_report fail "engine " "Docker is not installed" || issues=$((issues + 1)) ;;
        podman) _docker_report warn "engine " "'docker' is Podman's shim (podman-docker), not real Docker" || issues=$((issues + 1)) ;;
        *)      _docker_report ok   "engine " "real Docker on PATH" || true ;;
    esac

    # 2. OCI runtime — the piece whose absence crash-loops dockerd/BuildKit.
    if [[ $(_docker_runtime) == none ]]; then
        _docker_report fail "runtime" "no runc/crun — BuildKit and containers will fail to start" || issues=$((issues + 1))
    else
        _docker_report ok "runtime" "$(_docker_runtime) present" || true
    fi

    # 3. Service + 4. socket reachability (derived without sudo).
    if systemctl is-active --quiet docker 2>/dev/null; then
        if systemctl is-enabled --quiet docker 2>/dev/null; then
            _docker_report ok "service" "active and enabled on boot" || true
        else
            _docker_report warn "service" "active, but not enabled — won't start on boot" || issues=$((issues + 1))
        fi
        if docker info >/dev/null 2>&1; then
            _docker_report ok "socket " "reachable from this shell without sudo" || true
        else
            _docker_report warn "socket " "daemon up but not reachable here — use sudo, or fix the 'docker' group (below)" || issues=$((issues + 1))
        fi
    else
        _docker_report fail "service" "daemon not running — 'systemctl enable --now docker'" || issues=$((issues + 1))
    fi

    # 5. Compose CLI (v2 plugin or v1 standalone).
    if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
        _docker_report ok "compose" "available" || true
    else
        _docker_report warn "compose" "no 'docker compose' / 'docker-compose' found" || issues=$((issues + 1))
    fi

    # 6. docker group — the three-state membership check.
    case "$(_docker_group_state "$user")" in
        missing)  _docker_report warn "group  " "no 'docker' group yet — setup will create it" || issues=$((issues + 1)) ;;
        absent)   _docker_report warn "group  " "$user is not in 'docker' — use sudo, or let setup add you" || issues=$((issues + 1)) ;;
        inactive) _docker_report warn "group  " "$user is in 'docker' but THIS shell predates it — run 'newgrp docker' or log out/in" || issues=$((issues + 1)) ;;
        active)   _docker_report ok   "group  " "$user is in 'docker' (active in this shell)" || true ;;
    esac

    # 7. sysctl — IP forwarding.
    if [[ $(_docker_sysctl_get net.ipv4.ip_forward) == 1 ]]; then
        _docker_report ok "sysctl " "net.ipv4.ip_forward = 1" || true
    else
        _docker_report warn "sysctl " "net.ipv4.ip_forward is not 1 — container networking may fail" || issues=$((issues + 1))
    fi

    # 8. Kernel modules.
    local m
    for m in overlay br_netfilter; do
        if _docker_module_loaded "$m"; then
            _docker_report ok "module " "$m loaded" || true
        else
            _docker_report warn "module " "$m not loaded" || issues=$((issues + 1))
        fi
    done

    say ""
    if (( issues == 0 )); then
        ok "Docker looks healthy — no issues found."
    else
        warn "$issues issue(s) found — run './install.sh --docker' to fix."
    fi
    (( issues == 0 ))
}

docker_setup() {
    banner "Set up Docker"

    local family=${DISTRO_FAMILY:-unknown} core user
    if ! core=$(_docker_core_pkg "$family"); then
        error "Unsupported distro family '$family' for Docker setup."
        return 1
    fi
    user=$(_sudo_user)

    # Diagnose first so the user sees exactly what is wrong before we touch anything.
    docker_diagnose || true
    say ""

    # Podman shim: detect and warn, but never auto-remove/replace it.
    if [[ $(_docker_engine_kind) == podman ]]; then
        warn "'docker' here is Podman's shim (podman-docker), not real Docker."
        say  "  This installs real Docker (moby-engine) and will NOT remove Podman."
        say  "  Until you remove podman-docker, the 'docker' command may still run Podman."
        confirm "Continue installing real Docker anyway?" || return 0
    fi

    info "This will install and bring up Docker:"
    say  "  - packages: $core containerd runc (+ docker-compose if available)"
    say  "  - modules:  overlay, br_netfilter  (/etc/modules-load.d/docker.conf)"
    say  "  - sysctl:   ip_forward + bridge netfilter  (/etc/sysctl.d/99-docker.conf)"
    say  "  - service:  systemctl enable --now docker"
    say  ""

    # Not gated on 'already installed': this path also repairs a broken install
    # (missing runc, daemon down), which is exactly why it exists.
    confirm "Install / repair Docker now?" || return 0

    pm_require_privileges          # no-op under root/dry-run; bootstraps sudo
    pm_refresh || warn "package index refresh failed; continuing."

    # 1. Engine + the runtime bits whose absence crash-loops dockerd/BuildKit.
    if ! pm_install "$core" containerd runc; then
        error "Failed to install Docker packages ($core containerd runc)."
        return 1
    fi
    # 2. Compose is best-effort: the v2 plugin often ships with the engine, and
    #    the standalone package is not named the same on every distro.
    pm_install docker-compose \
        || warn "docker-compose package not available; skipping (Docker Compose v2 may already be bundled as 'docker compose')."

    # 3. Kernel modules for overlay storage + bridge networking (load br_netfilter
    #    before the bridge sysctls below, which depend on it).
    _docker_write_conf 0644 /etc/modules-load.d/docker.conf "$(_docker_modules_lines)" \
        || warn "could not write /etc/modules-load.d/docker.conf."
    local -a modcmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    modcmd=( $SUDO modprobe overlay )
    _docker_run "${modcmd[@]}" || warn "could not load 'overlay' now (loads on next boot)."
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    modcmd=( $SUDO modprobe br_netfilter )
    _docker_run "${modcmd[@]}" || warn "could not load 'br_netfilter' now (bridge sysctls apply once loaded)."

    # 4. sysctl: IP forwarding + bridged traffic visible to iptables/nftables.
    _docker_write_conf 0644 /etc/sysctl.d/99-docker.conf "$(_docker_sysctl_lines)" \
        || warn "could not write /etc/sysctl.d/99-docker.conf."
    local -a syscmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    syscmd=( $SUDO sysctl --system )
    _docker_run "${syscmd[@]}" || warn "sysctl --system reported an issue; values apply on next boot."

    # 5. Clear any prior crash-loop rate-limit ("start request repeated too
    #    quickly"), then enable on boot + start now.
    local -a rfcmd encmd
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    rfcmd=( $SUDO systemctl reset-failed docker.service )
    _docker_run "${rfcmd[@]}" || true
    # shellcheck disable=SC2206  # intentional word-split of $SUDO
    encmd=( $SUDO systemctl enable --now docker )
    if ! _docker_run "${encmd[@]}"; then
        error "Failed to enable/start the Docker service. Check: journalctl -u docker -n 50"
        return 1
    fi
    ok "Docker service enabled and started."

    # 6. The 'docker' group. Ensure it exists, then act on the membership state:
    #    only offer usermod when genuinely absent; if the user is already a member
    #    but this shell predates it, the fix is 'newgrp'/re-login, not usermod.
    if ! getent group docker >/dev/null 2>&1; then
        local -a gacmd
        # shellcheck disable=SC2206  # intentional word-split of $SUDO
        gacmd=( $SUDO groupadd docker )
        _docker_run "${gacmd[@]}" || warn "could not create the 'docker' group."
    fi
    case "$(_docker_group_state "$user")" in
        active)
            ok "${user} is already in the 'docker' group (active in this shell)." ;;
        inactive)
            info "${user} is in the 'docker' group, but this shell predates it — run 'newgrp docker' or log out/in to use docker without sudo." ;;
        *)  # absent (or missing, i.e. the group we just created): offer to add.
            if confirm "Add ${user} to the 'docker' group so you can run docker without sudo? This grants root-equivalent access."; then
                local -a grpcmd
                # shellcheck disable=SC2206  # intentional word-split of $SUDO
                grpcmd=( $SUDO usermod -aG docker "$user" )
                if _docker_run "${grpcmd[@]}"; then
                    info "Added ${user} to 'docker'. Log out and back in (or run 'newgrp docker') for it to take effect."
                else
                    warn "could not add ${user} to the 'docker' group; use sudo to run docker."
                fi
            fi ;;
    esac

    # 7. Verify (real mode only — nothing changed under --dry-run).
    (( DRY_RUN )) || _docker_verify
    return 0
}
