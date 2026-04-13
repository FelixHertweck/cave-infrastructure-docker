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
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         CAVE Infrastructure - Deployment Wrapper            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
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

show_usage() {
    cat << EOF
${BLUE}Usage:${NC}
  $0 [OPTIONS]
  $0 <config-name> [OPTIONS]

${BLUE}Arguments:${NC}
  config-name              Config file name (without .json5), e.g., 'day1'
                          If not provided, you'll be prompted to choose

${BLUE}Options:${NC}
  --wg                    Use WireGuard for VPN (default: OpenVPN)
  --lab-prefix PREFIX     Custom lab prefix (default: from .env or config name)
  --users FILE            User configuration file (default: users_<config>.json)
  --dry-run              Show what would be executed without running
  --help                 Show this help message

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
        find /cave/backend/configs -name "*.json5" -not -name ".*" | sed 's|.*/||; s|\.json5||' | sed "s|^|  - |"
    else
        echo "  (configs directory not found)"
    fi
}

main() {
    print_header
    
    # Parse arguments
    local config_name=""
    local use_wg=false
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
    
    # Get config name (interactive if not provided)
    if [ -z "$config_name" ]; then
        print_info "Available configurations:"
        local configs=($(find /cave/backend/configs -name "*.json5" -not -name ".*" | sed 's|.*/||; s|\.json5||' | sort))
        
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
    
    # Validate config file
    local config_file="/cave/backend/configs/${config_name}.json5"
    if ! validate_file "$config_file"; then
        exit 1
    fi
    print_success "Config file found: $config_name.json5"
    
    # Determine users file
    if [ -z "$users_file" ]; then
        users_file="/cave/backend/configs/users_${config_name}.json"
        if [ -f "$users_file" ]; then
            print_success "Using users file: users_${config_name}.json"
        else
            print_info "No users file found for $config_name (optional)"
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
        lab_prefix="${LAB_PREFIX:-$config_name}"
    fi
    print_info "Lab prefix: $lab_prefix"
    
    # Build command
    local cmd="/cave/backend/make_it_so.sh"
    cmd="$cmd '$config_file'"
    cmd="$cmd '$ssh_key_path'"
    
    if [ -n "$users_file" ]; then
        cmd="$cmd '$users_file'"
    else
        cmd="$cmd ''"
    fi
    
    cmd="$cmd --lab-prefix '$lab_prefix'"
    
    if [ "$use_wg" = true ]; then
        cmd="$cmd --wg"
        print_info "Using WireGuard VPN"
    else
        print_info "Using OpenVPN (default)"
    fi
    
    # Show summary
    echo ""
    print_info "Deployment Summary:"
    echo "  Config:        $config_name"
    echo "  SSH Key:       $SSH_KEY_NAME"
    if [ -n "$users_file" ]; then
        echo "  Users File:    $(basename $users_file)"
    fi
    echo "  Lab Prefix:    $lab_prefix"
    echo "  VPN:           $([ "$use_wg" = true ] && echo "WireGuard" || echo "OpenVPN")"
    echo ""
    
    if [ "$dry_run" = true ]; then
        print_info "Dry-run mode - would execute:"
        echo "  bash -c \"$cmd\""
        exit 0
    fi
    
    # Confirmation
    echo -n "Proceed with deployment? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled"
        exit 0
    fi
    
    # Execute
    echo ""
    print_info "Starting deployment..."
    echo ""
    
    eval "$cmd"
}

# Run main function
main "$@"
