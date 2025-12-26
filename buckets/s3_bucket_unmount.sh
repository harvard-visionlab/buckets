#!/bin/bash
#
# Usage:
#   ./s3_bucket_unmount.sh <mount_path> <bucket_name> [--all-jobs]
#
# Examples:
#   ./s3_bucket_unmount.sh ./s3_buckets teamspace-lrm
#   ./s3_bucket_unmount.sh ./s3_buckets teamspace-lrm --all-jobs
#
# Notes:
# - Unmounts are per-node. Run this on the SAME NODE where the mount exists.
# - By default it targets the node-local path for the current job:
#     /tmp/$USER/rclone/$(hostname -s)/${SLURM_JOB_ID:-interactive}/<bucket>
#   Use --all-jobs to unmount any job-tagged mounts for this bucket on this host.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo ""
  echo "==> s3_bucket_unmount.sh usage:"
  echo ""
  echo "Usage: $0 <mount_path> <bucket_name> [--all-jobs]"
  echo "Example: $0 ./s3_buckets teamspace-lrm"
  exit 1
fi

MOUNT_PATH="$1"
BUCKET_NAME="$2"
ALL_JOBS="${3:-}"

# Expand ~ in MOUNT_PATH
MOUNT_PATH=$(eval echo "$MOUNT_PATH")

# Do not keep the mount busy
cd ~

HOST_SHORT="$(hostname -s || echo node)"
JOB_TAG="${SLURM_JOB_ID:-interactive}"

# Candidate node-local mountpoints
declare -a CANDIDATES=()

if [ "$ALL_JOBS" = "--all-jobs" ]; then
  # Find all job-tagged mountpoints for this bucket on this host
  while IFS= read -r -d '' p; do
    CANDIDATES+=("$p")
  done < <(find "/tmp/$USER/rclone/${HOST_SHORT}" -maxdepth 3 -type d -name "${BUCKET_NAME}" -print0 2>/dev/null || true)
else
  CANDIDATES+=("/tmp/$USER/rclone/${HOST_SHORT}/${JOB_TAG}/${BUCKET_NAME}")
fi

# Always unique the list
if [ ${#CANDIDATES[@]} -gt 0 ]; then
  mapfile -t CANDIDATES < <(printf "%s\n" "${CANDIDATES[@]}" | awk '!x[$0]++')
fi

LINK_PATH="${MOUNT_PATH%/}/${BUCKET_NAME}"

echo "Unmounting bucket:   ${BUCKET_NAME}"
echo "Repo symlink path:   ${LINK_PATH}"
echo "Host:                ${HOST_SHORT}"
if [ "$ALL_JOBS" = "--all-jobs" ]; then
  echo "Mode:                all jobs on this host"
else
  echo "Job tag:             ${JOB_TAG}"
fi
echo ""

# Kill rclone mount processes for this bucket (safe even if none found)
if command -v pkill >/dev/null 2>&1; then
  pkill -f "rclone mount .*s3_remote:${BUCKET_NAME}" 2>/dev/null || true
fi

# Helper to unmount one path
unmount_one() {
  local MP="$1"
  [ -n "$MP" ] || return 0

  if mountpoint -q "$MP" 2>/dev/null; then
    echo "-> Unmounting: $MP"
    # Try kernel lazy unmount first, then FUSE, treating "already gone" as success
    if /bin/umount -l -- "$MP" 2>/dev/null \
      || (command -v fusermount3 >/dev/null 2>&1 && fusermount3 -uz -- "$MP" 2>/dev/null) \
      || (command -v fusermount  >/dev/null 2>&1 && fusermount  -uz -- "$MP" 2>/dev/null); then
      echo "   ✅ unmounted"
    else
      # Re-check; if it’s not a mount anymore, call it success
      if mountpoint -q "$MP" 2>/dev/null; then
        echo "   ❌ still mounted (try closing any shells or processes in that path)"
      else
        echo "   ✅ unmounted (already gone)"
      fi
    fi
  else
    echo "-> Not a mountpoint (ok): $MP"
  fi

  # Clean up empty /tmp/$USER/rclone/* dirs (safe only under that prefix)
  case "$MP" in
    "/tmp/$USER/rclone/"*)
      rmdir "$MP" 2>/dev/null || true
      rmdir "$(dirname "$MP")" 2>/dev/null || true
      rmdir "$(dirname "$(dirname "$MP")")" 2>/dev/null || true
      ;;
  esac
}

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "No candidate node-local mountpoints found for this host/bucket."
else
  for MP in "${CANDIDATES[@]}"; do
    unmount_one "$MP"
  done
fi

echo ""

# Remove the repo symlink if present
if [ -L "$LINK_PATH" ]; then
  echo "Removing symlink: $LINK_PATH"
  rm -f -- "$LINK_PATH"
elif [ -e "$LINK_PATH" ]; then
  echo "WARNING: '$LINK_PATH' exists but is not a symlink. Not removing."
else
  echo "Symlink not present (ok): $LINK_PATH"
fi

echo ""
echo "Remaining rclone mounts for this bucket on this host (if any):"
mount | grep -E "fuse\.rclone.*${BUCKET_NAME}" || echo "  none"
echo ""
echo "✅ Cleanup complete."
