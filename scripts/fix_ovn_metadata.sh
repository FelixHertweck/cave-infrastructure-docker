#!/usr/bin/env bash
# Sustainable fix for MicroStack OVN metadata agent crashing on newer kernels.
#
# Root cause: neutron-ovn-metadata-agent calls ip2.addr.delete() on a TAP
# interface inside a network namespace, which returns EOPNOTSUPP on kernels
# >= ~6.x under snap confinement. The resulting crash leaves the metadata
# namespace broken, so VMs cannot reach 169.254.169.254 and cloud-init never
# receives the SSH key pair -> Permission denied (publickey) on first boot.
#
# A second crash occurs in teardown_datapath() during cleanup of stale
# namespaces: del_veth() -> privileged.delete_interface() also raises
# InterfaceOperationNotSupported under snap confinement on newer kernels.
# This leaves metadata/DHCP ports behind, which later blocks
# `tofu destroy` / `openstack network delete` with RouterInUse / NetworkInUse
# and can leave addresses allocated (IpAddressAlreadyAllocated on the next deploy).
#
# Fix: patch both provision_datapath() and teardown_datapath() in agent.py to
# swallow those exceptions, then bind-mount the patched file over the
# read-only snap filesystem.
#
# What makes this version hold up (why the old one needed manual re-runs):
#   - The patch is VERIFIED. If a call site cannot be found or wrapped (e.g. agent.py
#     changed shape), it fails loudly instead of mounting an unpatched copy and
#     reporting success. The result is also checked through the live mount.
#   - It is re-applied when it is lost, not only at boot: a systemd path unit watches
#     /snap/microstack, so a snap refresh no longer leaves the agent unpatched until
#     the next reboot. Snap auto-refresh is additionally held.
#   - At boot it waits for the snap to be mounted (the old unit could run too early,
#     find no agent.py, fail, and let the agent start unpatched), retries on failure,
#     and restarts an agent that came up before the patch was in place.
#   - `check` shows whether the agent still hits EOPNOTSUPP in its journal and where,
#     which tells you if another call site needs patching.
#
# Usage (as root, except status/check):
#   ./fix_ovn_metadata.sh install    # patch, bind-mount, install units, hold refresh, restart agent
#   ./fix_ovn_metadata.sh apply      # re-patch + bind-mount if needed (used by the units)
#   ./fix_ovn_metadata.sh status     # is the fix active and verified?
#   ./fix_ovn_metadata.sh check      # does the agent still log EOPNOTSUPP errors? (journal)
#   ./fix_ovn_metadata.sh uninstall  # remove units and mount, un-hold refresh, restart agent
#
# Stale ports after a failed teardown are not fixed by this script: clean them with
#   exterminate.sh <lab-prefix> --hard

set -euo pipefail

SNAP_NAME="microstack"
SNAP_ROOT="${SNAP_ROOT:-/snap}"
AGENT_SERVICE="neutron-ovn-metadata-agent"
AGENT_UNIT="snap.${SNAP_NAME}.${AGENT_SERVICE}.service"
PATCHED_DIR="${PATCHED_DIR:-/var/snap/${SNAP_NAME}/common/fix-ovn-metadata}"
SERVICE_NAME="fix-ovn-metadata-agent"
WATCH_NAME="fix-ovn-metadata-agent-watch"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
MARKER="EOPNOTSUPP via privsep on newer kernels under snap confinement"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "-> $*" >&2; }
require_root() { [ "$EUID" -eq 0 ] || die "Must run as root"; }

# agent.py inside the snap, via the stable `current` symlink. Waits for the snap
# to be mounted: at boot this may run before snapd has mounted the squashfs.
snap_agent_path() {
    local found="" waited=0
    while :; do
        if [ -e "$SNAP_ROOT/$SNAP_NAME/current" ]; then
            found=$(find -L "$SNAP_ROOT/$SNAP_NAME/current" -path "*/neutron/agent/ovn/metadata/agent.py" 2>/dev/null | head -n 1 || true)
            [ -n "$found" ] && break
        fi
        [ "$waited" -lt "$WAIT_SECONDS" ] || die "agent.py not found under $SNAP_ROOT/$SNAP_NAME/current after ${WAIT_SECONDS}s (snap not mounted, or layout changed)"
        sleep 2
        waited=$((waited + 2))
    done
    echo "$found"
}

