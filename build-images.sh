#!/bin/bash
# Build CAVE Images using Packer and upload to OpenStack
# This script clones the CAVE-Images repository and builds all images

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          CAVE Infrastructure - Image Builder              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if OpenStack credentials are set
if [ -z "$OS_PASSWORD" ]; then
    echo "[ERROR] OS_PASSWORD is not set!"
    echo "[ERROR] Make sure to source credentials first:"
    echo "[ERROR]   source .openrc  OR  source .env"
    exit 1
fi

# Variables
CAVE_IMAGES_REPO="https://gitlab.opencode.de/BSI-Bund/cave/cave-images.git"
CAVE_IMAGES_DIR="/tmp/cave-images"
OUTPUT_DIR="${OUTPUT_DIR:-./out}"

mkdir -p "$OUTPUT_DIR"

echo "[INFO] Cloning CAVE-Images repository..."
if [ -d "$CAVE_IMAGES_DIR" ]; then
    echo "[INFO] Repository already exists, pulling latest changes..."
    cd "$CAVE_IMAGES_DIR"
    git pull
else
    git clone "$CAVE_IMAGES_REPO" "$CAVE_IMAGES_DIR"
    cd "$CAVE_IMAGES_DIR"
fi

echo "[INFO] Repository ready at: $CAVE_IMAGES_DIR"
echo ""
echo "Available images to build:"
echo "  - vpn"
echo "  - ctfd"
echo "  - etherpad"
echo "  - dns"
echo "  - recplast-website"
echo "  - kali-vnc"
echo ""

# Show available packer templates
if [ -d "packer" ]; then
    echo "[INFO] Available Packer templates:"
    find packer -name "*.pkr.hcl" -o -name "*.json" | head -10
fi

echo ""
echo "Next steps:"
echo "1. Read the CAVE-Images README for detailed build instructions"
echo "2. Run: packer build <template>"
echo "3. Images will be uploaded to your OpenStack project"
echo ""
echo "For example:"
echo "  cd $CAVE_IMAGES_DIR"
echo "  packer init ."
echo "  packer build -var-file=vars/vpn.pkrvars.hcl ."
echo ""
