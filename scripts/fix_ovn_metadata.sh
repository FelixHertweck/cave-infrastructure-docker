#!/usr/bin/env bash
# Sustainable fix for MicroStack OVN metadata agent crashing on newer kernels.
#
# Root cause: neutron-ovn-metadata-agent calls ip2.addr.delete() on a TAP
# interface inside a network namespace, which returns EOPNOTSUPP on kernels
# >= ~6.x under snap confinement. The resulting crash leaves the metadata
# namespace broken, so VMs cannot reach 169.254.169.254 and cloud-init never
# receives the SSH key pair -> Permission denied (publickey) on first boot.
#
# Fix: patch provision_datapath() in agent.py to swallow that exception, then
# bind-mount the patched file over the read-only snap filesystem. A systemd
# service re-applies the bind-mount on every boot (and after snap refresh).
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

patched = []
i = 0
in_func = False
changes = 0

while i < len(lines):
    line = lines[i]

    if 'def provision_datapath' in line:
        in_func = True
    elif in_func and line.strip().startswith('def '):
        in_func = False

    if (in_func
            and 'ip2.addr.delete(ipaddr)' in line
            and (i == 0 or 'try:' not in lines[i - 1])):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        sp = ' ' * indent
        patched += [
            sp + 'try:\n',
            ' ' * (indent + 4) + stripped,
            sp + 'except OSError as _exc:  # EOPNOTSUPP expected on newer kernels under snap confinement\n',
            sp + '    import errno as _errno\n',
            sp + '    if _exc.errno != _errno.EOPNOTSUPP:\n',
            sp + '        LOG.warning("Unexpected addr.delete error (errno=%s): %s", _exc.errno, _exc)\n',
        ]
        changes += 1
        i += 1
        continue

    patched.append(line)
    i += 1

if changes == 0:
    print("WARNING: target pattern not found — snap may have been updated or bug already fixed")
else:
    with open(path, 'w') as f:
        f.writelines(patched)
    print(f"Patched {changes} occurrence(s) in {path}")
PYEOF
}

apply_bindmount() {
    local snap_agent
    snap_agent=$(snap_agent_path)
    local dst="$PATCHED_DIR/agent.py"

    [ -f "$dst" ] || die "Patched file missing: $dst — run 'install' first"

    # Unmount any stale bind mounts from previous snap revisions
    while IFS= read -r f; do
        if mountpoint -q "$f" 2>/dev/null; then
            umount "$f" 2>/dev/null && echo "Unmounted stale: $f" || true
        fi
    done < <(find "/snap/${SNAP_NAME}" -name "agent.py" -path "*/ovn/metadata/*" 2>/dev/null)

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
        patch_file "$(snap_agent_path)" "$PATCHED_DIR/agent.py"
        apply_bindmount
        ;;
    install)
        [ "$EUID" -eq 0 ] || die "Must run as root"
        mkdir -p "$PATCHED_DIR"
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
