FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Configure cave-images repository and reference (tag, branch, or commit)
ARG CAVE_REPO=https://gitlab.opencode.de/oc000142689289/cave-images.git
ARG CAVE_REF=main

# Install dependencies for QEMU, UEFI simulation, git and noVNC
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 \
    qemu-kvm \
    qemu-utils \
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
    novnc \
    websockify \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /work

# Clone cave-images repository and extract windows-image-generation content
RUN git clone "${CAVE_REPO}" /tmp/cave-images && \
    cd /tmp/cave-images && \
    git fetch --depth 1 origin "${CAVE_REF}" && \
    git checkout "${CAVE_REF}" && \
    # Copy windows-image-generation directory
    cp -r /tmp/cave-images/windows-image-generation/* /work/ && \
    # Cleanup temporary clone
    rm -rf /tmp/cave-images && \
    # Make bootstrap script executable
    chmod +x /work/bootstrap.sh

# Copy OVMF files for UEFI emulation (must be actual copies, not symlinks)
RUN cp /usr/share/OVMF/OVMF_CODE_4M.ms.fd /work/ && \
    cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd /work/

# Copy wrapper script
COPY wrapper.sh /work/wrapper.sh
RUN chmod +x /work/wrapper.sh

# Expose noVNC port for web terminal
EXPOSE 8080

# Run the wrapper script
CMD ["/work/wrapper.sh"]
