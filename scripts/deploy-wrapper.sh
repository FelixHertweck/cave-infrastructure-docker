#!/bin/bash
# Wrapper for make_it_so.sh - Simplifies CAVE infrastructure deployment
# Automatically handles common parameters and provides interactive prompts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${BLUE}║         CAVE Infrastructure - Deployment Wrapper           ║${NC}" >&2
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n" >&2
}

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}" >&2
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}" >&2
}

validate_file() {
    if [ ! -f "$1" ]; then
        print_error "File not found: $1"
        return 1
    fi
}

validate_credentials() {
    if [ -z "$OS_PASSWORD" ]; then
        print_error "OS_PASSWORD is not set!"
        print_error "Make sure to source credentials: source .openrc or .env"
        exit 1
    fi
    print_success "OpenStack credentials validated"
}

validate_ssh_key() {
    if [ -z "$SSH_KEY_NAME" ]; then
        print_error "SSH_KEY_NAME is not set in .env"
        exit 1
    fi
    
    local ssh_key_path="/home/cave/.ssh/$SSH_KEY_NAME"
    if [ ! -f "$ssh_key_path" ]; then
        print_error "SSH key not found: $ssh_key_path"
        print_error "Make sure your SSH key is in ./ssh-keys/$SSH_KEY_NAME"
        exit 1
    fi
    print_success "SSH key found: $SSH_KEY_NAME"
    echo "$ssh_key_path"
}

setup_openstack_toml() {
    local toml_path="/cave/backend/configs/openstack.toml"
    
    print_info "Generating OpenStack configuration..."
    
    # 0. Import SSH key to OpenStack
    local ssh_key_path="/home/cave/.ssh/$SSH_KEY_NAME"
    local ssh_key_name="${SSH_KEY_NAME%.*}"  # Remove extension if any
    
    print_info "Checking SSH key in OpenStack..."
    if openstack keypair show "$ssh_key_name" >/dev/null 2>&1; then
        print_success "SSH keypair '$ssh_key_name' already exists in OpenStack"
    else
        if [ ! -f "${ssh_key_path}.pub" ]; then
            print_error "Public key file '${ssh_key_path}.pub' not found. Cannot import keypair to OpenStack."
            exit 1
        fi
        print_info "Importing SSH key '$ssh_key_name' to OpenStack..."
        openstack keypair create --public-key "${ssh_key_path}.pub" "$ssh_key_name"
        print_success "SSH keypair '$ssh_key_name' imported to OpenStack"
    fi
    
    # 1. Find Public Network (following build-images.sh logic)
    local public_net_id
    local public_net_name
    public_net_id=$(openstack network list --external -f value -c ID | head -n 1)
    public_net_name=$(openstack network list --external -f value -c Name | head -n 1)
    
    if [ -z "$public_net_id" ]; then
        print_error "Could not find an external (public) network in OpenStack!"
        exit 1
    fi
    print_success "Found public network: $public_net_id ($public_net_name)"
    
    # 2. Get the subnet of the public network (for floating IPs)
    local public_subnet_id
    public_subnet_id=$(openstack subnet list --network "$public_net_id" -f value -c ID | head -n 1)
    
    if [ -z "$public_subnet_id" ]; then
        print_error "Could not find a subnet for the public network!"
        exit 1
    fi
    print_success "Found public network subnet: $public_subnet_id"
    
    # 3. Create/Find Management Subnet
    local mgmt_net_name="cave-mgmt-net"
    local mgmt_subnet_name="cave-mgmt-subnet"
    local mgmt_subnet_cidr="${CAVE_MGMT_SUBNET_CIDR:-10.99.0.0/24}"
    local mgmt_net_id
    local mgmt_subnet_id

    print_info "Ensuring management network '$mgmt_net_name' exists..."
    mgmt_net_id=$(openstack network show "$mgmt_net_name" -f value -c id 2>/dev/null || openstack network create "$mgmt_net_name" -f value -c id)

    print_info "Ensuring management subnet '$mgmt_subnet_name' exists..."
    if ! openstack subnet show "$mgmt_subnet_name" -f value -c id >/dev/null 2>&1; then
        # Check for exact CIDR conflict with any existing subnet (catches duplicates, not partial overlaps)
        if openstack subnet list -f value -c Subnet 2>/dev/null | grep -qF "$mgmt_subnet_cidr"; then
            print_error "CIDR $mgmt_subnet_cidr already used by another subnet. Set CAVE_MGMT_SUBNET_CIDR to a different range."
            exit 1
        fi
        mgmt_subnet_id=$(openstack subnet create --network "$mgmt_net_id" --subnet-range "$mgmt_subnet_cidr" "$mgmt_subnet_name" -f value -c id)
    else
        mgmt_subnet_id=$(openstack subnet show "$mgmt_subnet_name" -f value -c id)
    fi
    
    # 4. Write TOML
    cat << EOF > "$toml_path"
public_network_id = "$public_net_id"
floating_ip_pool = "$public_net_name"
subnet_id = "$public_subnet_id"
key_pair = "$ssh_key_name"
EOF
    print_success "Generated $toml_path"
}

