#!/usr/bin/env bash
# Sustainable fix for MicroStack OVN metadata agent crashing on newer kernels.
#
# Root cause: neutron-ovn-metadata-agent calls ip2.addr.delete() on a TAP
# interface inside a network namespace, which returns EOPNOTSUPP on kernels
# >= ~6.x under snap confinement. The resulting crash leaves the metadata
# namespace broken, so VMs cannot reach 169.254.169.254 and cloud-init never
# receives the SSH key pair -> Permission denied (publickey) on first boot.
#
# A second crash occurs in teardown_datapath() during startup cleanup of
# stale namespaces: del_veth() -> privileged.delete_interface() also raises
# InterfaceOperationNotSupported under snap confinement on newer kernels.
#
# Fix: patch both provision_datapath() and teardown_datapath() in agent.py to
# swallow those exceptions, then bind-mount the patched file over the
# read-only snap filesystem. A systemd service re-applies the bind-mount on
# every boot (and after snap refresh).
#
# Usage (as root):
#   ./fix_ovn_metadata.sh install   # patch, bind-mount, install service
#   ./fix_ovn_metadata.sh apply     # re-patch + bind-mount (called by service)
#   ./fix_ovn_metadata.sh status    # show whether fix is active

set -euo pipefail

SNAP_NAME="microstack"
PATCHED_DIR="/var/snap/microstack/common/fix-ovn-metadata"
SERVICE_NAME="fix-ovn-metadata-agent"

die() { echo "ERROR: $*" >&2; exit 1; }

snap_agent_path() {
    local rev snap_root found
    rev=$(readlink "/snap/${SNAP_NAME}/current") || die "MicroStack snap not found"
    snap_root="/snap/${SNAP_NAME}/${rev}"
    found=$(find "$snap_root" -path "*/neutron/agent/ovn/metadata/agent.py" | head -n 1)
    [ -n "$found" ] || die "agent.py not found under $snap_root (snap layout may have changed)"
    echo "$found"
}

patch_file() {
    local src="$1" dst="$2"
    [ -f "$src" ] || die "Source not found: $src"
    cp "$src" "$dst"
    python3 - "$dst" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

def make_try_except_block(line, extra_comment=""):
    """Wrap a single line in a try/except that swallows EOPNOTSUPP via privsep."""
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    sp = ' ' * indent
    block = [
        sp + 'try:\n',
        ' ' * (indent + 4) + stripped,
        # The OSError(EOPNOTSUPP) is serialised across the oslo.privsep IPC
        # channel and re-raised as InterfaceOperationNotSupported, so we
        # must catch Exception and check the type name instead of OSError.
        sp + 'except Exception as _exc:  # EOPNOTSUPP via privsep on newer kernels under snap confinement\n',
        sp + '    _ename = type(_exc).__name__\n',
        sp + '    _is_eopnotsupp = (isinstance(_exc, OSError) and _exc.errno == 95)\n',
        sp + '    _is_privsep_eopnotsupp = "OperationNotSupported" in _ename\n',
        sp + '    if not (_is_eopnotsupp or _is_privsep_eopnotsupp):\n',
        sp + '        raise\n',
        sp + '    LOG.debug("Ignoring EOPNOTSUPP%s (%s): %s", "%s", _ename, _exc)\n' % (
            (' ' + extra_comment) if extra_comment else '', ),
    ]
    return block

patched = []
i = 0
current_func = None
changes = 0

while i < len(lines):
    line = lines[i]

    # Track which function we are in
    if line.strip().startswith('def '):
        import re
        m = re.match(r'\s*def (\w+)', line)
        if m:
            current_func = m.group(1)

    already_wrapped = (i > 0 and 'try:' in lines[i - 1])

    # -----------------------------------------------------------------
    # Patch 1: provision_datapath() — ip2.addr.delete(ipaddr)
    # -----------------------------------------------------------------
    if (current_func == 'provision_datapath'
            and 'ip2.addr.delete(ipaddr)' in line
            and not already_wrapped):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        sp = ' ' * indent
        patched += [
            sp + 'try:\n',
            ' ' * (indent + 4) + stripped,
            sp + 'except Exception as _exc:  # EOPNOTSUPP via privsep on newer kernels under snap confinement\n',
            sp + '    _ename = type(_exc).__name__\n',
            sp + '    _is_eopnotsupp = (isinstance(_exc, OSError) and _exc.errno == 95)\n',
            sp + '    _is_privsep_eopnotsupp = "OperationNotSupported" in _ename\n',
            sp + '    if not (_is_eopnotsupp or _is_privsep_eopnotsupp):\n',
            sp + '        raise\n',
            sp + '    LOG.debug("Ignoring EOPNOTSUPP on addr.delete (%s): %s", _ename, _exc)\n',
        ]
        changes += 1
        i += 1
        continue

    # -----------------------------------------------------------------
    # Patch 2: teardown_datapath() — ip_lib.IPWrapper().del_veth(...)
    # -----------------------------------------------------------------
    if (current_func == 'teardown_datapath'
            and 'del_veth(' in line
            and not already_wrapped):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        sp = ' ' * indent
        patched += [
            sp + 'try:\n',
            ' ' * (indent + 4) + stripped,
            sp + 'except Exception as _exc:  # EOPNOTSUPP via privsep on newer kernels under snap confinement\n',
            sp + '    _ename = type(_exc).__name__\n',
            sp + '    _is_eopnotsupp = (isinstance(_exc, OSError) and _exc.errno == 95)\n',
            sp + '    _is_privsep_eopnotsupp = "OperationNotSupported" in _ename\n',
            sp + '    if not (_is_eopnotsupp or _is_privsep_eopnotsupp):\n',
            sp + '        raise\n',
            sp + '    LOG.debug("Ignoring EOPNOTSUPP on del_veth (%s): %s", _ename, _exc)\n',
        ]
        changes += 1
        i += 1
        continue

    patched.append(line)
    i += 1

if changes == 0:
    print("WARNING: no target patterns found — snap may have been updated or bug already fixed")
elif changes == 1:
    print("WARNING: only 1 of 2 expected patterns was found and patched")
    with open(path, 'w') as f:
        f.writelines(patched)
else:
    with open(path, 'w') as f:
        f.writelines(patched)
    print(f"Patched {changes} occurrence(s) in {path}")
PYEOF
}

