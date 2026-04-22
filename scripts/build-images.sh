#!/bin/bash
# Script to clone an images repository and run packer builds interactively

set -e

# ─────────────────────────────────────────────
#  COLORS & OUTPUT HELPERS
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header()  {
    if [ "$QUIET_MODE" -eq 0 ]; then
        echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}" >&2
        echo -e "${BLUE}║            CAVE Infrastructure - Image Builder             ║${NC}" >&2
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n" >&2
    fi
}
print_error()   { echo -e "${RED}✗ ERROR: $1${NC}" >&2; }
print_success() { if [ "$QUIET_MODE" -eq 0 ]; then echo -e "${GREEN}✓ $1${NC}" >&2; fi; }
print_info()    { if [ "$QUIET_MODE" -eq 0 ]; then echo -e "${YELLOW}ℹ $1${NC}" >&2; fi; }


# ─────────────────────────────────────────────
#  GLOBAL STATE (for cleanup trap)
# ─────────────────────────────────────────────

QUIET_MODE=0
TEMP_NETWORK_ID=""
TEMP_ROUTER_ID=""
TEMP_SUBNET_ID=""


# ═════════════════════════════════════════════
#  MAIN FLOW
# ═════════════════════════════════════════════

main() {
    # --- Parse flags ---
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -q|--quiet)
                QUIET_MODE=1
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    # --- Argument validation ---
    REPO_URL="$1"
    COMMIT_HASH="$2"
    LOCAL_MODE=0

    if [ $# -eq 0 ]; then
        # No arguments: use local repository
        print_info "No arguments provided: using standard cave-images submodule at /cave/backend/submodule/cave-images"
        CLONE_DIR="/cave/backend/submodule/cave-images"
        LOCAL_MODE=1
    elif [ $# -eq 1 ]; then
        # One argument: repo URL with default main branch
        print_info "Using repository: $REPO_URL"
        print_info "Using default ref: main"
        COMMIT_HASH="main"
    else
        # Two arguments: both specified
        print_info "Using repository: $REPO_URL"
        print_info "Using ref: $COMMIT_HASH"
    fi

    print_header

    # --- Prerequisites ---
    check_openstack_credentials
    check_packer_installed
    setup_security_group_rules
    setup_ssh_key

    # --- Clone or update repository (unless in local mode) ---
    if [ $LOCAL_MODE -eq 0 ]; then
        # Generate a stable directory name based on repo URL hash
        local repo_hash=$(echo -n "$REPO_URL" | md5sum | cut -c1-8)
        CLONE_DIR="/tmp/cave-images-${repo_hash}"
        clone_or_update_repository "$REPO_URL" "$COMMIT_HASH" "$CLONE_DIR"
    else
        # Verify that the local directory exists
        if [ ! -d "$CLONE_DIR" ]; then
            print_error "Local cave-images directory not found at $CLONE_DIR"
            exit 1
        fi
        print_success "Using local cave-images submodule"
    fi

    # --- Discover images ---
    pushd "$CLONE_DIR" >/dev/null
    mapfile -t IMAGES < <(find . -type f -name "*.pkr.hcl" \
        | sed -r 's|/[^/]+$||' | sort -u | sed 's|^\./||')

    if [ ${#IMAGES[@]} -eq 0 ]; then
        print_error "No packer templates (*.pkr.hcl) found in the repository."
        popd >/dev/null
        exit 1
    fi

    # --- Interactive build loop ---
    while true; do
        # --- User selection ---
        echo ""
        print_info "Discovered the following images:"
        for i in "${!IMAGES[@]}"; do
            echo -e "  $((i+1))) ${YELLOW}${IMAGES[$i]}${NC}"
        done
        echo -e "  A) All images"
        echo -e "  Q) Quit"
        echo ""
        read -p "Which image do you want to build? [1-${#IMAGES[@]}, A, Q] or space-separated numbers: " CHOICE

        # --- Dispatch ---
        case "$CHOICE" in
            A|a)
                for img in "${IMAGES[@]}"; do
                    build_image "$img"
                done
                ;;
            Q|q)
                print_info "Exiting without building."
                break
                ;;
            *)
                # Check if it's a valid input (numbers and spaces)
                if [[ "$CHOICE" =~ ^[0-9\ ]+$ ]]; then
                    # Parse space-separated numbers
                    local valid=true
                    for num in $CHOICE; do
                        if [ "$num" -lt 1 ] || [ "$num" -gt "${#IMAGES[@]}" ]; then
                            print_error "Invalid selection: $num"
                            valid=false
                            break
                        fi
                    done
                    
                    if [ "$valid" = true ]; then
                        # Build selected images
                        for num in $CHOICE; do
                            build_image "${IMAGES[$((num-1))]}"
                        done
                    fi
                else
                    print_error "Invalid choice. Please enter numbers (1-${#IMAGES[@]}), A, Q, or space-separated numbers."
                fi
                ;;
        esac
    done

    # --- Cleanup ---
    popd >/dev/null
    if [ $LOCAL_MODE -eq 0 ]; then
        print_success "Done. Repository cached at $CLONE_DIR for future runs."
    else
        print_success "Done."
    fi
}


