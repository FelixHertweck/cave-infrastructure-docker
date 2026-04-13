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

#### 4. Build OpenStack Images (Required Before First Deployment)

Before deploying the infrastructure, you need to build the CAVE images and upload them to OpenStack. The container includes Packer and Ansible for this purpose.

```bash
# Start the image builder
docker-compose run --rm cave ./build-images.sh
```

This will:
1. Clone the CAVE-Images repository
2. Show available Packer templates
3. Guide you through the build process

**Inside the container, you'll then run:**
```bash
cd /tmp/cave-images
packer init .
packer build -var-file=vars/vpn.pkrvars.hcl .
# Repeat for each image: ctfd, dns, etherpad, kali-vnc, recplast-website
```

The built images will automatically be uploaded to your OpenStack project.

#### 5. Build the Docker Image

```bash
# Build locally (with BuildKit for better caching)
DOCKER_BUILDKIT=1 docker-compose build

# Or pull pre-built image
docker-compose pull
```

#### 6. Deploy Infrastructure

The repository includes a **deployment wrapper** (`deploy-wrapper.sh`) that simplifies the deployment process by automatically handling common parameters.

##### Using the Wrapper (Recommended)

The wrapper provides an interactive interface and automatically:
- Uses credentials from your `.env` or `.openrc`
- Uses SSH key from `SSH_KEY_NAME` in `.env`
- Auto-discovers user configuration files
- Validates all inputs before deploying

**Interactive mode (choose config from menu):**
```bash
docker-compose run --rm cave
```

**Direct mode (specify config):**
```bash
docker-compose run --rm cave /cave/deploy-wrapper.sh day1
```

**With WireGuard VPN:**
```bash
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --wg
```

**With custom lab prefix:**
```bash
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --lab-prefix my-training-01 --wg
```

**Dry-run (see what would be executed):**
```bash
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --dry-run
```

##### Wrapper Features

The deployment wrapper automatically:
- ✅ Validates OpenStack credentials
- ✅ Confirms SSH key exists and is readable
- ✅ Lists available configurations to choose from
- ✅ Auto-detects user configuration files (`users_<config>.json`)
- ✅ Shows deployment summary before confirming
- ✅ Provides helpful error messages
- ✅ Supports WireGuard (`--wg`) and OpenVPN (default)

##### Manual Deployment (Advanced)

If you need more control, use the raw command:
```bash
docker-compose run --rm cave /cave/backend/make_it_so.sh \
  /cave/backend/configs/day1.json5 \
  /home/cave/.ssh/$SSH_KEY_NAME \
  /cave/backend/configs/users_day1.json \
  --lab-prefix day01 \
  --wg
```

##### Interactive Shell

For debugging or exploring:
```bash
docker-compose run --rm cave bash
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

### Build Images First (One-time setup)
```bash
docker-compose run --rm cave ./build-images.sh
# Follow instructions inside container to build with Packer
```

### Interactive Deployment (Recommended)
```bash
# Choose config from menu
docker-compose run --rm cave
```

### Deploy Specific Configuration
```bash
# Deploy day1 config with default settings
docker-compose run --rm cave /cave/deploy-wrapper.sh day1

# Deploy day1 with WireGuard
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --wg

# Deploy with custom prefix
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --lab-prefix training-01 --wg

# Try before deploying (dry-run)
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --dry-run
```

### Destroy Infrastructure
```bash
docker-compose run --rm cave ./exterminate.sh <lab-prefix> [--hard]
```

## Deployment Wrapper Details

The `deploy-wrapper.sh` script simplifies infrastructure deployment by handling common tasks automatically.

### Wrapper Usage Patterns

**Pattern 1: Interactive Selection**
```bash
# Lists available configs and lets you choose
docker-compose run --rm cave
```

**Pattern 2: Direct Configuration**
```bash
# Directly specify config name
docker-compose run --rm cave /cave/deploy-wrapper.sh day1
```

**Pattern 3: With VPN Technology**
```bash
# WireGuard (modern, faster, but less reliable on clock skew)
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --wg

# OpenVPN (default, more stable in unreliable time sync scenarios)
docker-compose run --rm cave /cave/deploy-wrapper.sh day1
```

**Pattern 4: Custom Parameters**
```bash
# Custom lab prefix (multiple deployments from same config)
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --lab-prefix training-group-a

# Custom user config file
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --users /cave/backend/configs/users_custom.json

# Combine options
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --lab-prefix training-01 --wg --users /cave/backend/configs/users_advanced.json
```

**Pattern 5: Dry-Run (Test Without Deploying)**
```bash
# Shows what would be executed
docker-compose run --rm cave /cave/deploy-wrapper.sh day1 --dry-run
```

### What the Wrapper Does

1. **Validates Credentials**
   - Checks `OS_PASSWORD` is set
   - Validates OpenStack credentials are available

2. **Validates SSH Key**
   - Verifies `SSH_KEY_NAME` is set in `.env`
   - Checks SSH key file exists in container

3. **Config Management**
   - Interactive menu if no config specified
   - Validates JSON5 config file syntax
   - Supports all configs in `/cave/backend/configs/`

4. **User File Discovery**
   - Auto-finds `users_<config>.json`
   - Allows custom user config files
   - Works with or without user config

5. **Parameter Handling**
   - Uses `LAB_PREFIX` from `.env` or parameter
   - Supports WireGuard (`--wg`) and OpenVPN
   - Full parameter validation

6. **Deployment Confirmation**
   - Shows deployment summary
   - Asks for confirmation before deploying
   - Can skip with `--dry-run` for testing

### Troubleshooting the Wrapper

**Error: "Config file not found"**
```bash
# Check available configs
docker-compose run --rm cave ls /cave/backend/configs/*.json5
```

**Error: "SSH key not found"**
```bash
# Verify SSH key name in .env
docker-compose run --rm cave grep SSH_KEY_NAME /etc/environment

# Check if key exists in container
docker-compose run --rm cave ls -la /home/cave/.ssh/
```

**Need more control?**
```bash
# Use manual mode with make_it_so.sh directly
docker-compose run --rm cave bash
# Then run custom commands inside the container
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
