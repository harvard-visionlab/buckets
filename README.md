# visionlab-buckets

S3 bucket mounting utilities for research workflows. Mount S3 buckets via rclone with smart symlink handling across platforms.

## Features

- **Python API** for mounting S3 buckets via rclone/FUSE
- **CLI utilities**: `mount-bucket` and `unmount-bucket`
- **Smart mounting**: single mount point with multiple symlinks
- **Cross-platform**: Linux (SLURM, Lightning Studio, devbox) and macOS
- **Zero dependencies**: only Python standard library required

## Installation

### Global CLI Installation (Recommended)

Install the CLI tools globally so `mount-bucket` and `unmount-bucket` are available everywhere:

```bash
# Using uv tool (recommended)
uv tool install git+https://github.com/harvard-visionlab/buckets.git

# Verify installation
mount-bucket --help
```

To update or uninstall:
```bash
uv tool upgrade visionlab-buckets
uv tool uninstall visionlab-buckets
```

### Project Dependency

Add to your `pyproject.toml`:

```toml
dependencies = [
    "visionlab-buckets @ git+https://github.com/harvard-visionlab/buckets.git",
]
```

Then lock and sync:
```bash
uv lock
uv sync --locked
```

### Development Install

```bash
git clone https://github.com/harvard-visionlab/buckets.git
cd buckets
uv sync              # Creates venv and installs package
uv run mount-bucket --help
```

## Quick Start

### Python API

```python
from visionlab.buckets import mount_bucket, unmount_bucket, is_mounted

# Mount with platform-dependent default root
mount_bucket("teamspace-lrm")
# -> Creates mount at /tmp/<user>/rclone/teamspace-lrm
# -> Symlink at ~/s3_buckets/teamspace-lrm (or /tmp/<user>/s3_buckets on SLURM)

# Mount with custom root
mount_bucket("teamspace-lrm", root_dir="./data")
# -> Symlink at ./data/teamspace-lrm

# Multiple symlinks to same mount (no duplicate mounts)
mount_bucket("teamspace-lrm", root_dir="~/project1/data")
mount_bucket("teamspace-lrm", root_dir="~/project2/data")

# Check status
is_mounted("teamspace-lrm")  # -> True/False

# Unmount
unmount_bucket("teamspace-lrm")
```

### CLI

```bash
# Basic usage
mount-bucket teamspace-lrm

# With s3:// prefix (stripped automatically)
mount-bucket s3://teamspace-lrm

# Custom root directory
mount-bucket teamspace-lrm --root ./data

# List all mounts
mount-bucket --list

# Check status
mount-bucket --status teamspace-lrm

# Unmount
unmount-bucket teamspace-lrm

# Unmount all
unmount-bucket --all
```

## AWS Credentials Setup

Before mounting S3 buckets, you need AWS credentials configured. The rclone config uses `env_auth = true`, which means it reads credentials from environment variables.

### Lightning Studio

Set AWS credentials as **global user environment variables** in the Lightning Studio UI:

1. Go to your Lightning Studio settings
2. Navigate to "Environment Variables" or "Secrets"
3. Add these variables:
   - `AWS_ACCESS_KEY_ID` = your access key
   - `AWS_SECRET_ACCESS_KEY` = your secret key

These persist across studio restarts and are available in all terminals.

### FASRC SLURM / Linux Workstations / macOS

Add AWS credentials to your shell configuration file:

**For bash** (`~/.bashrc`):
```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
```

**For zsh** (`~/.zshrc`):
```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
```

**For fish** (`~/.config/fish/config.fish`):
```fish
set -gx AWS_ACCESS_KEY_ID "your-access-key-id"
set -gx AWS_SECRET_ACCESS_KEY "your-secret-access-key"
```

After editing, reload your shell:
```bash
source ~/.bashrc  # or ~/.zshrc
```

### Verify Credentials

```bash
# Check environment variables are set
echo $AWS_ACCESS_KEY_ID

# Test S3 access (after rclone is configured)
rclone lsd s3_remote:
```

## Platform Setup

Before using this package, you need to install **rclone** and **FUSE**, then configure rclone.

