#!/usr/bin/env bash
set -euo pipefail

NAT_SUBNET="${OS_NAT_SUBNET:-10.20.20.0/24}"
EXTERNAL_IF="${OS_EXTERNAL_IF:-enp1s0}"
BRIDGE_IF="${OS_BRIDGE_IF:-br-ex}"

MICROSTACK_OVMF_DIR="/snap/microstack/245/usr/share/OVMF"
HOST_OVMF_DIR="/var/snap/microstack/common/ovmf"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
  fi
}

detect_iptables() {
  if command -v iptables-legacy >/dev/null 2>&1; then
    echo "iptables-legacy"
  else
    echo "iptables"
  fi
}

setup_nat() {
  local iptables="$1"
  
  echo "Configuring NAT for $NAT_SUBNET ($BRIDGE_IF → $EXTERNAL_IF)..."
  
  sysctl -w net.ipv4.ip_forward=1 > /dev/null
  
  $iptables -t nat -C POSTROUTING -s "$NAT_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE 2>/dev/null || \
    $iptables -t nat -A POSTROUTING -s "$NAT_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE
  
  $iptables -C FORWARD -i "$BRIDGE_IF" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null || \
    $iptables -A FORWARD -i "$BRIDGE_IF" -o "$EXTERNAL_IF" -j ACCEPT
  
  $iptables -C FORWARD -i "$EXTERNAL_IF" -o "$BRIDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    $iptables -A FORWARD -i "$EXTERNAL_IF" -o "$BRIDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

persist_firewall_rules() {
  echo "Persisting firewall rules..."
  
  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y iptables-persistent
  fi
  
  netfilter-persistent save
}

# MicroStack bundles 2M OVMF firmware, but Windows images are built with 4M OVMF
# (OVMF_CODE_4M.ms.fd + OVMF_VARS_4M.ms.fd). Using mismatched firmware sizes causes
# a silent black screen on boot. Since the snap is read-only, we bind-mount the
# host's 4M OVMF files over the snap's 2M files and persist this via a systemd unit.
setup_ovmf() {
  echo "Setting up 4M OVMF firmware for MicroStack..."

  # Verify host has 4M OVMF files
  if [ ! -f /usr/share/OVMF/OVMF_CODE_4M.secboot.fd ]; then
    echo "Error: /usr/share/OVMF/OVMF_CODE_4M.secboot.fd not found. Install ovmf package."
    exit 1
  fi

  mkdir -p "$HOST_OVMF_DIR"
  cp /usr/share/OVMF/OVMF_CODE_4M.secboot.fd "$HOST_OVMF_DIR/OVMF_CODE.secboot.fd"
  cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd      "$HOST_OVMF_DIR/OVMF_VARS.ms.fd"
  cp /usr/share/OVMF/OVMF_VARS_4M.fd         "$HOST_OVMF_DIR/OVMF_VARS.fd"

  mount --bind "$HOST_OVMF_DIR/OVMF_CODE.secboot.fd" "$MICROSTACK_OVMF_DIR/OVMF_CODE.secboot.fd"
  mount --bind "$HOST_OVMF_DIR/OVMF_VARS.ms.fd"      "$MICROSTACK_OVMF_DIR/OVMF_VARS.ms.fd"
  mount --bind "$HOST_OVMF_DIR/OVMF_VARS.fd"         "$MICROSTACK_OVMF_DIR/OVMF_VARS.fd"

  echo "Persisting OVMF bind-mounts via systemd..."
  cat > /etc/systemd/system/microstack-ovmf-fix.service << EOF
[Unit]
Description=Bind-mount 4M OVMF firmware over MicroStack snap (2M)
After=snapd.service
Before=snap.microstack.nova-compute.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount --bind ${HOST_OVMF_DIR}/OVMF_CODE.secboot.fd ${MICROSTACK_OVMF_DIR}/OVMF_CODE.secboot.fd
ExecStart=/bin/mount --bind ${HOST_OVMF_DIR}/OVMF_VARS.ms.fd      ${MICROSTACK_OVMF_DIR}/OVMF_VARS.ms.fd
ExecStart=/bin/mount --bind ${HOST_OVMF_DIR}/OVMF_VARS.fd         ${MICROSTACK_OVMF_DIR}/OVMF_VARS.fd
ExecStop=/bin/umount ${MICROSTACK_OVMF_DIR}/OVMF_CODE.secboot.fd
ExecStop=/bin/umount ${MICROSTACK_OVMF_DIR}/OVMF_VARS.ms.fd
ExecStop=/bin/umount ${MICROSTACK_OVMF_DIR}/OVMF_VARS.fd

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable microstack-ovmf-fix.service

  echo "OVMF firmware setup complete."
}

add_custom_flavors() {
  echo "Adding custom VM flavors to OpenStack..."
  
  # Check if docker compose is available
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker CLI not found."
    return 1
  fi
  
  # Check if we're in the right directory (where docker-compose.yml exists)
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local project_dir="$(dirname "$script_dir")"
  
  if [ ! -f "$project_dir/docker-compose.yml" ]; then
    echo "Error: docker-compose.yml not found in $project_dir"
    return 1
  fi
  
  cd "$project_dir"
  
  # Execute all flavor creation commands in a single container run
  docker compose run --rm cave bash -c '
    set -e
    
    create_flavor_if_missing() {
      local name=$1
      local ram=$2
      local disk=$3
      local vcpus=$4
      if openstack flavor show "$name" >/dev/null 2>&1; then
        echo "Flavor '\''$name'\'' already exists, skipping..."
      else
        echo "Creating flavor '\''$name'\'' (${ram}MB RAM, ${vcpus} VCPUs, ${disk}GB disk)..."
        openstack flavor create \
          --ram "$ram" \
          --disk "$disk" \
          --vcpus "$vcpus" \
          --public \
          "$name"
        echo "Successfully created flavor '\''$name'\''"
      fi
    }
    
    echo "Checking existing flavors..."
    
    # Windows flavor specifications
    create_flavor_if_missing "windows.small" 4096 60 2
    create_flavor_if_missing "windows.large" 16384 120 8
    
    # Linux flavor specifications
    create_flavor_if_missing "linux.medium.50g" 4096 50 2
    create_flavor_if_missing "linux.large.50g" 8192 50 4
    
    # Packer build flavors
    create_flavor_if_missing "client-medium" 4096 20 2
    create_flavor_if_missing "client-large" 8192 20 4
    create_flavor_if_missing "server-small" 2048 20 1
    create_flavor_if_missing "server-large" 8192 20 4
    create_flavor_if_missing "server-windows" 4096 60 2
    
    echo ""
    echo "Available VM flavors:"
    openstack flavor list --public || echo "No custom flavors found"
  '
  
  echo "Custom flavor setup complete."
}

main() {
  check_root
  
  local iptables
  iptables=$(detect_iptables)
  echo "Using $iptables"
  
  setup_nat "$iptables"
  persist_firewall_rules
  setup_ovmf
  add_custom_flavors
  
  echo "Post-OpenStack initialization complete."
}

main
