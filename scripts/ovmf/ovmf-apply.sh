#!/usr/bin/env bash
# Replaces a hypervisor's bundled OVMF firmware with the host's 4M firmware.
#
# GENERIC ENGINE: this script does not know where your hypervisor keeps its firmware.
# You pass the directories that contain the hypervisor's OVMF_*.fd files. Finding them
# is the job of a provider script (ovmf-snap.sh for snap-based hypervisors such as
# MicroStack), or you look them up yourself and call this script by hand.
#
# Why: Windows images are built with the host's 4M OVMF (OVMF_CODE_4M.ms.fd +
# OVMF_VARS_4M.ms.fd, see windows-image-builder). A hypervisor that ships its own 2M
# firmware boots such images with a black screen (observed with MicroStack; the 2M and 4M
# CODE/VARS layouts are not interchangeable). Nova cannot pick the firmware variant per
# image, libvirt/QEMU on the hypervisor chooses it, so the fix has to happen on the
# hypervisor host. It is NOT always needed: Ubuntu 24.04's ovmf package ships only 4M
# files, and a hypervisor that bundles firmware may still pick its 4M files. Only MicroStack
# is confirmed to need it. Elsewhere, boot a Windows VM first and apply this only if it fails
# (details: scripts/ovmf/README.md).
#
# How: the files named below are bind-mounted over the hypervisor's copies (they usually
# live in a read-only image, e.g. a snap). A systemd unit (cave-ovmf-bindmount.service)
# repeats the mounts at every boot. The call is idempotent; files that already match the
# host's 4M firmware are left alone. The list of directories is replaced on each call.
#
# Usage:
#   sudo ovmf-apply.sh [--dry-run] [--before UNIT]... DIR [DIR...]
#   sudo ovmf-apply.sh --remove
#
#   DIR             Directory containing the hypervisor's OVMF_CODE.secboot.fd,
#                   OVMF_VARS.ms.fd and/or OVMF_VARS.fd (paths that stay valid across
#                   updates are best, e.g. /snap/<name>/current/... instead of a revision)
#   --before UNIT   systemd unit that must start after the mounts (usually the hypervisor's
#                   nova-compute/libvirt service). Repeatable.
#   --dry-run       Show what would happen; changes nothing, needs no root.
#   --remove        Undo: unmount, remove the unit, helper and state.
#
# Environment:
#   OS_HOST_OVMF_DIR   Directory with the host's 4M firmware (default: /usr/share/OVMF)
#
# Example (manual):
#   sudo ovmf-apply.sh --before snap.mystack.nova-compute.service /snap/mystack/current/share/OVMF
set -euo pipefail

HOST_OVMF_DIR="${OS_HOST_OVMF_DIR:-/usr/share/OVMF}"
STATE_DIR="/var/lib/cave/ovmf"
TARGET_LIST="/etc/cave/ovmf-targets"
HELPER="/usr/local/sbin/cave-ovmf-bindmount"
UNIT="cave-ovmf-bindmount.service"
LEGACY_UNIT="microstack-ovmf-fix.service"

# hypervisor file name -> host 4M file it is replaced with
FILES=(
  "OVMF_CODE.secboot.fd:OVMF_CODE_4M.secboot.fd"
  "OVMF_VARS.ms.fd:OVMF_VARS_4M.ms.fd"
  "OVMF_VARS.fd:OVMF_VARS_4M.fd"
)

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() { echo "Error: $*" >&2; exit 1; }

# Written to $HELPER; runs at boot (and on `systemctl restart`) via the unit.
install_helper() {
  cat > "$HELPER" <<'HELPER_EOF'
#!/usr/bin/env bash
# Managed by ovmf-apply.sh. Bind-mounts the host's 4M OVMF firmware over the hypervisor's
# firmware in the directories listed in /etc/cave/ovmf-targets. Idempotent.
set -u
STATE_DIR=/var/lib/cave/ovmf
LIST=/etc/cave/ovmf-targets
NAMES=(OVMF_CODE.secboot.fd OVMF_VARS.ms.fd OVMF_VARS.fd)

run() { if [ -n "${CAVE_OVMF_DRY_RUN:-}" ]; then echo "+ $*"; else "$@"; fi; }

for_each_file() {
  local action="$1" dir name src dst
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for name in "${NAMES[@]}"; do
      src="$STATE_DIR/$name"
      dst="$dir/$name"
      [ -f "$src" ] && [ -f "$dst" ] || continue
      "$action" "$src" "$dst"
    done
  done < "$LIST"
}

do_mount() {
  if cmp -s "$1" "$2"; then echo "ok (already 4M): $2"; else run mount --bind "$1" "$2" && echo "mounted: $2"; fi
}
do_umount() {
  if findmnt -M "$2" >/dev/null 2>&1; then run umount "$2" && echo "unmounted: $2"; fi
}

case "${1:-mount}" in
  mount)  for_each_file do_mount ;;
  umount) for_each_file do_umount ;;
  *) echo "Usage: $0 [mount|umount]" >&2; exit 1 ;;
