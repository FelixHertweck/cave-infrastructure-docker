# CAVE Infrastructure Docker

A Docker deployment wrapper for the [CAVE Infrastructure](https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure-docker) project by BSI-Bund.

This repository provides an easy way to build and run CAVE Infrastructure in Docker containers, including all necessary dependencies (Python, OpenTofu, OpenStack CLI, WireGuard).

## Quick Start

### Prerequisites

- Docker and Docker Compose installed
- OpenStack credentials (RC file or environment variables)
- SSH key for deployment
- (Optional) GitHub Container Registry access for pushing images

### Run CAVE Infrastructure in Docker

#### 1. Prepare Required Files

Create the following directory structure in the project root:

```
.
├── docker-compose.yml
├── .env                    # ← Copy from .env.sample and customize
├── .env.sample             # Template for environment variables
├── .openrc                 # (Optional) OpenStack RC file
├── ssh-keys/               # SSH keys for deployment
│   └── id_rsa
├── backend/
│   └── configs/           # CAVE configuration files
│       ├── day1.json5
│       └── users_day1.json
└── out/                    # Output directory (created automatically)
```

#### 2. Configure Environment Variables

```bash
# Copy the sample file
cp .env.sample .env

# Edit .env with your OpenStack credentials
```

See [.env.sample](.env.sample) for all available options.

#### 3. Configure docker-compose.yml

Review the service configuration in [docker-compose.yml](docker-compose.yml). Key points:
- Environment variables are loaded from `.env` file
- SSH keys mounted at `./ssh-keys:/home/cave/.ssh:ro`
- Config files at `./backend/configs:/cave/backend/configs:ro` 
- Output at `./out:/cave/out:rw`
- WireGuard capability enabled (`cap_add: NET_ADMIN`)

#### 4. Build the Image

```bash
# Build locally (with BuildKit for better caching)
DOCKER_BUILDKIT=1 docker-compose build

# Or pull pre-built image
docker-compose pull
```

#### 5. Run Deployments

**Interactive Shell** – For debugging or manual commands:
```bash
docker-compose run --rm cave bash
```

**Direct Deployment** – Single command (credentials auto-loaded from .env):
```bash
docker-compose run --rm cave ./make_it_so.sh \
  configs/day1.json5 \
  ~/.ssh/id_rsa \
  configs/users_day1.json \
  --lab-prefix mylab
```

#### Tips

- **Credentials**: Both `.env` and `.openrc` auto-sourced by entrypoint
- **SSH Key Path**: Inside container at `/home/cave/.ssh/`
- **Config Files**: Inside container at `/cave/backend/configs/`
- **Output**: Generated files go to `./out/` (mounted as rw)
- **BuildKit**: Set `DOCKER_BUILDKIT=1` for 40-60% faster builds
- **Interactive Work**: Use `docker-compose run --rm cave bash` to explore



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

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Related Projects

- [CAVE Infrastructure](https://gitlab.opencode.de/BSI-Bund/cave/cave-infrastructure-docker) - The main CAVE project
- [OpenTofu](https://opentofu.org/) - Infrastructure as Code tool used by CAVE
- [OpenStack](https://www.openstack.org/) - Cloud computing platform