is_bind_mounted() { findmnt -M "$(readlink -f "$1")" >/dev/null 2>&1; }
marker_count() { grep -c "$MARKER" "$1" 2>/dev/null || true; }

# Patch provision_datapath()'s addr.delete(...) and teardown_datapath()'s del_veth(...)
# to swallow EOPNOTSUPP. Each call site must end up wrapped (freshly patched, or already
# patched from an earlier run), otherwise exit non-zero and write nothing.
patch_file() {
    local src="$1" dst="$2"
    [ -f "$src" ] || die "Source not found: $src"
    cp "$src" "$dst"
    python3 - "$dst" <<'PYEOF' || die "could not patch $src, not mounting anything"
import re
import sys

path = sys.argv[1]
MARKER = "EOPNOTSUPP via privsep on newer kernels under snap confinement"

with open(path) as f:
    lines = f.readlines()


def wrap(line, label):
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    sp = ' ' * indent
    return [
        sp + 'try:\n',
        ' ' * (indent + 4) + stripped,
        # The OSError(EOPNOTSUPP) is serialised across the oslo.privsep IPC
        # channel and re-raised as InterfaceOperationNotSupported, so we
        # must catch Exception and check the type name instead of OSError.
        sp + f'except Exception as _exc:  # {MARKER}\n',
        sp + '    _ename = type(_exc).__name__\n',
        sp + '    _is_eopnotsupp = (isinstance(_exc, OSError) and _exc.errno == 95)\n',
        sp + '    _is_privsep_eopnotsupp = "OperationNotSupported" in _ename\n',
        sp + '    if not (_is_eopnotsupp or _is_privsep_eopnotsupp):\n',
        sp + '        raise\n',
        sp + f'    LOG.debug("Ignoring EOPNOTSUPP in {label} (%s): %s", _ename, _exc)\n',
    ]


# function name -> text of the call that has to be wrapped
targets = [
    ('provision_datapath', 'addr.delete('),
    ('teardown_datapath', 'del_veth('),
]

patched = []
covered = set()
current_func = None
for i, line in enumerate(lines):
    m = re.match(r'\s*def (\w+)', line)
    if m:
        current_func = m.group(1)

    already_wrapped = i > 0 and 'try:' in lines[i - 1]
    func = next((f for f, needle in targets if current_func == f and needle in line), None)

    if func and already_wrapped:
        covered.add(func)
        patched.append(line)
    elif func:
        if line.count('(') != line.count(')'):
            print(f"FATAL: the call in {func}() spans several lines, refusing to wrap it: {line.strip()}",
                  file=sys.stderr)
            sys.exit(1)
        patched += wrap(line, func)
        covered.add(func)
    else:
        patched.append(line)

missing = [f for f, _ in targets if f not in covered]
if missing:
    print(
        f"FATAL: could not patch or verify: {', '.join(missing)}. agent.py likely changed shape "
        "in a snap update -- the patch patterns in this script need updating.",
        file=sys.stderr,
    )
    sys.exit(1)

with open(path, 'w') as f:
    f.writelines(patched)
print(f"Verified {len(targets)}/{len(targets)} call sites patched in {path}")
PYEOF

    # If the snap ships its own python, make sure it can still read the patched file:
    # a broken agent.py would take the agent down.
    local snap_python
    snap_python=$(find -L "$SNAP_ROOT/$SNAP_NAME/current/usr/bin" -maxdepth 1 -name 'python3*' -type f 2>/dev/null | head -n 1 || true)
    if [ -n "$snap_python" ]; then
        "$snap_python" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$dst" \
            || die "patched agent.py does not parse with the snap's python, not using it"
    fi
}