### FASRC SLURM Cluster

rclone is pre-installed on FASRC. Just add the config file:

```bash
mkdir -p ~/.config/rclone
nano ~/.config/rclone/rclone.conf
```

Add:
```ini
[s3_remote]
type = s3
provider = AWS
env_auth = true
region = us-east-1
acl = public-read
```

Test:
```bash
rclone lsd s3_remote:
rclone lsd s3_remote:teamspace-lrm
```

### Lightning Studio

```bash
# Install FUSE and rclone
sudo apt-get update && sudo apt-get install -y fuse3
curl https://rclone.org/install.sh | sudo bash

# Configure rclone
mkdir -p ~/.config/rclone
nano ~/.config/rclone/rclone.conf
```

Add:
```ini
[s3_remote]
type = s3
provider = AWS
env_auth = true
region = us-east-1
acl = public-read
```

Test:
```bash
rclone lsd s3_remote:
rclone lsd s3_remote:teamspace-lrm
```

### Local GPU Workstation (Linux)

```bash
# Install FUSE and rclone
sudo apt-get update && sudo apt-get install -y fuse3
curl https://rclone.org/install.sh | sudo bash

# Configure rclone
mkdir -p ~/.config/rclone
nano ~/.config/rclone/rclone.conf
```

Add:
```ini
[s3_remote]
type = s3
provider = AWS
env_auth = true
region = us-east-1
acl = public-read
```

### Local CPU Workstation (macOS)

```bash
# Remove conflicting FUSE implementations (if present)
brew uninstall --cask macfuse 2>/dev/null
brew uninstall --cask osxfuse 2>/dev/null

# Install FUSE-T (kext-less FUSE implementation)
brew install --cask fuse-t

# Remove Homebrew rclone (if installed) and install official binary
brew uninstall rclone 2>/dev/null
cd /tmp
curl -O https://downloads.rclone.org/rclone-current-osx-arm64.zip
unzip rclone-current-osx-arm64.zip
cd rclone-*-osx-arm64
sudo cp rclone /usr/local/bin/
sudo chmod +x /usr/local/bin/rclone

# Verify
which rclone
rclone version
ls -la /Library/Frameworks/fuse_t.framework

# Configure rclone
mkdir -p ~/.config/rclone
nano ~/.config/rclone/rclone.conf
```

Add:
```ini
[s3_remote]
type = s3
provider = AWS
env_auth = true
region = us-east-1
acl = public-read
```

Test:
```bash
rclone lsd s3_remote:
```

## Platform Detection

The package includes zero-dependency platform detection:

```python
from visionlab.buckets import (
    is_lightning_studio,
    is_slurm,
    is_macos,
    is_linux,
    has_gpu,
    get_platform_name,
)

# Detect environment without importing torch/lightning
is_lightning_studio()  # True if on Lightning Studio
is_slurm()             # True if in a SLURM job
has_gpu()              # True if NVIDIA GPU available (no torch needed)
get_platform_name()    # "lightning", "slurm", "macos", "linux-gpu", etc.
```

## How It Works

The package separates **mount points** from **symlinks**:

```
Mount point:  /tmp/<user>/rclone/<bucket_name>   (singleton per bucket)
Symlinks:     <root_dir>/<bucket_name>           (can have many)
```

This allows multiple projects to reference the same bucket without duplicate mounts:

```python
# These all point to the same mount - no wasted resources
mount_bucket("teamspace-lrm", root_dir="~/project1/data")
mount_bucket("teamspace-lrm", root_dir="~/project2/data")
mount_bucket("teamspace-lrm", root_dir="./experiments")
```

## Private Buckets

For private bucket access, add a second rclone remote:

```ini
[s3_remote_private]
type = s3
provider = AWS
env_auth = true
region = us-east-1
acl = private
```

Then specify the remote:
```python
mount_bucket("my-private-bucket", remote_name="s3_remote_private")
```

## Development

```bash
git clone https://github.com/harvard-visionlab/buckets.git
cd buckets
uv sync --all-extras    # Install with dev dependencies

# Run tests
uv run pytest

# Lint
uv run ruff check .
```

## License

MIT
