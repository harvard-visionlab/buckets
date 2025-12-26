# Plan: Standalone `visionlab-buckets` Utility

**Target repo:** `harvard-visionlab/buckets`
**Package namespace:** `visionlab.buckets`

---

## Goals

1. **Python API** for mounting S3 buckets via rclone/FUSE
2. **CLI utility** for shell-based mounting
3. **Smart mounting**: mount once, allow multiple symlinks
4. **Cross-platform**: Linux (Lightning Studio, SLURM, devbox) and macOS

---

## Python API

```python
from visionlab.buckets import mount_bucket, unmount_bucket, is_mounted

# Mount with platform-dependent default root
mount_bucket("teamspace-lrm")
# -> Creates mount at /tmp/<user>/rclone/teamspace-lrm
# -> Symlink at <default_root>/teamspace-lrm

# Mount with custom root
mount_bucket("teamspace-lrm", root_dir="./s3_buckets")
# -> Symlink at ./s3_buckets/teamspace-lrm

# Multiple symlinks to same mount
mount_bucket("teamspace-lrm", root_dir="~/project1/data")
mount_bucket("teamspace-lrm", root_dir="~/project2/data")
# -> Both symlinks point to single mount at /tmp/<user>/rclone/teamspace-lrm

# Check status
is_mounted("teamspace-lrm")  # -> True/False

# Unmount (removes mount, cleans up all symlinks)
unmount_bucket("teamspace-lrm")
```

### Default root_dir by platform

```python
def get_default_root():
    if is_lightning_studio():
        return Path.home() / "s3_buckets"
    elif is_slurm():
        return Path("/tmp") / getpass.getuser() / "s3_buckets"
    else:
        return Path.home() / "s3_buckets"
```

---

## CLI

```bash
# Basic usage
mount-bucket teamspace-lrm

# With s3:// prefix (stripped automatically)
mount-bucket s3://teamspace-lrm

# Custom root
mount-bucket teamspace-lrm --root ./data

# Multiple symlinks
mount-bucket teamspace-lrm --root ~/project1/data
mount-bucket teamspace-lrm --root ~/project2/data

# Status
mount-bucket --status teamspace-lrm

# Unmount
unmount-bucket teamspace-lrm

# List all mounts
mount-bucket --list
```

---

## Smart Mounting Logic

### Key Insight
Separate the **mount point** (where rclone actually mounts) from the **symlink** (user-facing path).

```
Mount point:  /tmp/<user>/rclone/<bucket_name>   (singleton per bucket)
Symlinks:     <root_dir>/<bucket_name>           (can have many)
```

### Mounting Flow

```python
def mount_bucket(bucket_name: str, root_dir: str = None):
    bucket_name = bucket_name.replace("s3://", "")
    root_dir = root_dir or get_default_root()

    mount_point = Path(f"/tmp/{getpass.getuser()}/rclone/{bucket_name}")
    symlink_path = Path(root_dir) / bucket_name

    # 1. Check if already mounted at mount_point
    if not is_mountpoint_active(mount_point):
        # Actually mount with rclone
        do_rclone_mount(bucket_name, mount_point)
        poll_until_ready(mount_point)

    # 2. Create/update symlink (always, even if mount existed)
    symlink_path.parent.mkdir(parents=True, exist_ok=True)
    if symlink_path.is_symlink():
        symlink_path.unlink()
    symlink_path.symlink_to(mount_point)

    return symlink_path
```

### Unmounting Flow

```python
def unmount_bucket(bucket_name: str, remove_symlinks: bool = True):
    mount_point = Path(f"/tmp/{getpass.getuser()}/rclone/{bucket_name}")

    # 1. Unmount
    if is_mountpoint_active(mount_point):
        do_unmount(mount_point)

    # 2. Optionally find and remove all symlinks pointing to this mount
    if remove_symlinks:
        # Could scan known locations or maintain a registry
        pass
```

---

## Package Structure

```
harvard-visionlab/buckets/
├── pyproject.toml
├── README.md
├── src/
│   └── visionlab/
│       └── buckets/
│           ├── __init__.py       # Public API
│           ├── mount.py          # Core mount/unmount logic
│           ├── platform.py       # Platform detection, defaults
│           ├── rclone.py         # rclone command wrappers
│           └── cli.py            # Click/argparse CLI
└── tests/
```

### pyproject.toml

```toml
[project]
name = "visionlab-buckets"
version = "0.1.0"
description = "S3 bucket mounting utilities for research workflows"
dependencies = []  # No hard deps - rclone must be installed separately

[project.optional-dependencies]
dev = ["pytest", "ruff"]

[project.scripts]
mount-bucket = "visionlab.buckets.cli:mount_cli"
unmount-bucket = "visionlab.buckets.cli:unmount_cli"

[tool.setuptools.packages.find]
where = ["src"]
```

---

## Files to Migrate from lrm-ssl

| Current file | Destination | Notes |
|--------------|-------------|-------|
| `s3_mount_anywhere.sh` | `src/visionlab/buckets/scripts/` or inline in Python | Could keep as shell or rewrite in pure Python |
| `platform.py` (partial) | `src/visionlab/buckets/platform.py` | Platform detection, `is_mounted()` |
| `s3_auth.py` | Maybe not needed | rclone handles auth via its own config |

---

## Open Questions

1. **Shell script vs pure Python?**
   - Shell: Already works, handles edge cases
   - Python: More portable, easier to test, no bash dependency on Windows
   - Recommendation: Start with shell wrapper, migrate to pure Python later

2. **Symlink registry?**
   - Track all symlinks created so `unmount_bucket` can clean them up
   - Could use a JSON file at `~/.config/visionlab-buckets/symlinks.json`
   - Or just leave symlink cleanup to the user

3. **rclone config management?**
   - Assume user has `~/.config/rclone/rclone.conf` configured
   - Optionally provide helper: `visionlab-buckets configure`

4. **Windows support?**
   - rclone works on Windows but FUSE mounting is different (WinFsp)
   - Defer for now, focus on Linux/macOS

---

## Implementation Order

1. **v0.1**: Basic mount/unmount with shell script wrapper
   - `mount_bucket(bucket_name, root_dir)`
   - `unmount_bucket(bucket_name)`
   - CLI: `mount-bucket`, `unmount-bucket`

2. **v0.2**: Smart symlink handling
   - Multiple symlinks to same mount
   - Symlink registry for cleanup

3. **v0.3**: Pure Python rclone integration
   - Remove shell script dependency
   - Better error handling and logging

4. **Future**:
   - `mount-bucket --watch` for auto-remount on disconnect
   - Integration with fsspec for transparent S3 access