unmount_all() {
    # Must run before patch_file: if the bind mount is already active,
    # snap_agent_path and PATCHED_DIR/agent.py share the same inode and cp fails.
    local f
    while IFS= read -r f; do
        if mountpoint -q "$f" 2>/dev/null; then
            umount "$f" 2>/dev/null && info "Unmounted: $f" || true
        fi
    done < <(find "$SNAP_ROOT/$SNAP_NAME" -name "agent.py" -path "*/ovn/metadata/*" 2>/dev/null)
}

apply_bindmount() {
    local snap_agent dst="$PATCHED_DIR/agent.py"
    snap_agent=$(snap_agent_path)
    [ -f "$dst" ] || die "Patched file missing: $dst — run 'install' first"

    mount --bind "$dst" "$snap_agent"

    # Read back through the live path: proves the mount took effect and serves patched code.
    local hits
    hits=$(marker_count "$snap_agent")
    [ "${hits:-0}" -ge 2 ] || die "Bind mount applied but $snap_agent does not look patched (${hits:-0}/2 markers)"
    info "Bind mount applied and verified: $dst -> $snap_agent"
}

# True when the patched file is mounted, verified, and identical to what we would mount.
already_applied() {
    local agent="$1"
    is_bind_mounted "$agent" \
        && [ "$(marker_count "$agent")" -ge 2 ] \
        && [ -f "$PATCHED_DIR/agent.py" ] \
        && cmp -s "$PATCHED_DIR/agent.py" "$agent"
}

# Sets APPLIED=true if it (re)applied the patch. Call it as a plain command, never inside
# `if` or `... || ...`: that would switch off `set -e` for everything it calls, and a failed
# patch could then still get mounted.
APPLIED=false
do_apply() {
    require_root
    mkdir -p "$PATCHED_DIR"
    local agent
    agent=$(snap_agent_path)
    if already_applied "$agent"; then
        info "Fix already applied and verified, nothing to do"
        return 0
    fi
    unmount_all
    agent=$(snap_agent_path)
    patch_file "$agent" "$PATCHED_DIR/agent.py"
    apply_bindmount
    APPLIED=true
}

restart_and_verify_agent() {
    info "Restarting ${AGENT_SERVICE}..."
    snap restart "${SNAP_NAME}.${AGENT_SERVICE}"
    sleep 3
    systemctl is-active --quiet "$AGENT_UNIT" \
        || die "${AGENT_SERVICE} is not active after restart — check: journalctl -u $AGENT_UNIT -n 100"
    info "${AGENT_SERVICE} is active"
}

hold_snap_refresh() {
    if snap refresh --hold=forever "$SNAP_NAME" >/dev/null 2>&1; then
        info "MicroStack snap auto-refresh held (forever)"
    elif snap refresh --hold "$SNAP_NAME" >/dev/null 2>&1; then
        info "MicroStack snap auto-refresh held"
    else
        info "WARNING: could not hold snap auto-refresh; the watch unit still re-applies the patch after a refresh"
    fi
}

install_units() {
    local script_path
    script_path="$(realpath "$0")"

    # No RemainAfterExit: every trigger (boot, path unit) runs `apply` again.
    cat > "$UNIT_DIR/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Patch MicroStack OVN metadata agent for kernel compatibility
Documentation=https://github.com/FelixHertweck/CAVE-Infrastructure-docker
After=snapd.service snapd.socket
Before=${AGENT_UNIT}

[Service]
Type=oneshot
TimeoutStartSec=300
Restart=on-failure
RestartSec=15
ExecStart=${script_path} apply

[Install]
WantedBy=multi-user.target
EOF

    # A snap refresh replaces agent.py at any time, not only at boot.
    cat > "$UNIT_DIR/${WATCH_NAME}.path" <<EOF
[Unit]
Description=Re-apply the OVN metadata agent patch when the MicroStack snap changes

[Path]
PathChanged=${SNAP_ROOT}/${SNAP_NAME}
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    systemctl enable --now "${WATCH_NAME}.path"
    info "Units installed: ${SERVICE_NAME}.service, ${WATCH_NAME}.path"
}

