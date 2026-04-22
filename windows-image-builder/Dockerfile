FROM debian:bookworm

LABEL maintainer="CAVE Infrastructure"
LABEL description="Docker container for Windows image generation using QEMU and swtpm"

# Install dependencies for QEMU, UEFI simulation and git
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 \
    qemu-kvm \
    qemu-efi \
    ovmf \
    swtpm \
    swtpm-tools \
    genisoimage \
    curl \
    sed \
    bash \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /work

# Clone cave-images repository and extract windows-image-generation content
RUN git clone --depth 1 https://gitlab.opencode.de/BSI-Bund/cave/cave-images.git /tmp/cave-images && \
    # Copy windows-image-generation directory
    cp -r /tmp/cave-images/windows-image-generation/* /work/ && \
    # Cleanup temporary clone
    rm -rf /tmp/cave-images && \
    # Make bootstrap script executable
    chmod +x /work/bootstrap.sh

# Default to bash shell for interactive use
CMD ["/bin/bash"]
