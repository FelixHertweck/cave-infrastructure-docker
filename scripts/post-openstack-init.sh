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

add_windows_flavors() {
  echo "Adding Windows VM flavors to OpenStack..."
  
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
    
    # Windows flavor specifications
    WIN_SMALL_NAME="windows.small"
    WIN_SMALL_RAM=4096
    WIN_SMALL_VCPUS=2
    WIN_SMALL_DISK=60
    
    WIN_LARGE_NAME="windows.large"
    WIN_LARGE_RAM=16384
    WIN_LARGE_VCPUS=8
    WIN_LARGE_DISK=120
    
    # Linux flavor specifications
    LINUX_MEDIUM_NAME="linux.medium.50g"
    LINUX_MEDIUM_RAM=4096
    LINUX_MEDIUM_VCPUS=2
    LINUX_MEDIUM_DISK=50
    
    LINUX_LARGE_NAME="linux.large.50g"
    LINUX_LARGE_RAM=8192
    LINUX_LARGE_VCPUS=4
    LINUX_LARGE_DISK=50
    
    echo "Checking existing flavors..."
    
    # Create windows.small flavor if it does not exist
    if openstack flavor show "$WIN_SMALL_NAME" >/dev/null 2>&1; then
      echo "Flavor '\''$WIN_SMALL_NAME'\'' already exists, skipping..."
    else
      echo "Creating flavor '\''$WIN_SMALL_NAME'\'' (${WIN_SMALL_RAM}MB RAM, ${WIN_SMALL_VCPUS} VCPUs, ${WIN_SMALL_DISK}GB disk)..."
      openstack flavor create --id auto \
        --ram "$WIN_SMALL_RAM" \
        --disk "$WIN_SMALL_DISK" \
        --vcpus "$WIN_SMALL_VCPUS" \
        --public \
        "$WIN_SMALL_NAME"
      echo "Successfully created flavor '\''$WIN_SMALL_NAME'\''"
    fi
    
    # Create windows.large flavor if it does not exist
    if openstack flavor show "$WIN_LARGE_NAME" >/dev/null 2>&1; then
      echo "Flavor '\''$WIN_LARGE_NAME'\'' already exists, skipping..."
    else
      echo "Creating flavor '\''$WIN_LARGE_NAME'\'' (${WIN_LARGE_RAM}MB RAM, ${WIN_LARGE_VCPUS} VCPUs, ${WIN_LARGE_DISK}GB disk)..."
      openstack flavor create --id auto \
        --ram "$WIN_LARGE_RAM" \
        --disk "$WIN_LARGE_DISK" \
        --vcpus "$WIN_LARGE_VCPUS" \
        --public \
        "$WIN_LARGE_NAME"
      echo "Successfully created flavor '\''$WIN_LARGE_NAME'\''"
    fi
    
    # Create linux.medium flavor if it does not exist
    if openstack flavor show "$LINUX_MEDIUM_NAME" >/dev/null 2>&1; then
      echo "Flavor '\''$LINUX_MEDIUM_NAME'\'' already exists, skipping..."
    else
      echo "Creating flavor '\''$LINUX_MEDIUM_NAME'\'' (${LINUX_MEDIUM_RAM}MB RAM, ${LINUX_MEDIUM_VCPUS} VCPUs, ${LINUX_MEDIUM_DISK}GB disk)..."
      openstack flavor create --id auto \
        --ram "$LINUX_MEDIUM_RAM" \
        --disk "$LINUX_MEDIUM_DISK" \
        --vcpus "$LINUX_MEDIUM_VCPUS" \
        --public \
        "$LINUX_MEDIUM_NAME"
      echo "Successfully created flavor '\''$LINUX_MEDIUM_NAME'\''"
    fi
    
    # Create linux.large flavor if it does not exist
    if openstack flavor show "$LINUX_LARGE_NAME" >/dev/null 2>&1; then
      echo "Flavor '\''$LINUX_LARGE_NAME'\'' already exists, skipping..."
    else
      echo "Creating flavor '\''$LINUX_LARGE_NAME'\'' (${LINUX_LARGE_RAM}MB RAM, ${LINUX_LARGE_VCPUS} VCPUs, ${LINUX_LARGE_DISK}GB disk)..."
      openstack flavor create --id auto \
        --ram "$LINUX_LARGE_RAM" \
        --disk "$LINUX_LARGE_DISK" \
        --vcpus "$LINUX_LARGE_VCPUS" \
        --public \
        "$LINUX_LARGE_NAME"
      echo "Successfully created flavor '\''$LINUX_LARGE_NAME'\''"
    fi
    
    echo ""
    echo "Available VM flavors:"
    openstack flavor list --public | grep -E "(windows|linux)\." || echo "No custom flavors found"
  '
  
  echo "Windows flavor setup complete."
}

main() {
  check_root
  
  local iptables
  iptables=$(detect_iptables)
  echo "Using $iptables"
  
  setup_nat "$iptables"
  persist_firewall_rules
  setup_ovmf
  add_windows_flavors
  
  echo "Post-OpenStack initialization complete."
}

main
