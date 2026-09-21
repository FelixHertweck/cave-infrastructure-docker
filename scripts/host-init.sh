#!/usr/bin/env bash
# Host-level setup for a SELF-HOSTED OpenStack. Needs root on the OpenStack host. Not
# needed on a managed OpenStack, where the provider handles networking and reachability.
# Flavors (API only) are handled by init-flavors.sh, the Windows UEFI firmware fix for
# hypervisors with their own firmware by scripts/ovmf/ (see ovmf-apply.sh).
#
# Verified on MicroStack only. Other self-hosted backends: check for each step whether
# it is needed at all before running it.
#
# Usage: sudo ./scripts/host-init.sh <command>
#
#   network       NAT + forwarding so VMs on the external network reach the internet.
#                 Needed when the host itself routes that network (MicroStack: br-ex behind
#                 the host). Check first whether your external network is already routed.
#   deploy-user   The `vpnsetup` user the deployment scripts use over SSH to add iptables
#                 port-forwarding rules for the VPN. Only needed if the OpenStack floating
#                 IP network is reachable only through this host.
#   all           network + deploy-user
#
# Configuration (environment, see .env.sample):
#   OS_EXTERNAL_IF        Host interface towards the outside (default: from the default route)
#   OS_BRIDGE_IF          Bridge of the OpenStack external network (default: br-ex)
#   OS_NAT_SUBNET         External network CIDR to masquerade. Required, except on MicroStack
#                         (default there: 10.20.20.0/24). Look it up: `openstack subnet list --external`
set -euo pipefail

NAT_SUBNET="${OS_NAT_SUBNET:-}"
EXTERNAL_IF="${OS_EXTERNAL_IF:-}"
BRIDGE_IF="${OS_BRIDGE_IF:-br-ex}"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Error: This command must be run as root."
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

detect_external_if() {
  ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
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

setup_network() {
  if [ -z "$NAT_SUBNET" ]; then
    if [ -e /snap/microstack/current ]; then
      NAT_SUBNET="10.20.20.0/24"
      echo "MicroStack detected: using its default external network $NAT_SUBNET"
    else
      echo "Error: OS_NAT_SUBNET is not set. Set it to the CIDR of your OpenStack external network"
      echo "  (find it with: openstack subnet list --external; e.g. 172.24.4.0/24 on DevStack)."
      exit 1
    fi
  fi

  local iptables
  iptables=$(detect_iptables)
  echo "Using $iptables"

  if [ -z "$EXTERNAL_IF" ]; then
    EXTERNAL_IF="$(detect_external_if)"
    if [ -z "$EXTERNAL_IF" ]; then
      echo "Error: could not detect the external interface. Set OS_EXTERNAL_IF."
      exit 1
    fi
    echo "Detected external interface: $EXTERNAL_IF"
  fi
  if ! ip link show "$BRIDGE_IF" >/dev/null 2>&1; then
    echo "Warning: bridge '$BRIDGE_IF' does not exist (yet). If your OpenStack uses a different"
    echo "         external bridge, set OS_BRIDGE_IF and re-run."
  fi

  echo "Configuring NAT for $NAT_SUBNET ($BRIDGE_IF → $EXTERNAL_IF)..."

  sysctl -w net.ipv4.ip_forward=1 > /dev/null

  $iptables -t nat -C POSTROUTING -s "$NAT_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE 2>/dev/null || \
    $iptables -t nat -A POSTROUTING -s "$NAT_SUBNET" -o "$EXTERNAL_IF" -j MASQUERADE

  $iptables -C FORWARD -i "$BRIDGE_IF" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null || \
    $iptables -A FORWARD -i "$BRIDGE_IF" -o "$EXTERNAL_IF" -j ACCEPT

  $iptables -C FORWARD -i "$EXTERNAL_IF" -o "$BRIDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    $iptables -A FORWARD -i "$EXTERNAL_IF" -o "$BRIDGE_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

  persist_firewall_rules
}

setup_vpnsetup_user() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local ssh_key_name="${SSH_KEY_NAME:-id_ed25519}"

  # Resolve public key: explicit env var or auto-detect from ssh-keys/ directory
  local pubkey_file="${CAVE_DEPLOY_PUBKEY:-}"
  if [ -z "$pubkey_file" ]; then
    local candidate
    candidate="$(realpath "$script_dir/../ssh-keys/${ssh_key_name}.pub" 2>/dev/null || true)"
    [ -f "$candidate" ] && pubkey_file="$candidate"
  fi

  if [ -z "$pubkey_file" ] || [ ! -f "$pubkey_file" ]; then
    echo "Warning: No public key found for vpnsetup user."
    echo "  Set CAVE_DEPLOY_PUBKEY or place the key at ssh-keys/${ssh_key_name}.pub"
    echo "Skipping vpnsetup user setup."
    return 0
  fi

  echo "Setting up vpnsetup user (key: $pubkey_file)..."

  if ! id vpnsetup &>/dev/null; then
    useradd -m -s /bin/bash vpnsetup
    echo "  Created user vpnsetup"
  else
    echo "  User vpnsetup already exists"
  fi

  local auth_keys="/home/vpnsetup/.ssh/authorized_keys"
  mkdir -p /home/vpnsetup/.ssh
  chmod 700 /home/vpnsetup/.ssh
  touch "$auth_keys"

  local pubkey_content
  pubkey_content=$(cat "$pubkey_file")
  if ! grep -qF "$pubkey_content" "$auth_keys"; then
    echo "$pubkey_content" >> "$auth_keys"
    echo "  Added public key to authorized_keys"
  else
    echo "  Public key already in authorized_keys"
  fi

  chmod 600 "$auth_keys"
  chown -R vpnsetup:vpnsetup /home/vpnsetup/.ssh

  # Allow iptables only — covers both iptables and iptables-legacy across distros
  local sudoers_file="/etc/sudoers.d/vpnsetup"
  local sudoers_content="vpnsetup ALL=(ALL) NOPASSWD: /sbin/iptables, /usr/sbin/iptables, /sbin/iptables-legacy, /usr/sbin/iptables-legacy"
  if [ ! -f "$sudoers_file" ] || ! grep -qF "NOPASSWD" "$sudoers_file"; then
    local sudoers_tmp
    sudoers_tmp=$(mktemp)
    printf '%s\n' "$sudoers_content" > "$sudoers_tmp"
    if ! visudo -cf "$sudoers_tmp" >/dev/null 2>&1; then
      rm -f "$sudoers_tmp"
      echo "  ERROR: generated sudoers entry failed visudo check — not installed" >&2
      return 1
    fi
    install -m 0440 "$sudoers_tmp" "$sudoers_file"
    rm -f "$sudoers_tmp"
    echo "  Configured sudoers for iptables access"
  else
    echo "  sudoers already configured"
  fi

  echo "vpnsetup user setup complete."
}

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    network)     check_root; setup_network ;;
    deploy-user) check_root; setup_vpnsetup_user ;;
    all)         check_root; setup_network; setup_vpnsetup_user ;;
    -h|--help|help|"") usage ;;
    *) echo "Unknown command: $cmd" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
