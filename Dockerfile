# Multi-stage build for CAVE Infrastructure
FROM python:3.12-slim AS builder

ARG CAVE_REPO=https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure.git
ARG CAVE_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel

RUN git config --global url."https://gitlab.opencode.de/".insteadOf "git@gitlab.opencode.de:" && \
    git clone --branch "${CAVE_REF}" "${CAVE_REPO}" /tmp/cave && \
    cd /tmp/cave && git submodule update --init --recursive

RUN cd /tmp/cave/backend && pip install --no-cache-dir -e ".[cli]"

# ---

FROM ghcr.io/opentofu/opentofu:minimal AS tofu

# ---

FROM python:3.12-slim

LABEL maintainer="CAVE Infrastructure"
LABEL description="Docker container for CAVE Infrastructure deployment"

COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl \
    jq \
    wireguard-tools \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /tmp/cave /cave

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /cave

RUN chmod +x backend/make_it_so.sh && \
    chmod +x backend/exterminate.sh && \
    chmod +x backend/configs/generate_openstack_config.sh

WORKDIR /cave/backend

CMD ["bash", "-c", "./make_it_so.sh --help"]