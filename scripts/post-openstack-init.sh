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
  
  # Check if openstack CLI is available
  if ! command -v openstack >/dev/null 2>&1; then
    echo "Error: openstack CLI not found. Please ensure it's installed and configured."
    return 1
  fi
  
  # Check if OpenStack authentication is set up
  if [ -z "${OS_AUTH_URL:-}" ] || [ -z "${OS_USERNAME:-}" ] || [ -z "${OS_PASSWORD:-}" ]; then
    echo "Error: OpenStack credentials not set. Please source your openrc file first."
    return 1
  fi
  
  # Define flavor specifications
  # windows.small: Minimum requirements for Windows Server
  # - 4 GB RAM (minimum for Windows Server with GUI)
  # - 2 VCPUs
  # - 60 GB root disk (sufficient for Windows Server installation)
  local SMALL_NAME="windows.small"
  local SMALL_RAM=4096
  local SMALL_VCPUS=2
  local SMALL_DISK=60
  
  # windows.large: High-performance Windows VM
  # - 16 GB RAM
  # - 8 VCPUs
  # - 120 GB root disk (for larger workloads)
  local LARGE_NAME="windows.large"
  local LARGE_RAM=16384
  local LARGE_VCPUS=8
  local LARGE_DISK=120
  
  # Create windows.small flavor if it doesn't exist
  if openstack flavor show "$SMALL_NAME" >/dev/null 2>&1; then
    echo "Flavor '$SMALL_NAME' already exists, skipping..."
  else
    echo "Creating flavor '$SMALL_NAME' (${SMALL_RAM}MB RAM, ${SMALL_VCPUS} VCPUs, ${SMALL_DISK}GB disk)..."
    openstack flavor create --id auto \
      --ram "$SMALL_RAM" \
      --disk "$SMALL_DISK" \
      --vcpus "$SMALL_VCPUS" \
      --public \
      "$SMALL_NAME"
    echo "Successfully created flavor '$SMALL_NAME'"
  fi
  
  # Create windows.large flavor if it doesn't exist
  if openstack flavor show "$LARGE_NAME" >/dev/null 2>&1; then
    echo "Flavor '$LARGE_NAME' already exists, skipping..."
  else
    echo "Creating flavor '$LARGE_NAME' (${LARGE_RAM}MB RAM, ${LARGE_VCPUS} VCPUs, ${LARGE_DISK}GB disk)..."
    openstack flavor create --id auto \
      --ram "$LARGE_RAM" \
      --disk "$LARGE_DISK" \
      --vcpus "$LARGE_VCPUS" \
      --public \
      "$LARGE_NAME"
    echo "Successfully created flavor '$LARGE_NAME'"
  fi
  
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
