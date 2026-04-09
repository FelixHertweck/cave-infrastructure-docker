# CAVE Infrastructure Docker

A Docker deployment wrapper for the [CAVE Infrastructure](https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure-docker) project by BSI-Bund.

This repository provides an easy way to build and run CAVE Infrastructure in Docker containers, including all necessary dependencies (Python, OpenTofu, OpenStack CLI, WireGuard).

## Quick Start

### Prerequisites

- Docker and Docker Compose installed
- OpenStack credentials (RC file or environment variables)
- SSH key for deployment
- (Optional) GitHub Container Registry access for pushing images

### 1. Build the Image

```bash
# Using Docker Compose (recommended)
docker-compose build

# Or using Docker directly
docker build -t ghcr.io/felixhertweck/cave-infrastructure-docker:latest .
```

### 2. Run the Container

```bash
# Interactive shell with Docker Compose
docker-compose run --rm cave /bin/bash

# Inside the container, source your OpenStack credentials
source /.openrc

# Deploy infrastructure
./make_it_so.sh configs/day1.json5 ~/.ssh/id_rsa configs/users_day1.json --lab-prefix mylab
```

## Common Deployment Commands

### Deploy Day 1 Lab
```bash
./make_it_so.sh \
  configs/day1.json5 \
  ~/.ssh/admin_key \
  configs/users_day1.json \
  --lab-prefix day01
```

### Deploy Day 5 Lab
```bash
./make_it_so.sh \
  configs/day5.json5 \
  ~/.ssh/id_rsa \
  configs/users_day5.json \
  --lab-prefix custom01 \
  --wg
```

### Destroy Infrastructure
```bash
./exterminate.sh <lab-prefix> [--hard]
```

## Push to GitHub Container Registry

This project is optimized for GitHub Container Registry (ghcr.io).

### Setup

1. **Create a GitHub Personal Access Token:**
   - Go to [GitHub Settings → Developer settings → Personal access tokens](https://github.com/settings/tokens)
   - Create a token with `write:packages`, `read:packages`, `delete:packages` scopes

2. **Login to GitHub Container Registry:**
   ```bash
   echo $GITHUB_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin
   ```

### Build and Push

```bash
# Build with registry namespace
docker build -t ghcr.io/felixhertweck/cave-infrastructure-docker:latest .

# Push to registry
docker push ghcr.io/felixhertweck/cave-infrastructure-docker:latest

# Tag and push a version
docker tag ghcr.io/felixhertweck/cave-infrastructure-docker:latest \
  ghcr.io/felixhertweck/cave-infrastructure-docker:v1.0.0
docker push ghcr.io/felixhertweck/cave-infrastructure-docker:v1.0.0
```

### Use Image from Registry

Update `docker-compose.yml`:
```yaml
services:
  cave:
    image: ghcr.io/felixhertweck/cave-infrastructure-docker:latest
```

Then run:
```bash
docker-compose pull
docker-compose run --rm cave /bin/bash
```

## Automatic Builds with GitHub Actions

Enable automatic builds and pushes on every commit. Create `.github/workflows/docker-build-push.yml`:

```yaml
name: Build and Push Docker Image

on:
  push:
    branches: [main]
    tags: ['v*']
  workflow_dispatch:

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ghcr.io/${{ github.repository_owner }}/cave-infrastructure-docker
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=sha
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

## Environment Variables

Key OpenStack environment variables used inside the container:

- `OS_PROJECT_NAME` - OpenStack project name
- `OS_USERNAME` - OpenStack username  
- `OS_PASSWORD` - OpenStack password
- `OS_AUTH_URL` - OpenStack authentication endpoint
- `OS_REGION_NAME` - OpenStack region (default: RegionOne)
- `OS_IDENTITY_API_VERSION` - OpenStack identity version (default: 3)

## Troubleshooting

### Permission Denied on SSH Keys
```bash
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub
```

### OpenStack Connection Issues
```bash
# Inside container, verify credentials
openstack --version
openstack endpoint list
openstack image list
```

### Generated Files Ownership
```bash
# Fix permissions after deployment
docker-compose exec cave chown -R $(id -u):$(id -g) /cave/out
```

## Project Structure

| Component | Location | Purpose |
|-----------|----------|---------|
| SSH Keys | `~/.ssh` | SSH keys for deployment |
| OpenStack RC | `/.openrc` | OpenStack API credentials |
| Configs | `/cave/backend/configs` | Lab configuration files |
| Output | `/cave/out` | Generated OpenTofu infrastructure code |

## Detailed Documentation

For more information, see:
- [DOCKER.md](DOCKER.md) - Detailed Docker and Docker Compose guide
- [CAVE Infrastructure Docs](https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure-docker) - Official CAVE project documentation
- [OpenTofu Documentation](https://opentofu.org/)
- [GitHub Container Registry Docs](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Related Projects

- [CAVE Infrastructure](https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure-docker) - The main CAVE project
- [OpenTofu](https://opentofu.org/) - Infrastructure as Code tool used by CAVE
- [OpenStack](https://www.openstack.org/) - Cloud computing platform
