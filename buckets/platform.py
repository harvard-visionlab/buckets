"""
Platform detection utilities with zero external dependencies.

Detects environment (Lightning Studio, SLURM, local) without importing
torch, lightning, or other heavy packages.
"""

import getpass
import os
import shutil
import subprocess
import sys
from pathlib import Path


def is_lightning_studio() -> bool:
    """
    Detect Lightning Studio environment via env vars and filesystem.

    No lightning import needed - uses environment markers that Lightning
    sets automatically.
    """
    # Check Lightning-specific environment variables
    lightning_env_vars = [
        "LIGHTNING_CLOUDSPACE_HOST",
        "LIGHTNING_CLOUD_PROJECT_ID",
        "LIGHTNING_CLUSTER_ID",
        "LIGHTNING_CLOUD_URL",
    ]
    if any(os.environ.get(var) for var in lightning_env_vars):
        return True

    # Check for /teamspace directory (Lightning Studio workspace)
    if Path("/teamspace").is_dir():
        return True

    return False


def is_slurm() -> bool:
    """Detect if running in a SLURM job environment."""
    return os.environ.get("SLURM_JOB_ID") is not None


def is_slurm_login_node() -> bool:
    """Detect if on a SLURM cluster login node (not in a job)."""
    # On FASRC, login nodes have squeue available but no SLURM_JOB_ID
    if is_slurm():
        return False
    return shutil.which("squeue") is not None


def is_macos() -> bool:
    """Detect macOS."""
    return sys.platform == "darwin"


def is_linux() -> bool:
    """Detect Linux."""
    return sys.platform.startswith("linux")


def has_gpu() -> bool:
    """
    Check for GPU availability without importing torch.

    Uses nvidia-smi and /dev/nvidia* checks.
    """
    # Method 1: Check nvidia-smi
    if shutil.which("nvidia-smi"):
        try:
            result = subprocess.run(
                ["nvidia-smi", "-L"],
                capture_output=True,
                timeout=5,
            )
            if result.returncode == 0 and b"GPU" in result.stdout:
                return True
        except (subprocess.TimeoutExpired, OSError):
            pass

    # Method 2: Check /dev/nvidia* devices
    if is_linux():
        nvidia_devices = list(Path("/dev").glob("nvidia*"))
        if nvidia_devices:
            return True

    return False


def get_platform_name() -> str:
    """Get a human-readable platform name."""
    if is_lightning_studio():
        return "lightning"
    elif is_slurm():
        return "slurm"
    elif is_slurm_login_node():
        return "slurm-login"
    elif is_macos():
        return "macos"
    elif is_linux():
        if has_gpu():
            return "linux-gpu"
        return "linux"
    else:
        return "unknown"


def get_default_root() -> Path:
    """
    Get default root directory for bucket symlinks.

    Defaults to current working directory for all platforms.
    User can override with --root flag.
    """
    return Path.cwd()


def get_mount_base() -> Path:
    """
    Get base directory for actual rclone mount points.

    Mounts go in /tmp/<user>/rclone/<bucket_name>
    Symlinks point from root_dir to these mounts.
    """
    return Path("/tmp") / getpass.getuser() / "rclone"


def get_user() -> str:
    """Get current username."""
    return os.environ.get("USER", getpass.getuser())


def check_rclone() -> tuple[bool, str]:
    """
    Check if rclone is available and configured.

    Returns:
        (is_ready, message)
    """
    # Check rclone binary
    if not shutil.which("rclone"):
        return False, "rclone not found in PATH"

    # Check rclone config
    config_path = Path.home() / ".config" / "rclone" / "rclone.conf"
    if not config_path.exists():
        return False, f"rclone config not found at {config_path}"

    return True, "rclone ready"


def check_fuse() -> tuple[bool, str]:
    """
    Check if FUSE is available for mounting.

    Returns:
        (is_ready, message)
    """
    if is_linux():
        if Path("/dev/fuse").exists():
            return True, "FUSE available"
        return False, "/dev/fuse not found - install fuse3"

    elif is_macos():
        # Check for FUSE-T (preferred kext-less implementation)
        if Path("/Library/Frameworks/fuse_t.framework").is_dir():
            return True, "FUSE-T available"
        # Check for macFUSE (older)
        if Path("/Library/Frameworks/macFUSE.framework").is_dir():
            return True, "macFUSE available"
        return False, "FUSE-T not installed - brew install --cask fuse-t"

    return False, f"Unsupported platform: {sys.platform}"
