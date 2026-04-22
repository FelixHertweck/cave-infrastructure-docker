# Windows Image Builder for CAVE Infrastructure

Isolated Docker environment for generating Windows images with QEMU and swtpm.

The `cave-images` repository is automatically cloned during Docker build.

## Quick Start

### Prepare ISO Files


### Build Docker Image

```bash
cd windows-image-builder

docker build -t ghcr.io/felixhertweck/cave-infrastructure-windows-image-builder:latest .
```

### Generate Windows Image

```bash
# Windows 11 Client (create new)
docker compose run --rm windows-image-builder \
  ./bootstrap.sh --variant client --new-disk

# Windows Server 2022 (create new)
docker compose run --rm windows-image-builder \
  ./bootstrap.sh --variant server2022 --new-disk

# Windows Server 2025 (create new)
docker compose run --rm windows-image-builder \
  ./bootstrap.sh --variant server2025 --new-disk
```

### 4. Interactive Shell (optional)

```bash
docker compose run --rm windows-image-builder bash
# Then in container:
cd /work/workspace
./bootstrap.sh --variant client --new-disk
```

## Generated Images

After successful build, QCOW2 images are available here:

```
windows-image-builder/output/
├── hda_client.qcow2
└── hda_server.qcow2
```

## Configuration

Modify environment variables in `docker compose.yml`:

```yaml
environment:
  - SPICE_PORT=5900      # VNC Port
  - VM_MEMORY=8G         # RAM for Windows VM
  - VM_CPUS=4            # CPU Cores
  - DISK_SIZE=64G        # Virtual disk size
  - LOCAL_TIMEZONE=Europe/Berlin
```

## Dockerfile - Build Process

The `Dockerfile` performs the following steps:

1. **Base Image:** Debian Bookworm
2. **Dependencies:** QEMU, swtpm, OVMF, genisoimage, git, ca-certificates
3. **Repository Clone:** Clones `cave-images` from GitLab
4. **Extraction:** Copies `windows-image-generation/*` content into `/work`
5. **Cleanup:** Removes temporary repository clone
6. **Executable:** Makes `bootstrap.sh` executable

During build, `bootstrap.sh` and `templates/` are automatically fetched from the cave-images repository and included in the image.

