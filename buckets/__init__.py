"""
visionlab.buckets - S3 bucket mounting utilities for research workflows.

Mount S3 buckets via rclone with smart symlink handling across platforms
(Linux, macOS, SLURM, Lightning Studio).

Basic usage:
    from visionlab.buckets import mount_bucket, unmount_bucket, is_mounted

    mount_bucket("teamspace-lrm")
    mount_bucket("teamspace-lrm", root_dir="./data")
    is_mounted("teamspace-lrm")
    unmount_bucket("teamspace-lrm")
"""

from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("visionlab-buckets")
except PackageNotFoundError:
    __version__ = "0.0.0-dev"

# Public API
from .mount import (
    MountError,
    UnmountError,
    get_mount_status,
    is_mounted,
    list_mounts,
    mount_bucket,
    unmount_bucket,
)
from .platform import (
    get_default_root,
    get_platform_name,
    has_gpu,
    is_lightning_studio,
    is_linux,
    is_macos,
    is_slurm,
)

__all__ = [
    # Core API
    "mount_bucket",
    "unmount_bucket",
    "is_mounted",
    "list_mounts",
    "get_mount_status",
    # Exceptions
    "MountError",
    "UnmountError",
    # Platform detection
    "is_lightning_studio",
    "is_slurm",
    "is_linux",
    "is_macos",
    "has_gpu",
    "get_platform_name",
    "get_default_root",
]