# ═════════════════════════════════════════════
#  FUNCTIONS
# ═════════════════════════════════════════════

# ── Credentials & Prerequisites ──────────────

check_openstack_credentials() {
    if [ -f /.openrc ]; then
        print_info "Sourcing OpenStack credentials from /.openrc..."
        set -a
        source /.openrc
        set +a
    fi

    if [ -z "$OS_AUTH_URL" ] || [ -z "$OS_PASSWORD" ]; then
        print_error "OpenStack credentials are not set."
        print_info "Please ensure that your .openrc or .env file is properly mapped and sourced."
        exit 1
    fi

    # Unset conflicting domain variables to prevent packer crashes
    export OS_DOMAIN_NAME="${OS_DOMAIN_NAME:-${OS_USER_DOMAIN_NAME:-Default}}"
    unset OS_DOMAIN_ID
    unset OS_USER_DOMAIN_ID
    unset OS_USER_DOMAIN_NAME
}

check_packer_installed() {
    if [ ! -x "$(command -v packer)" ]; then
        print_error "Packer is not installed or not in PATH."
        exit 1
    fi
}

setup_security_group_rules() {
    print_info "Ensuring 'default' security group allows SSH and ICMP..."
    openstack security group rule create --protocol icmp --ingress default >/dev/null 2>&1 || true
    openstack security group rule create --protocol tcp --dst-port 22:22 --ingress default >/dev/null 2>&1 || true
}

setup_ssh_key() {
    if [ -n "$SSH_KEY_NAME" ]; then
        SSH_KEY_PATH="/home/cave/.ssh/$SSH_KEY_NAME"
        if [ -f "$SSH_KEY_PATH" ]; then
            print_success "SSH key found: $SSH_KEY_NAME"
            export PACKER_SSH_KEY="$SSH_KEY_PATH"
        else
            print_info "SSH key $SSH_KEY_NAME defined in .env but not found at $SSH_KEY_PATH (some builds might not need it)."
        fi
    fi
}

# ── Repository ───────────────────────────────

clone_or_update_repository() {
    local repo_url=$1
    local commit_hash=$2
    local clone_dir=$3

    if [ -d "$clone_dir/.git" ]; then
        # Repository already exists, update it
        print_info "Repository already exists at $clone_dir, updating..."
        pushd "$clone_dir" >/dev/null
        git fetch origin
        git checkout "$commit_hash"
        popd >/dev/null
        print_success "Repository updated successfully."
    else
        # Repository doesn't exist, clone it
        print_info "Cloning $repo_url (Ref: $commit_hash) into $clone_dir..."
        mkdir -p "$clone_dir"
        git clone "$repo_url" "$clone_dir"
        pushd "$clone_dir" >/dev/null
        git checkout "$commit_hash"
        popd >/dev/null
        print_success "Repository cloned successfully."
    fi
}

clone_repository() {
    local repo_url=$1
    local commit_hash=$2
    local clone_dir=$3

    print_info "Cloning $repo_url (Ref: $commit_hash) into $clone_dir..."
    git clone "$repo_url" "$clone_dir"
    pushd "$clone_dir" >/dev/null
    git checkout "$commit_hash"
    popd >/dev/null
    print_success "Repository cloned successfully."
}

# ── Network ──────────────────────────────────

