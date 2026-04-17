# Multi-stage build for CAVE Infrastructure
FROM python:3.12.9-slim-bookworm AS builder

ARG CAVE_REPO=https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure.git
ARG CAVE_REF=3b808721950f77f578b17818e15f3ac0e05600b4

# Use BuildKit cache mount mounts for faster pip installs
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libssl-dev \
    libffi-dev \
    python3-dev

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip setuptools wheel uv

# Clone the repository and checkout specific commit
RUN git config --global url."https://gitlab.opencode.de/".insteadOf "git@gitlab.opencode.de:" && \
    git clone "${CAVE_REPO}" /tmp/cave && \
    cd /tmp/cave && \
    git checkout "${CAVE_REF}" && \
    git submodule update --init --recursive

RUN --mount=type=cache,target=/root/.cache/pip \
    cd /tmp/cave/backend && pip install -e ".[cli]" && \
    pip install python-openstackclient

# ---

FROM ghcr.io/opentofu/opentofu:1.9.0 AS tofu

# ---

FROM python:3.12.9-slim-bookworm

LABEL maintainer="CAVE Infrastructure"
LABEL description="Docker container for CAVE Infrastructure deployment"

COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

# Combine all apt-get calls into one layer to reduce layer count
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    openssl \
    jq \
    wireguard-tools \
    ca-certificates \
    ansible \
    git \
    wget \
    unzip

RUN wget https://releases.hashicorp.com/packer/1.10.2/packer_1.10.2_linux_amd64.zip && \
    unzip packer_1.10.2_linux_amd64.zip && \
    mv packer /usr/local/bin/ && \
    rm packer_1.10.2_linux_amd64.zip

RUN useradd -m -u 1000 cave

COPY --chown=cave:cave entrypoint.sh /entrypoint.sh
COPY --chown=cave:cave main-menu.sh /cave/backend/main-menu.sh
COPY --chown=cave:cave deploy-wrapper.sh /cave/backend/deploy-wrapper.sh
COPY --chown=cave:cave build-images.sh /cave/backend/build-images.sh
COPY --from=builder --chown=cave:cave /opt/venv /opt/venv
COPY --from=builder --chown=cave:cave /tmp/cave /cave

RUN chmod +x /entrypoint.sh && \
    chmod +x /cave/backend/main-menu.sh && \
    chmod +x /cave/backend/deploy-wrapper.sh && \
    chmod +x /cave/backend/build-images.sh && \
    chmod +x /cave/backend/make_it_so.sh && \
    chmod +x /cave/backend/exterminate.sh && \
    chmod +x /cave/backend/configs/generate_openstack_config.sh

USER cave
WORKDIR /home/cave

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /cave/backend

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/cave/backend/main-menu.sh"]