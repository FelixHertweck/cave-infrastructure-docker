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

main() {
  check_root
  
  local iptables
  iptables=$(detect_iptables)
  echo "Using $iptables"
  
  setup_nat "$iptables"
  persist_firewall_rules
  
  echo "Post-OpenStack initialization complete."
}

main
