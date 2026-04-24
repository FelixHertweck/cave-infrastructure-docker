# Multi-stage build for CAVE Infrastructure
FROM python:3.12.9-slim-bookworm AS builder

ARG CAVE_REPO=https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure.git
ARG CAVE_REF=3b808721950f77f578b17818e15f3ac0e05600b4

# Install build dependencies only in builder stage
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libssl-dev \
    libffi-dev \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip setuptools wheel uv

# Clone repository and checkout specific commit with cache
RUN --mount=type=cache,target=/root/.cache \
    git config --global url."https://gitlab.opencode.de/".insteadOf "git@gitlab.opencode.de:" && \
    git clone "${CAVE_REPO}" /tmp/cave && \
    cd /tmp/cave && \
    git fetch --depth 1 origin "${CAVE_REF}" && \
    git checkout "${CAVE_REF}" && \
    git submodule update --init --recursive --depth 1

RUN --mount=type=cache,target=/root/.cache/pip \
    cd /tmp/cave/backend && pip install -e ".[cli]" --no-cache-dir && \
    pip install python-openstackclient --no-cache-dir

# Remove .git directory to save space
RUN rm -rf /tmp/cave/.git /tmp/cave/*/.git

# ---

FROM ghcr.io/opentofu/opentofu:1.9.0 AS tofu

# ---

FROM python:3.12.9-slim-bookworm AS final

LABEL maintainer="CAVE Infrastructure"
LABEL description="Docker container for CAVE Infrastructure deployment"

# Copy OpenTofu binary
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

# Copy docker-buildx binary
COPY --from=docker/buildx-bin /buildx /usr/libexec/docker/cli-plugins/docker-buildx

# Install only essential runtime dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    openssl \
    jq \
    wireguard-tools \
    ca-certificates \
    git \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Optional: Install ansible only if needed (comment out if not required)
# RUN apt-get update && apt-get install -y --no-install-recommends ansible && rm -rf /var/lib/apt/lists/*

# Install Packer cleanly
RUN wget -q https://releases.hashicorp.com/packer/1.10.2/packer_1.10.2_linux_amd64.zip && \
    unzip -q packer_1.10.2_linux_amd64.zip && \
    mv packer /usr/local/bin/ && \
    rm -f packer_1.10.2_linux_amd64.zip

# Create non-root user
RUN useradd -m -u 1000 cave

# Copy scripts and application
COPY --chown=cave:cave scripts/entrypoint.sh /entrypoint.sh
COPY --chown=cave:cave scripts/*.sh /cave/
COPY --from=builder --chown=cave:cave /opt/venv /opt/venv
COPY --from=builder --chown=cave:cave /tmp/cave /cave

# Set permissions
RUN chmod +x /entrypoint.sh && \
    chmod +x /cave/*.sh && \
    chmod +x /cave/backend/make_it_so.sh && \
    chmod +x /cave/backend/exterminate.sh && \
    chmod +x /cave/backend/configs/generate_openstack_config.sh

# Cleanup: remove unnecessary files
RUN find /cave -name "*.pyc" -delete && \
    find /cave -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

USER cave
WORKDIR /home/cave

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /cave

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/cave/main-menu.sh"]