create_temp_network() {
    print_info "Creating temporary internal network for build..."

    TEMP_NETWORK_ID=$(openstack network create --format value -c id \
        "temp-packer-build-$(date +%s)") \
        || { print_error "Failed to create temporary network"; return 1; }
    print_success "Created temporary network: $TEMP_NETWORK_ID"

    local subnet_name="temp-packer-subnet-$(date +%s)"
    TEMP_SUBNET_ID=$(openstack subnet create \
        --network "$TEMP_NETWORK_ID" \
        --subnet-range "192.168.255.0/24" \
        "$subnet_name" --format value -c id) \
        || { print_error "Failed to create subnet"; return 1; }
    print_success "Created temporary subnet: $TEMP_SUBNET_ID"

    local external_net
    external_net=$(openstack network list --external -f value -c ID | head -n 1)

    if [ -n "$external_net" ]; then
        print_info "External network found — connecting via router..."
        local router_name="temp-packer-router-$(date +%s)"
        TEMP_ROUTER_ID=$(openstack router create --format value -c id "$router_name") \
            || { print_error "Failed to create router"; return 1; }
        print_success "Created temporary router: $TEMP_ROUTER_ID"

        openstack router set --external-gateway "$external_net" "$TEMP_ROUTER_ID" >/dev/null 2>&1 \
            || { print_error "Failed to set external gateway"; return 1; }
        openstack router add subnet "$TEMP_ROUTER_ID" "$TEMP_SUBNET_ID" >/dev/null 2>&1 \
            || { print_error "Failed to add subnet to router"; return 1; }
        print_success "Router connected to subnet and external network"
    else
        print_info "No external network found. Temporary network is isolated (internal only)."
    fi
}

cleanup_temp_network() {
    if [ -n "$TEMP_ROUTER_ID" ] && [ -n "$TEMP_SUBNET_ID" ]; then
        print_info "Removing subnet from temporary router..."
        openstack router remove subnet "$TEMP_ROUTER_ID" "$TEMP_SUBNET_ID" >/dev/null 2>&1 \
            || print_info "Failed to remove subnet from router"
    fi

    if [ -n "$TEMP_ROUTER_ID" ]; then
        print_info "Cleaning up temporary router: $TEMP_ROUTER_ID"
        openstack router unset --external-gateway "$TEMP_ROUTER_ID" >/dev/null 2>&1 || true
        openstack router delete "$TEMP_ROUTER_ID" >/dev/null 2>&1 \
            || print_info "Failed to delete temporary router"
        TEMP_ROUTER_ID=""
    fi

    if [ -n "$TEMP_SUBNET_ID" ]; then
        print_info "Cleaning up temporary subnet: $TEMP_SUBNET_ID"
        openstack subnet delete "$TEMP_SUBNET_ID" >/dev/null 2>&1 \
            || print_info "Failed to delete temporary subnet"
        TEMP_SUBNET_ID=""
    fi

    if [ -n "$TEMP_NETWORK_ID" ]; then
        print_info "Cleaning up temporary network: $TEMP_NETWORK_ID"
        openstack network delete "$TEMP_NETWORK_ID" >/dev/null 2>&1 \
            || print_info "Failed to delete temporary network"
        TEMP_NETWORK_ID=""
    fi
}

# ── Packer Template Patching ─────────────────

patch_tls() {
    if [[ "${OS_INSECURE,,}" == "true" || "$OS_INSECURE" == "1" ]]; then
        print_info "OS_INSECURE enabled — patching template to skip TLS verification..."
        find . -maxdepth 1 -name "*.pkr.hcl" | while read -r file; do
            if ! grep -q 'insecure' "$file"; then
                sed -i '/source "openstack"/a \  insecure = true' "$file"
            fi
        done
    fi
}

patch_config_drive() {
    print_info "Enforcing config_drive for secure SSH key and user-data injection..."
    find . -maxdepth 1 -name "*.pkr.hcl" | while read -r file; do
        if ! grep -q 'config_drive' "$file"; then
            sed -i '/source "openstack"/a \  config_drive = true' "$file"
        fi
    done
}

patch_flavor_map() {
    if [ -n "$OS_FLAVOR_MAP" ]; then
        print_info "Applying flavor mappings ($OS_FLAVOR_MAP)..."
        IFS=',' read -ra MAPPINGS <<< "$OS_FLAVOR_MAP"
        for map in "${MAPPINGS[@]}"; do
            local old="${map%%:*}"
            local new="${map##*:}"
            find . -maxdepth 1 -name "*.pkr.hcl" \
                -exec sed -i -E "s/flavor[[:space:]]*=[[:space:]]*\"$old\"/flavor = \"$new\"/g" {} +
        done
    fi
}

patch_network() {
    local build_network_id=$1
    find . -maxdepth 1 -name "*.pkr.hcl" | while read -r file; do
        # Only patch if networks line doesn't already point to the build network
        if ! grep -q "networks.*=.*\[\"$build_network_id\"\]" "$file"; then
            sed -i -E "s/networks[[:space:]]*=[[:space:]]*\[\"[^\"]*\"\]/networks = [\"$build_network_id\"]/" "$file"
        fi
    done
}

