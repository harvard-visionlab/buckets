"""
Command-line interface for bucket mounting.

Provides mount-bucket and unmount-bucket commands.
Uses argparse to avoid external dependencies.
"""

import argparse
import sys

from .mount import (
    MountError,
    UnmountError,
    get_mount_status,
    list_mounts,
    mount_bucket,
    unmount_bucket,
)
from .platform import get_default_root, get_platform_name


def mount_cli() -> None:
    """CLI entry point for mount-bucket command."""
    parser = argparse.ArgumentParser(
        prog="mount-bucket",
        description="Mount an S3 bucket via rclone",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  mount-bucket teamspace-lrm
  mount-bucket s3://teamspace-lrm
  mount-bucket teamspace-lrm --root ./data
  mount-bucket --list
  mount-bucket --status teamspace-lrm
        """,
    )

    parser.add_argument(
        "bucket",
        nargs="?",
        help="S3 bucket name (with or without s3:// prefix)",
    )
    parser.add_argument(
        "--root",
        "-r",
        metavar="DIR",
        help=f"Directory for symlink (default: {get_default_root()})",
    )
    parser.add_argument(
        "--remote",
        default="s3_remote",
        metavar="NAME",
        help="rclone remote name (default: s3_remote)",
    )
    parser.add_argument(
        "--list",
        "-l",
        action="store_true",
        help="List all mounted buckets",
    )
    parser.add_argument(
        "--status",
        "-s",
        action="store_true",
        help="Show status for the specified bucket",
    )
    parser.add_argument(
        "--quiet",
        "-q",
        action="store_true",
        help="Suppress progress messages",
    )

    args = parser.parse_args()

    # Handle --list
    if args.list:
        mounts = list_mounts()
        if not mounts:
            print("No buckets mounted")
            return

        print(f"{'Bucket':<30} {'Status':<10} Mount Point")
        print("-" * 70)
        for m in mounts:
            status = "active" if m["active"] else "stale"
            print(f"{m['bucket']:<30} {status:<10} {m['mount_point']}")
        return

    # Require bucket name for other operations
    if not args.bucket:
        parser.print_help()
        sys.exit(1)

    # Handle --status
    if args.status:
        status = get_mount_status(args.bucket)
        print(f"Bucket:        {status['bucket']}")
        print(f"Mount point:   {status['mount_point']}")
        print(f"Mounted:       {'yes' if status['is_mounted'] else 'no'}")
        print(f"Symlink:       {status['default_symlink']}")
        print(f"Symlink exists: {'yes' if status['symlink_exists'] else 'no'}")
        return

    # Mount the bucket
    try:
        symlink = mount_bucket(
            args.bucket,
            root_dir=args.root,
            remote_name=args.remote,
            verbose=not args.quiet,
        )
        if not args.quiet:
            print(f"\nBucket available at: {symlink}")
    except MountError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def unmount_cli() -> None:
    """CLI entry point for unmount-bucket command."""
    parser = argparse.ArgumentParser(
        prog="unmount-bucket",
        description="Unmount an S3 bucket",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  unmount-bucket teamspace-lrm
  unmount-bucket --all
        """,
    )

    parser.add_argument(
        "bucket",
        nargs="?",
        help="S3 bucket name to unmount",
    )
    parser.add_argument(
        "--all",
        "-a",
        action="store_true",
        help="Unmount all buckets",
    )
    parser.add_argument(
        "--keep-symlinks",
        action="store_true",
        help="Don't remove symlinks when unmounting",
    )
    parser.add_argument(
        "--quiet",
        "-q",
        action="store_true",
        help="Suppress progress messages",
    )

    args = parser.parse_args()

    # Handle --all
    if args.all:
        mounts = list_mounts()
        if not mounts:
            print("No buckets to unmount")
            return

        for m in mounts:
            if m["active"]:
                try:
                    unmount_bucket(
                        m["bucket"],
                        remove_symlinks=not args.keep_symlinks,
                        verbose=not args.quiet,
                    )
                except UnmountError as e:
                    print(f"Error unmounting {m['bucket']}: {e}", file=sys.stderr)
        return

    # Require bucket name
    if not args.bucket:
        parser.print_help()
        sys.exit(1)

    try:
        unmount_bucket(
            args.bucket,
            remove_symlinks=not args.keep_symlinks,
            verbose=not args.quiet,
        )
    except UnmountError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def info_cli() -> None:
    """Show environment and configuration info."""
    from .platform import check_fuse, check_rclone

    print("visionlab.buckets environment info")
    print("=" * 40)
    print(f"Platform:       {get_platform_name()}")
    print(f"Default root:   {get_default_root()}")

    rclone_ok, rclone_msg = check_rclone()
    print(f"rclone:         {'OK' if rclone_ok else rclone_msg}")

    fuse_ok, fuse_msg = check_fuse()
    print(f"FUSE:           {'OK' if fuse_ok else fuse_msg}")

    mounts = list_mounts()
    print(f"Active mounts:  {sum(1 for m in mounts if m['active'])}")


if __name__ == "__main__":
    mount_cli()
