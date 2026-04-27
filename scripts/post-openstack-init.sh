#!/usr/bin/env bash
set -euo pipefail

NAT_SUBNET="${OS_NAT_SUBNET:-10.20.20.0/24}"
EXTERNAL_IF="${OS_EXTERNAL_IF:-enp1s0}"
BRIDGE_IF="${OS_BRIDGE_IF:-br-ex}"

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
    
    # Flavor specifications
    SMALL_NAME="windows.small"
    SMALL_RAM=4096
    SMALL_VCPUS=2
    SMALL_DISK=60
    
    LARGE_NAME="windows.large"
    LARGE_RAM=16384
    LARGE_VCPUS=8
    LARGE_DISK=120
    
    echo "Checking existing flavors..."
    
    # Create windows.small flavor if it does not exist
    if openstack flavor show "$SMALL_NAME" >/dev/null 2>&1; then
      echo "Flavor '\''$SMALL_NAME'\'' already exists, skipping..."
    else
      echo "Creating flavor '\''$SMALL_NAME'\'' (${SMALL_RAM}MB RAM, ${SMALL_VCPUS} VCPUs, ${SMALL_DISK}GB disk)..."
      openstack flavor create --id auto \
        --ram "$SMALL_RAM" \
        --disk "$SMALL_DISK" \
        --vcpus "$SMALL_VCPUS" \
        --public \
        "$SMALL_NAME"
      echo "Successfully created flavor '\''$SMALL_NAME'\''"
    fi
    
    # Create windows.large flavor if it does not exist
    if openstack flavor show "$LARGE_NAME" >/dev/null 2>&1; then
      echo "Flavor '\''$LARGE_NAME'\'' already exists, skipping..."
    else
      echo "Creating flavor '\''$LARGE_NAME'\'' (${LARGE_RAM}MB RAM, ${LARGE_VCPUS} VCPUs, ${LARGE_DISK}GB disk)..."
      openstack flavor create --id auto \
        --ram "$LARGE_RAM" \
        --disk "$LARGE_DISK" \
        --vcpus "$LARGE_VCPUS" \
        --public \
        "$LARGE_NAME"
      echo "Successfully created flavor '\''$LARGE_NAME'\''"
    fi
    
    echo ""
    echo "Available Windows flavors:"
    openstack flavor list --public | grep -E "windows\\.(small|large)" || echo "No Windows flavors found"
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
  add_windows_flavors
  
  echo "Post-OpenStack initialization complete."
}

main
