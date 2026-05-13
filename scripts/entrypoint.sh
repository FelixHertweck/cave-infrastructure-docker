#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}" >&2
}

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}" >&2
}

# Fix permissions if running as root
if [ "$(id -u)" = '0' ]; then
    print_info "Running as root. Fixing permissions for /cave/backend/out and /cave/backend/configs..."
    
    # Ensure these directories exist (they should be mounted or copied)
    mkdir -p /cave/backend/out /cave/backend/configs
    
    # Recursively change ownership to the 'cave' user (UID 1000)
    chown -R cave:cave /cave/backend/out /cave/backend/configs
    
    print_success "Permissions fixed."
fi

# Source OpenStack credentials if available
# Use 'set -a' to export all variables in the sourced file
if [ -f /.openrc ]; then
    print_info "Sourcing OpenStack credentials from /.openrc..."
    set -a
    source /.openrc
    set +a
fi

# Load environment variables from .env (if available)
if [ -f .env ]; then
    print_info "Loading environment variables from .env..."
    set -a
    source .env
    set +a
fi

# Validate that OS_PASSWORD is set (required for OpenStack CLI)
if [ -z "$OS_PASSWORD" ]; then
    print_error "OS_PASSWORD is not set!"
    print_error "Make sure to either:"
    print_error "  1. Define OS_PASSWORD in .env file, OR"
    print_error "  2. Include OS_PASSWORD in .openrc file"
    exit 1
fi

print_success "OpenStack credentials validated. Ready to proceed."

# Dynamically fetch and trust the OpenStack certificate (if OS_INSECURE=true)
if [ "$OS_INSECURE" = "true" ] && [ -n "$OS_AUTH_URL" ]; then
    export OS_CACERT="/tmp/openstack_cert.pem"
    OS_HOST=$(echo "$OS_AUTH_URL" | awk -F/ '{print $3}')
    print_info "Fetching OpenStack certificate from $OS_HOST..."
    echo | openssl s_client -showcerts -connect "$OS_HOST" 2>/dev/null | openssl x509 -outform PEM > "$OS_CACERT"
    print_success "Certificate saved to $OS_CACERT and OS_CACERT exported"
fi

# Execute the command passed to the container
if [ "$(id -u)" = '0' ]; then
    # Use gosu to drop to the 'cave' user
    exec gosu cave "$@"
else
    # Already running as non-root user
    exec "$@"
fi
