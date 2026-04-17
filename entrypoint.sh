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

# Source OpenStack credentials if available
# Use 'set -a' to export all variables in the sourced file
if [ -f /.openrc ]; then
    print_info "Sourcing OpenStack credentials from /.openrc..."
    set -a
    source /.openrc
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

# Execute the command passed to the container
"$@"
EXIT_CODE=$?

exit $EXIT_CODE
