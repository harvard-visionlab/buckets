"""
Core S3 bucket mounting functionality via rclone.

Provides mount_bucket() and unmount_bucket() functions that handle:
- Platform detection and appropriate mount options
- Single mount point with multiple symlinks
- Proper cleanup on unmount
"""

import subprocess
import time
from pathlib import Path
from typing import Optional

from .platform import (
    check_fuse,
    check_rclone,
    get_default_root,
    get_mount_base,
    get_user,
    is_linux,
    is_macos,
)


class MountError(Exception):
    """Raised when mounting fails."""

    pass


class UnmountError(Exception):
    """Raised when unmounting fails."""

    pass


def _normalize_bucket_name(bucket_name: str) -> str:
    """Strip s3:// prefix if present."""
    return bucket_name.replace("s3://", "").strip("/")


def _is_stale_mount(path: Path) -> bool:
    """
    Check if a path is a stale/zombie FUSE mount.

    A stale mount occurs when the FUSE daemon dies but the mount point
    remains registered. Accessing it gives "Transport endpoint is not connected".
    """
    try:
        path.stat()
        return False
    except OSError as e:
        # ENOTCONN (107) = Transport endpoint is not connected
        return e.errno == 107


def _cleanup_stale_mount(path: Path, verbose: bool = False) -> bool:
    """
    Attempt to clean up a stale FUSE mount.

    Returns True if cleanup was successful or not needed.
    """
    if not _is_stale_mount(path):
        return True

    if verbose:
        print(f"Cleaning up stale mount: {path}")

    if is_linux():
        for cmd in ["fusermount3", "fusermount"]:
            result = subprocess.run(
                [cmd, "-uz", str(path)],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                return True
    elif is_macos():
        result = subprocess.run(
            ["umount", str(path)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return True

    return False


def _is_mountpoint_active(path: Path) -> bool:
    """Check if a path is an active mount point."""
    # First check for stale mount
    if _is_stale_mount(path):
        return False

    if not path.exists():
        return False

    if is_linux():
        result = subprocess.run(
            ["mountpoint", "-q", str(path)],
            capture_output=True,
        )
        return result.returncode == 0

    elif is_macos():
        # macOS: check mount output
        result = subprocess.run(["mount"], capture_output=True, text=True)
        path_str = str(path)
        # macOS may prefix with /private
        return (
            f" on {path_str} " in result.stdout
            or f" on /private{path_str} " in result.stdout
        )

    return False


def _test_s3_access(bucket_name: str, remote_name: str = "s3_remote") -> tuple[bool, str]:
    """Test if we can access the S3 bucket."""
    # Test remote connectivity
    result = subprocess.run(
        ["rclone", "lsd", f"{remote_name}:"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return False, f"Cannot connect to S3 remote '{remote_name}': {result.stderr}"

    # Test bucket access
    result = subprocess.run(
        ["rclone", "lsd", f"{remote_name}:{bucket_name}"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return False, f"Cannot access bucket '{bucket_name}': {result.stderr}"

    return True, "OK"


def _do_mount(
    bucket_name: str,
    mount_point: Path,
    remote_name: str = "s3_remote",
    log_file: Optional[Path] = None,
) -> None:
    """Execute rclone mount command."""
    if log_file is None:
        log_dir = Path("/tmp") / get_user() / "rclone-logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_file = log_dir / f"{bucket_name}.log"

    cmd = [
        "rclone",
        "mount",
        f"{remote_name}:{bucket_name}",
        str(mount_point),
        "--daemon",
        "--vfs-cache-mode",
        "writes",
        "--s3-chunk-size",
        "50M",
        "--s3-upload-cutoff",
        "50M",
        "--buffer-size",
        "50M",
        "--dir-cache-time",
        "30s",
        "--timeout",
        "30s",
        "--contimeout",
        "30s",
        "--log-level",
        "INFO",
        "--log-file",
        str(log_file),
    ]

    # Fully detach daemon: new session + redirect all I/O to devnull
    result = subprocess.run(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    if result.returncode != 0:
        raise MountError(f"rclone mount failed (exit code {result.returncode})")


def _poll_until_mounted(mount_point: Path, timeout: int = 10) -> bool:
    """Wait for mount to become active."""
    for _ in range(timeout):
        if _is_mountpoint_active(mount_point):
            return True
        time.sleep(1)
    return False


def _do_unmount(mount_point: Path) -> None:
    """Unmount a mount point."""
    if is_linux():
        # Try fusermount3 first, fall back to fusermount
        for cmd in ["fusermount3", "fusermount"]:
            result = subprocess.run(
                [cmd, "-uz", str(mount_point)],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                return
        raise UnmountError(f"Failed to unmount {mount_point}")

    elif is_macos():
        result = subprocess.run(
            ["umount", str(mount_point)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise UnmountError(f"Failed to unmount {mount_point}: {result.stderr}")


def is_mounted(bucket_name: str) -> bool:
    """
    Check if a bucket is currently mounted.

    Args:
        bucket_name: Name of the S3 bucket (with or without s3:// prefix)

    Returns:
        True if the bucket is mounted, False otherwise
    """
    bucket_name = _normalize_bucket_name(bucket_name)
    mount_point = get_mount_base() / bucket_name
    return _is_mountpoint_active(mount_point)


def mount_bucket(
    bucket_name: str,
    root_dir: Optional[str | Path] = None,
    remote_name: str = "s3_remote",
    verbose: bool = False,
) -> Path:
    """
    Mount an S3 bucket and create a symlink to it.

    The actual mount happens at /tmp/<user>/rclone/<bucket_name>.
    A symlink is created at <root_dir>/<bucket_name> pointing to the mount.
    Multiple calls with different root_dirs create multiple symlinks to the
    same mount (no duplicate mounts).

    Args:
        bucket_name: Name of the S3 bucket (with or without s3:// prefix)
        root_dir: Directory where the symlink will be created.
                  Defaults to platform-appropriate location.
        remote_name: Name of the rclone remote (default: s3_remote)
        verbose: Print progress messages

    Returns:
        Path to the symlink

    Raises:
        MountError: If mounting fails
    """
    bucket_name = _normalize_bucket_name(bucket_name)

    # Resolve paths
    root_dir = Path(root_dir).expanduser() if root_dir else get_default_root()
    mount_point = get_mount_base() / bucket_name
    symlink_path = root_dir / bucket_name

    if verbose:
        print(f"Bucket:      {bucket_name}")
        print(f"Symlink:     {symlink_path}")
        print(f"Mount point: {mount_point}")

    # Pre-flight checks
    rclone_ok, rclone_msg = check_rclone()
    if not rclone_ok:
        raise MountError(rclone_msg)

    fuse_ok, fuse_msg = check_fuse()
    if not fuse_ok:
        raise MountError(fuse_msg)

    # Test S3 access
    if verbose:
        print("Testing S3 access...")
    s3_ok, s3_msg = _test_s3_access(bucket_name, remote_name)
    if not s3_ok:
        raise MountError(s3_msg)

    # Clean up stale mount if present
    if _is_stale_mount(mount_point):
        if not _cleanup_stale_mount(mount_point, verbose=verbose):
            raise MountError(f"Failed to clean up stale mount at {mount_point}")

    # Create directories
    mount_point.parent.mkdir(parents=True, exist_ok=True)
    mount_point.mkdir(parents=True, exist_ok=True)
    symlink_path.parent.mkdir(parents=True, exist_ok=True)

    # Check for conflicts
    if symlink_path.exists() and not symlink_path.is_symlink():
        raise MountError(f"{symlink_path} exists and is not a symlink")

    if _is_mountpoint_active(symlink_path):
        raise MountError(f"{symlink_path} is already a mount point")

    # Mount if not already mounted
    if not _is_mountpoint_active(mount_point):
        if verbose:
            print("Mounting...")

        # Clean stale files
        for item in mount_point.iterdir():
            try:
                item.unlink()
            except Exception:
                pass

        _do_mount(bucket_name, mount_point, remote_name)

        if not _poll_until_mounted(mount_point):
            log_file = Path("/tmp") / get_user() / "rclone-logs" / f"{bucket_name}.log"
            raise MountError(f"Mount failed. Check logs: {log_file}")

        if verbose:
            print("Mount active")
    else:
        if verbose:
            print(f"Already mounted at {mount_point}")

    # Create/update symlink
    if symlink_path.is_symlink():
        symlink_path.unlink()
    symlink_path.symlink_to(mount_point)

    if verbose:
        print(f"Done: {symlink_path} -> {mount_point}")

    return symlink_path


def unlink_bucket(
    bucket_name: str,
    root_dir: Optional[str | Path] = None,
    verbose: bool = False,
) -> bool:
    """
    Remove a symlink to a bucket without unmounting.

    Use this to remove a symlink from a specific location while keeping
    the mount active (e.g., if you have symlinks in multiple places).

    Args:
        bucket_name: Name of the S3 bucket (with or without s3:// prefix)
        root_dir: Directory containing the symlink. Defaults to cwd.
        verbose: Print progress messages

    Returns:
        True if symlink was removed, False if it didn't exist
    """
    bucket_name = _normalize_bucket_name(bucket_name)
    root_dir = Path(root_dir).expanduser() if root_dir else get_default_root()
    symlink_path = root_dir / bucket_name

    if not symlink_path.is_symlink():
        if verbose:
            print(f"No symlink at: {symlink_path}")
        return False

    symlink_path.unlink()
    if verbose:
        print(f"Removed symlink: {symlink_path}")
    return True


def unmount_bucket(bucket_name: str, remove_symlinks: bool = True, verbose: bool = False) -> None:
    """
    Unmount an S3 bucket.

    Args:
        bucket_name: Name of the S3 bucket (with or without s3:// prefix)
        remove_symlinks: If True, remove symlinks pointing to the mount
        verbose: Print progress messages

    Raises:
        UnmountError: If unmounting fails
    """
    bucket_name = _normalize_bucket_name(bucket_name)
    mount_point = get_mount_base() / bucket_name

    if not _is_mountpoint_active(mount_point):
        if verbose:
            print(f"Not mounted: {bucket_name}")
        return

    if verbose:
        print(f"Unmounting {mount_point}...")

    _do_unmount(mount_point)

    if verbose:
        print(f"Unmounted: {bucket_name}")

    # Optionally clean up known symlink locations
    if remove_symlinks:
        default_symlink = get_default_root() / bucket_name
        if default_symlink.is_symlink():
            if verbose:
                print(f"Removing symlink: {default_symlink}")
            default_symlink.unlink()


def list_mounts() -> list[dict]:
    """
    List all active bucket mounts for the current user.

    Returns:
        List of dicts with 'bucket', 'mount_point', and 'active' keys
    """
    mount_base = get_mount_base()
    mounts = []

    if not mount_base.exists():
        return mounts

    for item in mount_base.iterdir():
        if item.is_dir():
            mounts.append(
                {
                    "bucket": item.name,
                    "mount_point": item,
                    "active": _is_mountpoint_active(item),
                }
            )

    return mounts


def get_mount_status(bucket_name: str) -> dict:
    """
    Get detailed status for a bucket mount.

    Returns:
        Dict with mount status information
    """
    bucket_name = _normalize_bucket_name(bucket_name)
    mount_point = get_mount_base() / bucket_name
    default_symlink = get_default_root() / bucket_name

    return {
        "bucket": bucket_name,
        "mount_point": mount_point,
        "is_mounted": _is_mountpoint_active(mount_point),
        "default_symlink": default_symlink,
        "symlink_exists": default_symlink.is_symlink(),
    }
