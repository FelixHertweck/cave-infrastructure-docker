#!/usr/bin/env bash
# Provider for SNAP-based hypervisors (MicroStack, openstack-hypervisor, ...).
#
# Finds the OVMF firmware that snaps bundle inside their read-only image and hands the
# directories to the generic engine ovmf-apply.sh, together with the snap's
# nova-compute/libvirt services so the mounts are in place before they start.
# The paths go through /snap/<name>/current, which stays valid across snap revisions.
#
# Read ovmf-apply.sh first for why and when this is needed. In short: only if Windows VMs
# boot with a black screen because the hypervisor ships its own 2M firmware.
#
# Usage:
#   sudo ovmf-snap.sh [--dry-run] [SNAP...]
#   sudo ovmf-snap.sh --remove
#
#   SNAP        Snap name(s) to look at, e.g. microstack. Default: every installed snap that
#               bundles an OVMF_CODE.secboot.fd.
#   --dry-run   Show what would be replaced; changes nothing, needs no root.
#   --remove    Undo (same as ovmf-apply.sh --remove).
#
# Examples:
#   ./ovmf-snap.sh --dry-run                        # what would be touched, on any snap host
#   sudo ./ovmf-snap.sh microstack                  # MicroStack (needed there)
#   sudo ./ovmf-snap.sh openstack-hypervisor        # Sunbeam, only if its Windows VMs fail
set -euo pipefail

SNAP_ROOT="${OS_SNAP_ROOT:-/snap}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Directories with OVMF_CODE.secboot.fd inside one snap, via its `current` symlink.
snap_ovmf_dirs() {
  find -L "$SNAP_ROOT/$1/current" -maxdepth 6 -type f -name 'OVMF_CODE.secboot.fd' 2>/dev/null \
    | xargs -r -n1 dirname | sort -u
}

# The snap's compute/libvirt units: they must not start before the firmware is replaced.
snap_units() {
  systemctl list-unit-files --no-legend "snap.$1.*" 2>/dev/null \
    | awk '{print $1}' | grep -E 'nova-compute|libvirt' || true
}

main() {
  local -a apply_args=() snaps=() dirs=()
  local remove=false name dir unit

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) apply_args+=("--dry-run") ;;
      --remove)  remove=true ;;
      -h|--help) usage; return 0 ;;
      -*)        echo "Error: unknown option: $1 (see --help)" >&2; exit 1 ;;
      *)         snaps+=("$1") ;;
    esac
    shift
  done

  if $remove; then exec "$HERE/ovmf-apply.sh" --remove; fi

  if [ ${#snaps[@]} -eq 0 ]; then
    for dir in "$SNAP_ROOT"/*/current; do
      [ -e "$dir" ] || continue
      name="${dir#"$SNAP_ROOT"/}"; snaps+=("${name%%/*}")
    done
  else
    for name in "${snaps[@]}"; do
      [ -e "$SNAP_ROOT/$name/current" ] || { echo "Error: snap '$name' is not installed." >&2; exit 1; }
    done
  fi

  for name in "${snaps[@]}"; do
    local -a found=()
    while IFS= read -r dir; do [ -n "$dir" ] && found+=("$dir"); done < <(snap_ovmf_dirs "$name")
    [ ${#found[@]} -gt 0 ] || continue
    echo "snap '$name' bundles OVMF firmware:"
    printf '  %s\n' "${found[@]}"
    dirs+=("${found[@]}")
    while IFS= read -r unit; do [ -n "$unit" ] && apply_args+=("--before" "$unit"); done < <(snap_units "$name")
  done

  if [ ${#dirs[@]} -eq 0 ]; then
    echo "No snap bundles OVMF firmware, nothing to replace."
    echo "If the hypervisor keeps it elsewhere, call ovmf-apply.sh with the directory directly."
    return 0
  fi

  echo
  exec "$HERE/ovmf-apply.sh" "${apply_args[@]}" "${dirs[@]}"
}

main "$@"