pyroute2_version() {
    find -L "$SNAP_ROOT/$SNAP_NAME/current" -maxdepth 8 \( -name 'pyroute2-*.dist-info' -o -name 'pyroute2-*.egg-info' \) 2>/dev/null \
        | head -n 1 | sed 's|.*/pyroute2-||; s|\.\(dist\|egg\)-info$||'
}

cmd="${1:-install}"

case "$cmd" in
    apply)
        # Only restart the agent if we changed something and it is already running,
        # i.e. it came up before the patch was in place.
        do_apply
        if [ "$APPLIED" = true ] && systemctl is-active --quiet "$AGENT_UNIT"; then
            restart_and_verify_agent
        fi
        ;;
    install)
        do_apply
        hold_snap_refresh
        install_units
        restart_and_verify_agent
        echo ""
        echo "Done. Check the agent later with:  $0 status   /   $0 check"
        ;;
    uninstall)
        require_root
        systemctl disable --now "${WATCH_NAME}.path" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
        rm -f "$UNIT_DIR/${SERVICE_NAME}.service" "$UNIT_DIR/${WATCH_NAME}.path"
        systemctl daemon-reload
        unmount_all
        rm -rf "$PATCHED_DIR"
        snap refresh --unhold "$SNAP_NAME" >/dev/null 2>&1 && info "Snap auto-refresh un-held" || true
        restart_and_verify_agent
        echo "Fix removed, ${AGENT_SERVICE} runs unpatched again."
        ;;
    status)
        snap_agent=$(snap_agent_path)
        if is_bind_mounted "$snap_agent"; then
            hits=$(marker_count "$snap_agent")
            if [ "${hits:-0}" -ge 2 ]; then
                echo "Fix is ACTIVE and VERIFIED ($hits/2 call sites patched in the live agent.py)"
            else
                echo "Fix bind mount present but content looks WRONG (${hits:-0}/2) — run: $0 apply"
            fi
        else
            echo "Fix is NOT active — run: $0 apply"
        fi
        systemctl is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1 \
            && echo "Boot-time unit: enabled" || echo "Boot-time unit: not installed"
        if systemctl is-enabled "${WATCH_NAME}.path" >/dev/null 2>&1; then
            echo "Refresh-watch unit: enabled ($(systemctl is-active "${WATCH_NAME}.path" 2>/dev/null || echo inactive))"
        else
            echo "Refresh-watch unit: not installed"
        fi
        hold_line=$(snap info "$SNAP_NAME" 2>/dev/null | grep -i '^hold:' || true)
        echo "Snap auto-refresh: ${hold_line:-not held (or not reported by this snapd)}"
        echo "pyroute2 in the snap: $(pyroute2_version || true)  (upstream fix for the root cause is >= 0.6.10)"
        if systemctl is-active --quiet "$AGENT_UNIT"; then
            echo "${AGENT_SERVICE}: active"
        else
            echo "${AGENT_SERVICE}: NOT active — journalctl -u $AGENT_UNIT -n 100"
        fi
        ;;
    check)
        pattern='InterfaceOperationNotSupported|Operation not supported|EOPNOTSUPP'
        hits=$(journalctl -u "$AGENT_UNIT" --since "24 hours ago" --no-pager 2>/dev/null | grep -Ec "$pattern" || true)
        if [ "${hits:-0}" -eq 0 ]; then
            echo "OK: no EOPNOTSUPP errors from ${AGENT_SERVICE} in the last 24 hours."
        else
            echo "${hits} EOPNOTSUPP-related log lines from ${AGENT_SERVICE} in the last 24 hours."
            echo "Last occurrences (the traceback names the function that still fails):"
            journalctl -u "$AGENT_UNIT" --since "24 hours ago" --no-pager 2>/dev/null \
                | grep -E "$pattern|File \".*agent\.py\"" | tail -n 12
            echo
            echo "If these appear AFTER the fix was active, another call site needs the same try/except;"
            echo "add it to 'targets' in patch_file()."
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 [install|apply|status|check|uninstall]"
        exit 1
        ;;
esac