unmount_all() {
    # Must run before patch_file: if the bind mount is already active,
    # snap_agent_path and PATCHED_DIR/agent.py share the same inode and cp fails.
    while IFS= read -r f; do
        if mountpoint -q "$f" 2>/dev/null; then
            umount "$f" 2>/dev/null && echo "Unmounted: $f" || true
        fi
    done < <(find "/snap/${SNAP_NAME}" -name "agent.py" -path "*/ovn/metadata/*" 2>/dev/null)
}

apply_bindmount() {
    local snap_agent
    snap_agent=$(snap_agent_path)
    local dst="$PATCHED_DIR/agent.py"

    [ -f "$dst" ] || die "Patched file missing: $dst — run 'install' first"

    mount --bind "$dst" "$snap_agent"
    echo "Bind mount applied: $dst -> $snap_agent"
}

install_service() {
    local script_path
    script_path="$(realpath "$0")"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Patch MicroStack OVN metadata agent for kernel compatibility
Documentation=https://github.com/FelixHertweck/CAVE-Infrastructure-docker
Before=snap.microstack.neutron-ovn-metadata-agent.service
After=snapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${script_path} apply

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    echo "Systemd service installed and enabled: ${SERVICE_NAME}.service"
}

cmd="${1:-install}"

case "$cmd" in
    apply)
        [ "$EUID" -eq 0 ] || die "Must run as root"
        mkdir -p "$PATCHED_DIR"
        unmount_all
        patch_file "$(snap_agent_path)" "$PATCHED_DIR/agent.py"
        apply_bindmount
        ;;
    install)
        [ "$EUID" -eq 0 ] || die "Must run as root"
        mkdir -p "$PATCHED_DIR"
        unmount_all
        patch_file "$(snap_agent_path)" "$PATCHED_DIR/agent.py"
        apply_bindmount
        install_service
        echo "Restarting neutron-ovn-metadata-agent..."
        snap restart "${SNAP_NAME}.neutron-ovn-metadata-agent"
        echo ""
        echo "Done. Monitor with:"
        echo "  journalctl -u snap.microstack.neutron-ovn-metadata-agent -f"
        ;;
    status)
        snap_agent=$(snap_agent_path)
        if mountpoint -q "$snap_agent" 2>/dev/null; then
            echo "Fix is ACTIVE (bind mount on $snap_agent)"
        else
            echo "Fix is NOT active"
        fi
        systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null \
            && echo "Systemd service: enabled" \
            || echo "Systemd service: not installed"
        ;;
    *)
        echo "Usage: $0 [install|apply|status]"
        exit 1
        ;;
esac