_escape_sed_repl() {
    # Escape &, \ and the | delimiter so the value is treated as a literal replacement.
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

patch_script_if_needed() {
    local original="/cave/backend/make_it_so.sh"

    # Resolve target IP: explicit env var takes priority, then auto-detect from OS_AUTH_URL
    local target_ip="${CAVE_HOST_IP:-}"
    if [ -z "$target_ip" ] && [ -n "${OS_AUTH_URL:-}" ]; then
        local url_host
        url_host=$(echo "$OS_AUTH_URL" | sed 's|https\?://||' | cut -d: -f1 | cut -d/ -f1)
        if [[ "$url_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            target_ip="$url_host"
        fi
    fi

    local target_user="${CAVE_HOST_SSH_USER:-vpnsetup}"
    local target_public_ip="${CAVE_PUBLIC_IP:-}"

    # Validate: reject characters that have no place in an IP/hostname or Unix username.
    if [ -n "$target_ip" ] && [[ ! "$target_ip" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "CAVE_HOST_IP contains invalid characters: $target_ip"
        exit 1
    fi
    if [[ ! "$target_user" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "CAVE_HOST_SSH_USER contains invalid characters: $target_user"
        exit 1
    fi
    if [ -n "$target_public_ip" ] && [[ ! "$target_public_ip" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "CAVE_PUBLIC_IP contains invalid characters: $target_public_ip"
        exit 1
    fi

    local needs_ip_patch=false
    local needs_user_patch=false
    local needs_public_ip_patch=false
    [ -n "$target_ip" ] && [ "$target_ip" != "10.80.0.100" ] && needs_ip_patch=true
    [ "$target_user" != "vpnsetup" ] && needs_user_patch=true
    [ -n "$target_public_ip" ] && [ "$target_public_ip" != "195.37.231.202" ] && needs_public_ip_patch=true

    if [ "$needs_ip_patch" = false ] && [ "$needs_user_patch" = false ] && [ "$needs_public_ip_patch" = false ]; then
        echo "$original"
        return
    fi

    # Temp copy must live in /cave/backend/ so realpath "$0" inside the script
    # resolves SCRIPT_DIR correctly and relative paths like WG_SERVICE_DIR still work
    local patched
    patched=$(mktemp /cave/backend/.make_it_so_XXXXXX.sh)
    cp "$original" "$patched"
    chmod +x "$patched"

    if [ "$needs_ip_patch" = true ]; then
        sed -i "s|10\.80\.0\.100|$(_escape_sed_repl "$target_ip")|g" "$patched"
        print_info "DevStack host IP patched: 10.80.0.100 → $target_ip"
    fi
    if [ "$needs_user_patch" = true ]; then
        sed -i "s|declare DEVSTACK_SSH_USER=\"vpnsetup\"|declare DEVSTACK_SSH_USER=\"$(_escape_sed_repl "$target_user")\"|" "$patched"
        print_info "DevStack SSH user patched: vpnsetup → $target_user"
    fi
    if [ "$needs_public_ip_patch" = true ]; then
        sed -i "s|195\.37\.231\.202|$(_escape_sed_repl "$target_public_ip")|g" "$patched"
        print_info "DevStack public IP patched: 195.37.231.202 → $target_public_ip"
    fi

    echo "$patched"
}

print_connection_info() {
    local lab_prefix="$1"
    local use_wg="$2"

    local vpn_type
    vpn_type=$([ "$use_wg" = true ] && echo "wg" || echo "openvpn")
    local backend_out="/cave/backend/out/$lab_prefix"
    local vpn_out="$backend_out/$vpn_type"
    local tofu_json="$backend_out/tofu.json"

    [ ! -f "$tofu_json" ] && { print_info "No tofu.json found, skipping connection info"; return; }

    local gateway
    gateway=$(jq -r 'to_entries[]
        | select(.key | test("^vpn_instance_info"))
        | select(.value.value.floating_ip != null)
        | .value.value.floating_ip' "$tofu_json" | head -1)

    local jump_host="${CAVE_OPENSTACK_HOST:-<JUMP_HOST>}"
    local jump_port="${CAVE_OPENSTACK_PORT:-22}"

    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${BLUE}║                    Connection Info                         ║${NC}" >&2
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n" >&2

    echo -e "${GREEN}► VPN Configs${NC}" >&2
    echo "  Teams:   $vpn_out/teams/" >&2
    echo "  Admins:  $vpn_out/admins/" >&2
    if [ "$vpn_type" = "openvpn" ]; then
        local ovpn_file
        ovpn_file=$(find "$vpn_out/admins" -name "*.ovpn" 2>/dev/null | head -1)
        if [ -n "$ovpn_file" ]; then
            local vpn_endpoint
            vpn_endpoint=$(grep -E "^\s*remote " "$ovpn_file" | grep -v "remote-" | awk '{print $2":"$3}')
            echo "  VPN Endpoint: $vpn_endpoint" >&2
        fi
    fi
    echo "" >&2

    echo -e "${GREEN}► Kali Guacamole Access${NC}" >&2
    echo "  Credentials: kali / kali" >&2
    echo "  VPN Server:  $gateway" >&2
    echo "" >&2

    local local_port=8443
    local inner_port=18443
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        echo -e "  ${YELLOW}https://localhost:${local_port}${NC}  →  ${ip}:443" >&2
        echo "  ssh -p $jump_port -L ${local_port}:localhost:${inner_port} ${jump_host} \\" >&2
        echo "    \"ssh -N -L ${inner_port}:${ip}:443 ubuntu@${gateway}\"" >&2
        echo "" >&2
        local_port=$((local_port + 1))
        inner_port=$((inner_port + 1))
    done < <(jq -r 'to_entries[]
        | select(.key | test("kali.*output_ansible"))
        | .value.value.ipv4' "$tofu_json" 2>/dev/null | sort)

    if [ -z "${CAVE_OPENSTACK_HOST:-}" ]; then
        echo -e "  ${YELLOW}Tip: Set CAVE_OPENSTACK_HOST and CAVE_OPENSTACK_PORT in .env${NC}" >&2
    fi
}

show_usage() {
    cat << EOF >&2
${BLUE}Usage:${NC}
  $0 [OPTIONS]
  $0 <config-name> [OPTIONS]

${BLUE}Arguments:${NC}
  config-name             Config file name (without .json5), e.g., 'day1'
                          If not provided, you'll be prompted to choose

${BLUE}Options:${NC}
  --wg                    Use WireGuard for VPN (default: OpenVPN)
  --lab-prefix PREFIX     Custom lab prefix (default: from .env or config name)
  --users FILE            User configuration file (default: users_<config>.json)
  --no-public             Disable public VPN IP (default: enabled)
                          Without --public, VPN is only reachable internally
  --public-vpn-port PORT  UDP port for the public VPN endpoint (default: 51800)
                          Only relevant when --public is active
  --dry-run               Show what would be executed without running
  --help                  Show this help message

${BLUE}Examples:${NC}
  # Interactive mode - choose config
  $0

  # Deploy specific config
  $0 day1

  # Deploy with WireGuard
  $0 day1 --wg

  # Deploy with custom prefix
  $0 day1 --lab-prefix mylab --wg

${BLUE}Available configs:${NC}
EOF
    
    # List available configs
    if [ -d "/cave/backend/configs" ]; then
        find /cave/backend/configs -name "*.json5" -not -name ".*" | sed 's|/cave/backend/configs/||; s|\.json5||' | sort | sed "s|^|  - |" >&2
    else
        echo "  (configs directory not found)" >&2
    fi
}

main() {
    print_header
    
    # Parse arguments
    local config_name=""
    local use_wg=false
    local use_public=true
    local public_vpn_port="${CAVE_PUBLIC_VPN_PORT:-51800}"
    local lab_prefix=""
    local users_file=""
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --wg)
                use_wg=true
                shift
                ;;
            --lab-prefix)
                lab_prefix="$2"
                shift 2
                ;;
            --users)
                users_file="$2"
                shift 2
                ;;
            --no-public)
                use_public=false
                shift
                ;;
            --public-vpn-port)
                public_vpn_port="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            --*)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -z "$config_name" ]; then
                    config_name="$1"
                else
                    print_error "Too many arguments"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate credentials and SSH key
    validate_credentials
    local ssh_key_path=$(validate_ssh_key)
    
    # Setup OpenStack TOML and Network
    setup_openstack_toml
    
    # Get config name (interactive if not provided)
    if [ -z "$config_name" ]; then
        print_info "Available configurations:"
        local configs=($(find /cave/backend/configs -name "*.json5" -not -name ".*" | sed 's|/cave/backend/configs/||; s|\.json5||' | sort))
        
        if [ ${#configs[@]} -eq 0 ]; then
            print_error "No configuration files found in /cave/backend/configs"
            exit 1
        fi
        
        # Show menu
        for i in "${!configs[@]}"; do
            echo "  $((i+1))) ${configs[$i]}"
        done
        
        echo -n "Select configuration (1-${#configs[@]}): "
        read -r choice
        
        # Validate choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#configs[@]} ]; then
            print_error "Invalid choice"
            exit 1
        fi
        
        config_name="${configs[$((choice-1))]}"
    fi
    
    # Validate config file — try direct path first (works for both bare names and sub-paths),
    # fall back to recursive name search so bare names without subdir still resolve.
    local config_file_orig
    if [ -f "/cave/backend/configs/${config_name}.json5" ]; then
        config_file_orig="/cave/backend/configs/${config_name}.json5"
    else
        config_file_orig=$(find /cave/backend/configs -name "$(basename "${config_name}").json5" -not -name ".*" | head -1)
    fi
    if [ -z "$config_file_orig" ]; then
        print_error "File not found: ${config_name}.json5 (searched in /cave/backend/configs)"
        exit 1
    fi
    print_success "Config file found: $config_name.json5"

    local config_basename
    config_basename=$(basename "$config_name")

    # Copy config to a writable location to allow patching (configs dir might be problematic)
    local config_work_dir="/tmp/cave_configs"
    mkdir -p "$config_work_dir"
    local config_file="$config_work_dir/${config_basename}.json5"
    cp "$config_file_orig" "$config_file"
    print_info "Config copied to writable location: $config_file"
    
    # Determine users file
    if [ -z "$users_file" ]; then
        users_file="/cave/backend/configs/users_${config_basename}.json"
        if [ -f "$users_file" ]; then
            print_success "Using users file: users_${config_basename}.json"
        else
            print_info "No users file found for $config_basename (optional)"
            users_file=""
        fi
    else
        if ! validate_file "$users_file"; then
            exit 1
        fi
        print_success "Using custom users file: $(basename $users_file)"
    fi
    
    # Determine lab prefix
    if [ -z "$lab_prefix" ]; then
        lab_prefix="${LAB_PREFIX:-$config_basename}"
    fi
    # Interactive summary + edit loop
    while true; do
        echo ""
        print_info "Deployment Summary:"
        echo "  Config:        $config_name"
        echo "  SSH Key:       $SSH_KEY_NAME"
        if [ -n "$users_file" ]; then
            echo "  Users File:    $(basename $users_file)"
        fi
        echo "  Lab Prefix:    $lab_prefix"
        echo "  VPN:           $([ "$use_wg" = true ] && echo "WireGuard" || echo "OpenVPN")"
        if [ "$use_public" = true ]; then
            echo "  Public VPN:    enabled  →  ${CAVE_PUBLIC_IP:-<CAVE_PUBLIC_IP not set>}:$public_vpn_port"
        else
            echo "  Public VPN:    disabled (internal access only)"
        fi
        echo ""
        if [ "$use_public" = true ]; then
            echo "  [y/Enter] Deploy    [v] Change VPN    [s] Toggle public VPN    [o] Change VPN port    [p] Change prefix    [n] Cancel"
        else
            echo "  [y/Enter] Deploy    [v] Change VPN    [s] Toggle public VPN    [p] Change prefix    [n] Cancel"
        fi
        echo ""
        echo -n "Choice: "
        read -r choice

        case "$choice" in
            y|Y|"")
                break
                ;;
            v|V)
                if [ "$use_wg" = true ]; then
                    use_wg=false
                    print_info "Switched to OpenVPN"
                else
                    use_wg=true
                    print_info "Switched to WireGuard"
                fi
                ;;
            s|S)
                if [ "$use_public" = true ]; then
                    use_public=false
                    print_info "Public VPN disabled (internal access only)"
                else
                    use_public=true
                    print_info "Public VPN enabled (${CAVE_PUBLIC_IP:-<set CAVE_PUBLIC_IP>}:$public_vpn_port)"
                fi
                ;;
            o|O)
                if [ "$use_public" = true ]; then
                    echo -n "New public VPN port [$public_vpn_port]: "
                    read -r new_port
                    if [ -n "$new_port" ]; then
                        public_vpn_port="$new_port"
                    fi
                else
                    print_error "Public VPN is disabled — enable it first with [s]"
                fi
                ;;
            p|P)
                echo -n "New lab prefix [$lab_prefix]: "
                read -r new_prefix
                if [ -n "$new_prefix" ]; then
                    lab_prefix="$new_prefix"
                fi
                ;;
            n|N)
                print_info "Deployment cancelled"
                exit 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac
    done

    # Validate public VPN settings
    if [ "$use_public" = true ]; then
        if [ -z "${CAVE_PUBLIC_IP:-}" ]; then
            print_error "CAVE_PUBLIC_IP is not set but public VPN is enabled!"
            print_error "Set CAVE_PUBLIC_IP to the external/public IP of your OpenStack host in .env"
            exit 1
        fi
        if ! [[ "$public_vpn_port" =~ ^[0-9]+$ ]] || [ "$public_vpn_port" -lt 1 ] || [ "$public_vpn_port" -gt 65535 ]; then
            print_error "Invalid --public-vpn-port: $public_vpn_port (must be 1–65535)"
            exit 1
        fi
    fi

    # Build command
    local make_it_so_script
    make_it_so_script=$(patch_script_if_needed)
    [ "$make_it_so_script" != "/cave/backend/make_it_so.sh" ] && trap "rm -f '$make_it_so_script'" EXIT

    local cmd=("$make_it_so_script" "$config_file" "$ssh_key_path")

    if [ -n "$users_file" ]; then
        cmd+=("$users_file")
    else
        # deploy_openvpn.py/deploy_wg.py require a config file; generate a minimal stub
        local stub_users_file
        stub_users_file=$(mktemp /tmp/cave_users_XXXXXX.json)
        echo '{"users": [], "teams": [], "access": []}' > "$stub_users_file"
        trap "rm -f '$make_it_so_script' '$stub_users_file'" EXIT
        cmd+=("$stub_users_file")
        print_info "No users file provided — using empty stub (no attendee VPN configs)"
    fi

    cmd+=(--lab-prefix "$lab_prefix")

    if [ "$use_wg" = true ]; then
        cmd+=(--wg)
    fi

    if [ "$use_public" = true ]; then
        cmd+=(--public --public-vpn-port "$public_vpn_port")
    fi

    if [ "$dry_run" = true ]; then
        print_info "Dry-run mode - would execute:"
        printf '  %q' "${cmd[@]}"
        echo ""
        exit 0
    fi

    # Execute
    echo ""
    print_info "Starting deployment..."
    echo ""

    # Change to backend directory so relative paths in make_it_so.sh (like configs/openstack.toml) work
    cd /cave/backend
 
    "${cmd[@]}"
    print_connection_info "$lab_prefix" "$use_wg"
}

# Run main function
main "$@"