esac
HELPER_EOF
  chmod 0755 "$HELPER"
}

unit_file() {
  cat <<EOF
[Unit]
Description=Bind-mount 4M OVMF firmware over the hypervisor's bundled firmware
After=snapd.service snapd.seeded.service
EOF
  if [ $# -gt 0 ]; then echo "Before=$*"; fi
  cat <<EOF

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER mount
ExecStop=$HELPER umount

[Install]
WantedBy=multi-user.target
EOF
}

do_remove() {
  [ "$EUID" -eq 0 ] || die "This command must be run as root."
  [ -x "$HELPER" ] && "$HELPER" umount || true
  for u in "$UNIT" "$LEGACY_UNIT"; do
    systemctl disable "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
  done
  rm -rf "$HELPER" "$STATE_DIR" "$TARGET_LIST"
  systemctl daemon-reload
  echo "OVMF bind-mounts removed."
}

main() {
  local dry_run=false remove=false
  local -a dirs=() before=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --remove)  remove=true ;;
      --before)  [ $# -ge 2 ] || die "--before needs a unit name"; before+=("$2"); shift ;;
      -h|--help) usage; return 0 ;;
      -*)        die "unknown option: $1 (see --help)" ;;
      *)         dirs+=("$1") ;;
    esac
    shift
  done

  if $remove; then do_remove; return; fi
  [ ${#dirs[@]} -gt 0 ] || { usage >&2; exit 1; }

  local pair name host_name dir found dst
  for pair in "${FILES[@]}"; do
    host_name="${pair#*:}"
    [ -f "$HOST_OVMF_DIR/$host_name" ] || die "$HOST_OVMF_DIR/$host_name not found. Install the ovmf package or set OS_HOST_OVMF_DIR."
  done

  echo "Host 4M firmware: $HOST_OVMF_DIR"
  local -a usable=()
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || die "not a directory: $dir"
    found=0
    for pair in "${FILES[@]}"; do
      name="${pair%%:*}"
      host_name="${pair#*:}"
      dst="$dir/$name"
      [ -f "$dst" ] || continue
      found=1
      if cmp -s "$HOST_OVMF_DIR/$host_name" "$dst"; then
        echo "  already 4M:  $dst"
      else
        echo "  replace:     $dst ($(stat -c %s "$dst") bytes -> $(stat -c %s "$HOST_OVMF_DIR/$host_name"))"
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "  warning: no OVMF_CODE.secboot.fd / OVMF_VARS.ms.fd / OVMF_VARS.fd in $dir, skipping"
    else
      usable+=("$dir")
    fi
  done
  [ ${#usable[@]} -gt 0 ] || die "none of the given directories contains hypervisor OVMF files."

  if $dry_run; then
    echo
    echo "Dry run: nothing changed. Unit that would be installed ($UNIT):"
    unit_file "${before[@]}" | sed 's/^/  | /'
    return 0
  fi

  [ "$EUID" -eq 0 ] || die "This command must be run as root (use --dry-run to only look)."

  mkdir -p "$STATE_DIR" "$(dirname "$TARGET_LIST")"
  for pair in "${FILES[@]}"; do
    cp "$HOST_OVMF_DIR/${pair#*:}" "$STATE_DIR/${pair%%:*}"
  done
  printf '%s\n' "${usable[@]}" > "$TARGET_LIST"
  install_helper
  unit_file "${before[@]}" > "/etc/systemd/system/$UNIT"

  # Replaces the MicroStack-only unit of earlier versions (post-openstack-init.sh).
  if [ -f "/etc/systemd/system/$LEGACY_UNIT" ]; then
    systemctl disable "$LEGACY_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$LEGACY_UNIT"
    echo "Removed legacy unit $LEGACY_UNIT"
  fi

  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null
  "$HELPER" mount

  echo "Done. After an update of the hypervisor package/snap the firmware is replaced again:"
  echo "  systemctl restart $UNIT"
}

main "$@"
