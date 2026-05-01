

#!/bin/bash

# pre-build-images.sh - Pre-build setup for CAVE Infrastructure
#
# Prepares the OpenStack environment before running packer builds:
#   1. Sets up required security groups and rules
#   2. Downloads, extracts and uploads base cloud images

set -e

# ─────────────────────────────────────────────
#  COLORS & OUTPUT HELPERS
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        CAVE Infrastructure - Pre-Build Setup               ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

print_error()   { echo -e "${RED}✗ ERROR: $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_info()    { echo -e "${YELLOW}ℹ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ WARNING: $1${NC}"; }


# ═════════════════════════════════════════════
#  MAIN FLOW
# ═════════════════════════════════════════════

main() {
    print_header
    check_openstack_auth
    setup_security_group_rules
    download_images_to_openstack
    print_success "Pre-build setup completed successfully."
}


# ═════════════════════════════════════════════
#  FUNCTIONS
# ═════════════════════════════════════════════

# ── OpenStack Auth ───────────────────────────

check_openstack_auth() {
    print_info "Checking OpenStack authentication..."

    if [ -f /.openrc ]; then
        print_info "Sourcing OpenStack credentials from /.openrc..."
        set -a
        source /.openrc
        set +a
    fi

    if [ -z "$OS_AUTH_URL" ] || [ -z "$OS_PASSWORD" ]; then
        print_error "OpenStack credentials are not set."
        print_info "Please ensure your .openrc or .env file is properly mapped and sourced."
        exit 1
    fi

    if ! openstack image list --limit 1 &>/dev/null; then
        print_error "OpenStack CLI cannot establish a connection. Check your credentials."
        exit 1
    fi

    print_success "OpenStack authentication successful"
}

# ── Security Groups ──────────────────────────

setup_security_group_rules() {
    print_info "Ensuring required security groups exist..."

    # Create 'open' security group if it doesn't exist
    if ! openstack security group show open >/dev/null 2>&1; then
        print_info "Creating 'open' security group..."
        openstack security group create open >/dev/null 2>&1 \
            || print_error "Failed to create 'open' security group"
    else
        print_success "Security group 'open' already exists"
    fi

    # Ensure 'open' security group allows all traffic
    print_info "Configuring 'open' security group rules..."
    openstack security group rule create --protocol icmp  --ingress open >/dev/null 2>&1 || true
    openstack security group rule create --protocol tcp   --dst-port 1:65535 --ingress open >/dev/null 2>&1 || true
    openstack security group rule create --protocol udp   --dst-port 1:65535 --ingress open >/dev/null 2>&1 || true

    # Ensure 'default' security group allows SSH and ICMP
    print_info "Ensuring 'default' security group allows SSH and ICMP..."
    openstack security group rule create --protocol icmp --ingress default >/dev/null 2>&1 || true
    openstack security group rule create --protocol tcp  --dst-port 22:22 --ingress default >/dev/null 2>&1 || true

    print_success "Security group rules configured"
}

# ── Image Download & Upload ──────────────────

download_images_to_openstack() {
    local KALI_URL="https://kali.download/cloud-images/kali-2026.1/kali-linux-2026.1-cloud-genericcloud-amd64.tar.xz"
    local ARCHIVE_NAME
    ARCHIVE_NAME=$(basename "$KALI_URL")
    local WORK_DIR
    WORK_DIR=$(mktemp -d /tmp/cave-kali-XXXXXX)

    print_info "Working directory: $WORK_DIR"

    # ── Download ─────────────────────────────
    print_info "Downloading $ARCHIVE_NAME ..."
    if ! wget --progress=bar:force:noscroll -O "$WORK_DIR/$ARCHIVE_NAME" "$KALI_URL"; then
        print_error "Download failed: $KALI_URL"
        rm -rf "$WORK_DIR"
        exit 1
    fi
    print_success "Download complete: $ARCHIVE_NAME"

    # ── Extract ──────────────────────────────
    print_info "Extracting $ARCHIVE_NAME ..."
    tar -xf "$WORK_DIR/$ARCHIVE_NAME" -C "$WORK_DIR"
    print_success "Extraction complete"

    # Find the disk image (prefer qcow2, fall back to raw .img)
    local IMAGE_FILE
    IMAGE_FILE=$(find "$WORK_DIR" -type f \( -name "*.qcow2" -o -name "*.img" \) | head -n 1)

    if [ -z "$IMAGE_FILE" ]; then
        print_error "No disk image (.qcow2 or .img) found after extraction."
        rm -rf "$WORK_DIR"
        exit 1
    fi

    print_success "Found image file: $(basename "$IMAGE_FILE")"

    # ── Upload ───────────────────────────────
    upload_image "$IMAGE_FILE"

    # ── Cleanup ──────────────────────────────
    print_info "Cleaning up temporary files..."
    rm -rf "$WORK_DIR"
    print_success "Temporary files removed"
}

upload_image() {
    local IMAGE_PATH="$1"
    local FILENAME
    FILENAME=$(basename "$IMAGE_PATH")
    local EXTENSION="${FILENAME##*.}"

    # Determine OpenStack disk format
    local DISK_FORMAT
    case "$EXTENSION" in
        qcow2) DISK_FORMAT="qcow2" ;;
        img)   DISK_FORMAT="raw"   ;;
        *)     DISK_FORMAT="raw"   ;;
    esac

    # Derive image name from filename (strip extension)
    local BASENAME="${FILENAME%.*}"
    # For double extensions like .tar.xz already stripped; handle .qcow2 / .img
    local IMAGE_NAME="$BASENAME"

    print_info "Image name   : $IMAGE_NAME"
    print_info "Disk format  : $DISK_FORMAT"
    print_info "Image size   : $(du -h "$IMAGE_PATH" | cut -f1)"

    # Check if image already exists
    print_info "Checking if image '$IMAGE_NAME' already exists in OpenStack..."
    if openstack image show "$IMAGE_NAME" &>/dev/null; then
        print_warning "An image named '$IMAGE_NAME' already exists!"
        read -p "Overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping upload of $IMAGE_PATH"
            return
        fi
        print_info "Deleting existing image..."
        openstack image delete "$IMAGE_NAME"
        print_success "Existing image deleted"
    fi

    # Upload
    print_info "Uploading image to OpenStack (this may take a while)..."
    openstack image create \
        --file            "$IMAGE_PATH" \
        --disk-format     "$DISK_FORMAT" \
        --container-format bare \
        --property os_type=linux \
        --property hw_disk_bus=virtio \
        --property hw_vif_model=virtio \
        "$IMAGE_NAME"

    print_success "Image '$IMAGE_NAME' successfully uploaded to OpenStack!"
}


# ─────────────────────────────────────────────
main "$@"