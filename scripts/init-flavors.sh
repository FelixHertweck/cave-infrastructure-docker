#!/usr/bin/env bash
# Creates the VM flavors CAVE needs (Windows/Linux labs and the packer image builds).
#
# API only: works against any OpenStack (self-hosted or managed), no access to the
# OpenStack host is needed. Creating *public* flavors requires admin rights. On a managed
# cloud without them, the creation is skipped with a warning; make sure flavors with these
# names (or equivalent ones) already exist there.
#
# Runs the `openstack` CLI directly when it is installed and OS_AUTH_URL is set,
# otherwise inside the `cave` container (docker compose).
set -euo pipefail

read -r -d '' FLAVOR_SCRIPT <<'EOF' || true
create_flavor_if_missing() {
  local name=$1 ram=$2 disk=$3 vcpus=$4
  if openstack flavor show "$name" >/dev/null 2>&1; then
    echo "Flavor '$name' already exists, skipping..."
  elif openstack flavor create --ram "$ram" --disk "$disk" --vcpus "$vcpus" --public "$name" >/dev/null; then
    echo "Created flavor '$name' (${ram}MB RAM, ${vcpus} VCPUs, ${disk}GB disk)"
  else
    echo "WARNING: could not create flavor '$name' (admin rights required?)" >&2
  fi
}

echo "Checking existing flavors..."

# Windows flavors
create_flavor_if_missing "windows.small" 4096 80 2
create_flavor_if_missing "windows.large" 16384 120 8

# Linux flavors
create_flavor_if_missing "linux.medium.50g" 4096 50 2
create_flavor_if_missing "linux.large.50g" 8192 50 4

# Packer build flavors
create_flavor_if_missing "client-medium" 4096 50 2
create_flavor_if_missing "client-large" 8192 50 4
create_flavor_if_missing "server-small" 2048 20 1
create_flavor_if_missing "server-large" 8192 50 4
create_flavor_if_missing "server-xlarge" 12288 50 4
create_flavor_if_missing "server-windows" 4096 80 2

echo ""
echo "Available VM flavors:"
openstack flavor list --public
EOF

main() {
  if command -v openstack >/dev/null 2>&1 && [ -n "${OS_AUTH_URL:-}" ]; then
    bash -c "$FLAVOR_SCRIPT"
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: neither the openstack CLI (with OS_* credentials) nor docker is available."
    return 1
  fi

  local script_dir project_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(dirname "$script_dir")"
  if [ ! -f "$project_dir/docker-compose.yml" ]; then
    echo "Error: docker-compose.yml not found in $project_dir"
    return 1
  fi

  cd "$project_dir"
  docker compose run --rm cave bash -c "$FLAVOR_SCRIPT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
