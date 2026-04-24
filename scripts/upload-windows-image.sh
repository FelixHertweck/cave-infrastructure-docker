#!/bin/bash

# upload-windows-image.sh - Interactive upload of Windows qcow2 images to OpenStack
# 
# Usage: bash upload-windows-image.sh
#
# The script will automatically search for qcow2 images in /cave/windows-images
# and allow you to select which one(s) to upload.

set -e

# Color definitions for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions for output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         CAVE Infrastructure - Windows Image Uploader       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

# ─────────────────────────────────────────────
#  MAIN FLOW
# ─────────────────────────────────────────────

main() {
    print_header

    # Define the directory to search
    WINDOWS_IMAGES_DIR="/cave/windows-images"
    
    # Check if directory exists
    if [ ! -d "$WINDOWS_IMAGES_DIR" ]; then
        print_error "Directory not found: $WINDOWS_IMAGES_DIR"
        print_info "Please ensure the windows-images directory exists."
        exit 1
    fi
    
    # Discover all qcow2 files in the directory
    mapfile -t IMAGES < <(find "$WINDOWS_IMAGES_DIR" -type f -name "*.qcow2" | sort)
    
    # Check if any images were found
    if [ ${#IMAGES[@]} -eq 0 ]; then
        print_error "No qcow2 images found in $WINDOWS_IMAGES_DIR"
        print_info "Please place your Windows qcow2 images in this directory."
        exit 1
    fi
    
    print_success "Found ${#IMAGES[@]} qcow2 image(s) in $WINDOWS_IMAGES_DIR"
    
    # Check OpenStack authentication
    check_openstack_cli
    check_openstack_auth
    
    # Interactive selection loop
    while true; do
        # Display available images
        echo ""
        print_info "Available images:"
        for i in "${!IMAGES[@]}"; do
            local img_size=$(du -h "${IMAGES[$i]}" | cut -f1)
            echo -e "  $((i+1))) ${YELLOW}$(basename "${IMAGES[$i]}")${NC} (${img_size})"
        done
        echo -e "  A) Upload all images"
        echo -e "  Q) Quit"
        echo ""
        
        read -p "Select image(s) to upload [1-${#IMAGES[@]}, A, Q] or space-separated numbers: " CHOICE
        
        # Process selection
        case "$CHOICE" in
            A|a)
                print_info "Uploading all images..."
                for img in "${IMAGES[@]}"; do
                    upload_image "$img"
                done
                ;;
            Q|q)
                print_info "Exiting without upload."
                break
                ;;
            *)
                # Check if it's a valid input (numbers and spaces)
                if [[ "$CHOICE" =~ ^[0-9\ ]+$ ]]; then
                    local valid=true
                    for num in $CHOICE; do
                        if [ "$num" -lt 1 ] || [ "$num" -gt "${#IMAGES[@]}" ]; then
                            print_error "Invalid selection: $num"
                            valid=false
                            break
                        fi
                    done
                    
                    if [ "$valid" = true ]; then
                        # Upload selected images
                        for num in $CHOICE; do
                            upload_image "${IMAGES[$((num-1))]}"
                        done
                    fi
                else
                    print_error "Invalid choice. Please enter numbers (1-${#IMAGES[@]}), A, Q, or space-separated numbers."
                fi
                ;;
        esac
        
        # Ask if user wants to upload more
        if [ "$CHOICE" != "Q" ] && [ "$CHOICE" != "q" ]; then
            echo ""
            read -p "Upload more images? (y/N): " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                print_info "Done."
                break
            fi
        fi
    done
    
    print_success "Windows Image Uploader finished."
}

# ─────────────────────────────────────────────
#  FUNCTIONS
# ─────────────────────────────────────────────

check_openstack_cli() {
    print_info "Checking OpenStack CLI..."
    if ! command -v openstack &> /dev/null; then
        print_error "OpenStack CLI not found. Please install with:"
        echo "  pip install python-openstackclient"
        exit 1
    fi
    print_success "OpenStack CLI found"
}

check_openstack_auth() {
    print_info "Checking OpenStack authentication..."
    if [ -z "$OS_AUTH_URL" ] && [ -z "$OS_CREDENTIAL" ]; then
        print_warning "OpenStack does not appear to be authenticated."
        print_info "Please source your openrc file first:"
        echo "  source /path/to/openrc"
        echo ""
    fi
    
    if ! openstack image list --limit 1 &> /dev/null; then
        print_error "OpenStack CLI cannot establish connection."
        print_error "Please make sure you have sourced a valid openrc file."
        exit 1
    fi
    print_success "OpenStack authentication successful"
}

upload_image() {
    local IMAGE_PATH="$1"
    local IMAGE_NAME=""
    
    echo ""
    print_info "Processing: $(basename "$IMAGE_PATH")"
    
    # Generate image name from filename
    local FILENAME=$(basename "$IMAGE_PATH")
    local BASENAME="${FILENAME%.qcow2}"
    
    # Try to detect variant type and generate appropriate name
    if [[ "$BASENAME" == *"server"* ]]; then
        if [[ "$BASENAME" == *"2025"* ]] || [[ "$BASENAME" == *"2k25"* ]]; then
            IMAGE_NAME="server2025"
        elif [[ "$BASENAME" == *"2022"* ]] || [[ "$BASENAME" == *"2k22"* ]]; then
            IMAGE_NAME="server2k22"
        else
            IMAGE_NAME="${BASENAME}"
        fi
    elif [[ "$BASENAME" == *"client"* ]] || [[ "$BASENAME" == *"win11"* ]] || [[ "$BASENAME" == *"windows11"* ]]; then
        IMAGE_NAME="client11_base"
    else
        IMAGE_NAME="${BASENAME}_$(date +%Y%m%d)"
    fi
    
    print_info "Generated image name: $IMAGE_NAME"
    
    # Display image size
    local IMAGE_SIZE=$(du -h "$IMAGE_PATH" | cut -f1)
    print_info "Image size: $IMAGE_SIZE"
    
    # Check if image already exists
    print_info "Checking if image '$IMAGE_NAME' already exists in OpenStack..."
    if openstack image show "$IMAGE_NAME" &> /dev/null; then
        print_warning "An image with the name '$IMAGE_NAME' already exists!"
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping upload of $IMAGE_PATH"
            return
        fi
        
        # Delete existing image
        print_info "Deleting existing image..."
        openstack image delete "$IMAGE_NAME"
        print_success "Existing image deleted"
    fi
    
    # Upload image to OpenStack
    print_info "Uploading image to OpenStack..."
    print_info "This may take some time depending on image size and network speed..."
    
    openstack image create \
        --file "$IMAGE_PATH" \
        --disk-format qcow2 \
        --container-format bare \
        "$IMAGE_NAME"
    
    # Success message
    echo ""
    print_success "Image '$IMAGE_NAME' successfully uploaded to OpenStack!"
    echo ""
    print_info "Image Details:"
    openstack image show "$IMAGE_NAME"
}

# Run main function
main "$@"