patch_floating_ip() {
    if [ -n "$OS_BUILD_FLOATING_IP_NETWORK_ID" ]; then
        if [[ "${OS_BUILD_FLOATING_IP_NETWORK_ID,,}" == "none" ]]; then
            print_info "Floating IPs disabled — using direct internal SSH..."
            find . -maxdepth 1 -name "*.pkr.hcl" | while read -r file; do
                sed -i -E '/floating_ip_network[[:space:]]*=/d' "$file"
                if ! grep -q 'use_floating_ip' "$file"; then
                    sed -i '/source "openstack"/a \  use_floating_ip = false' "$file"
                fi
                if ! grep -q 'ssh_interface' "$file"; then
                    sed -i '/source "openstack"/a \  ssh_interface = "private"' "$file"
                fi
            done
        else
            print_info "Using specified floating IP network: $OS_BUILD_FLOATING_IP_NETWORK_ID"
            find . -maxdepth 1 -name "*.pkr.hcl" | while read -r file; do
                sed -i -E '/floating_ip_network[[:space:]]*=/d' "$file"
                if ! grep -q 'floating_ip_network' "$file"; then
                    sed -i '/source "openstack"/a \  floating_ip_network = "'"$OS_BUILD_FLOATING_IP_NETWORK_ID"'"' "$file"
                fi
            done
        fi
    else
        local auto_external_net
        auto_external_net=$(openstack network list --external -f value -c ID | head -n 1)
        if [ -n "$auto_external_net" ]; then
            print_info "Auto-discovered external network for floating IPs: $auto_external_net"
            find . -maxdepth 1 -name "*.pkr.hcl" | while read -r file; do
                sed -i -E '/floating_ip_network[[:space:]]*=/d' "$file"
                if ! grep -q 'floating_ip_network' "$file"; then
                    sed -i '/source "openstack"/a \  floating_ip_network = "'"$auto_external_net"'"' "$file"
                fi
            done
        else
            print_info "No external network found — disabling floating IPs, using internal SSH..."
            find . -maxdepth 1 -name "*.pkr.hcl" | while read -r file; do
                sed -i -E '/floating_ip_network[[:space:]]*=/d' "$file"
                if ! grep -q 'use_floating_ip' "$file"; then
                    sed -i '/source "openstack"/a \  use_floating_ip = false' "$file"
                fi
                if ! grep -q 'ssh_interface' "$file"; then
                    sed -i '/source "openstack"/a \  ssh_interface = "private"' "$file"
                fi
            done
        fi
    fi
}

# ── Build ─────────────────────────────────────

build_image() {
    local img_dir=$1

    # Reset temp resource tracking for this build
    TEMP_NETWORK_ID=""
    TEMP_ROUTER_ID=""
    TEMP_SUBNET_ID=""

    print_info "=================================================="
    print_info "Building image in $img_dir..."
    print_info "=================================================="
    pushd "$img_dir" >/dev/null

    # Apply template patches
    patch_tls
    patch_config_drive
    patch_flavor_map

    # Resolve build network
    local build_network_id=""
    if [ -n "$OS_BUILD_NETWORK_ID" ]; then
        print_info "Using specified build network: $OS_BUILD_NETWORK_ID"
        build_network_id="$OS_BUILD_NETWORK_ID"
    else
        create_temp_network || { popd >/dev/null; return 1; }
        build_network_id="$TEMP_NETWORK_ID"
    fi
    patch_network "$build_network_id"

    # Resolve floating IP
    patch_floating_ip

    # Run Packer
    if [ "$QUIET_MODE" -eq 0 ]; then
        packer init . \
            || { print_error "Failed to initialize packer plugins in $img_dir"; popd >/dev/null; return 1; }

        packer plugins install github.com/hashicorp/openstack \
            || print_info "Openstack plugin might already be installed or unavailable to install directly."

        packer build .
    else
        packer init . >/dev/null 2>&1 \
            || { print_error "Failed to initialize packer plugins in $img_dir"; popd >/dev/null; return 1; }

        packer plugins install github.com/hashicorp/openstack >/dev/null 2>&1 \
            || true

        packer build -quiet . >/dev/null 2>&1
    fi
    local result=$?

    popd >/dev/null

    if [ $result -eq 0 ]; then
        print_success "Successfully built $img_dir"
    else
        print_error "Failed to build $img_dir"
    fi
}


# ═════════════════════════════════════════════
#  TRAPS & ENTRY POINT
# ═════════════════════════════════════════════

trap cleanup_temp_network EXIT INT TERM

main "$@"