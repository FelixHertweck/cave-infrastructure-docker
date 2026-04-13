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

#### 2. Configure OpenStack Credentials

Choose **one** of these methods:

**Option A: Using `.env` file** (simpler for automated deployments)
```bash
cp .env.sample .env
# Edit .env and set OS_PASSWORD, OS_AUTH_URL, OS_PROJECT_NAME, etc.
```

**Option B: Using `.openrc` file** (downloaded from OpenStack Dashboard)
```bash
# Download from OpenStack Dashboard: Project → API Access → Download OpenStack RC File
# Then fix the interactive password prompt:
cp .openrc.sample .openrc
# Edit .openrc and REPLACE these lines:
#   echo "Please enter your OpenStack Password..."
#   read -sr OS_PASSWORD_INPUT
#   export OS_PASSWORD=$OS_PASSWORD_INPUT
# With:
#   export OS_PASSWORD=your-actual-password-here
```

⚠️ **IMPORTANT**: The password prompt `read -sr` in OpenStack-generated RC files breaks Docker automation. You **must** remove it and set the password directly.

#### 3. Configure OpenStack Credentials (continued)

Review the configuration:
- If using `.env`: Set all credentials in the file
- If using `.openrc`: File is automatically sourced in the container
- Both methods work - choose what fits your workflow

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


## Troubleshooting

### ❌ "Please enter your OpenStack Password..." prompt appears

**Problem**: Your `.openrc` file contains the interactive password prompt.

**Solution**: Edit `.openrc` and replace these lines:
```bash
# ❌ Remove these lines:
echo "Please enter your OpenStack Password for project $OS_PROJECT_NAME as user $OS_USERNAME: "
read -sr OS_PASSWORD_INPUT
export OS_PASSWORD=$OS_PASSWORD_INPUT
```

With:
```bash
# ✅ Add this line instead:
export OS_PASSWORD=your-actual-password-here
```

This is necessary because Docker runs non-interactively. OpenStack-generated RC files are designed for manual shell usage, but need adjustment for automation.

### ❌ "OS_PASSWORD is not set" error

**Problem**: Both `.env` and `.openrc` are missing the password.

**Solution**: 
1. Make sure `.env` exists and has `OS_PASSWORD=your-password`, OR
2. Make sure `.openrc` exists and has `export OS_PASSWORD=your-password`

At least one must be configured.


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
