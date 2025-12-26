#!/bin/bash
#
# s3_connect.sh
# S3 mount script for Linux (Lightning Studio, DEVBOX, SLURM) and macOS
#
# Usage:
#   ./s3_connect.sh <mount_path> <bucket_name>
#   ./s3_connect_any.sh ./s3_buckets teamspace-lrm

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <mount_path> <bucket_name>"
  echo "Example: $0 ./s3_buckets teamspace-lrm"
  exit 1
fi

MOUNT_PATH="$(eval echo "$1")"
BUCKET_NAME="$2"
USER="${USER:-$(whoami)}"

# Platform detection
OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *)      echo "ERROR: Unsupported OS: $OS"; exit 1 ;;
esac

# Paths
NODE_LOCAL_MP="/tmp/$USER/rclone/${BUCKET_NAME}"
LOG_DIR="/tmp/$USER/rclone-logs"
LOG_FILE="${LOG_DIR}/${BUCKET_NAME}.log"
LINK_PATH="${MOUNT_PATH%/}/${BUCKET_NAME}"

echo "Bucket:        ${BUCKET_NAME}"
echo "Symlink:       ${LINK_PATH}"
echo "Mount point:   ${NODE_LOCAL_MP}"
echo "Platform:      ${PLATFORM}"

# Pre-flight checks
command -v rclone >/dev/null 2>&1 || { echo "ERROR: rclone not found"; exit 1; }
[ -f ~/.config/rclone/rclone.conf ] || { echo "ERROR: Missing rclone config"; exit 1; }

# Platform-specific FUSE check
if [ "$PLATFORM" = "linux" ]; then
  [ -e /dev/fuse ] || { echo "ERROR: /dev/fuse not present"; exit 1; }
else
  # macOS: check for FUSE-T framework
  [ -d /Library/Frameworks/fuse_t.framework ] || { echo "ERROR: FUSE-T not installed"; exit 1; }
fi

echo "Testing S3 access..."
rclone lsd s3_remote: >/dev/null 2>&1 || { echo "ERROR: Cannot access S3"; exit 1; }
rclone lsd "s3_remote:${BUCKET_NAME}" >/dev/null 2>&1 || { echo "ERROR: Cannot access bucket '${BUCKET_NAME}'"; exit 1; }

mkdir -p "$(dirname "$LINK_PATH")" "$LOG_DIR" "$NODE_LOCAL_MP"

# Platform-specific mountpoint check
is_mounted() {
  local check_path="$1"
  if [ "$PLATFORM" = "linux" ]; then
    mountpoint -q "$check_path" 2>/dev/null
  else
    # macOS: check if mount appears with resolved path
    mount | grep -q " on /private${check_path} " || mount | grep -q " on ${check_path} "
  fi
}

# Check for existing mount/symlink issues
if is_mounted "$LINK_PATH"; then
  echo "ERROR: ${LINK_PATH} is already a mountpoint. Unmount first."
  exit 1
fi

if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
  echo "ERROR: ${LINK_PATH} exists and is not a symlink"
  exit 1
fi

# If already mounted, just refresh symlink
if is_mounted "$NODE_LOCAL_MP"; then
  echo "Mount already active at ${NODE_LOCAL_MP}"
else
  # Clean stale files if not mounted
  rm -rf "${NODE_LOCAL_MP:?}"/* 2>/dev/null || true

  echo "Mounting..."
  rclone mount "s3_remote:${BUCKET_NAME}" "$NODE_LOCAL_MP" \
    --daemon \
    --vfs-cache-mode writes \
    --s3-chunk-size 50M \
    --s3-upload-cutoff 50M \
    --buffer-size 50M \
    --dir-cache-time 30s \
    --timeout 30s \
    --contimeout 30s \
    --log-level INFO \
    --log-file "${LOG_FILE}"

  # Wait for mount
  for i in {1..10}; do
    if is_mounted "$NODE_LOCAL_MP"; then
      echo "✅ Mount active"
      break
    fi
    [ $i -eq 10 ] && { echo "❌ Mount failed. Check: ${LOG_FILE}"; tail -50 "$LOG_FILE"; exit 1; }
    sleep 1
  done
fi

# Create symlink
ln -sfn "$NODE_LOCAL_MP" "$LINK_PATH"

echo ""
echo "✅ Done: ${LINK_PATH} → ${NODE_LOCAL_MP}"
echo ""
echo "Unmount with:"
if [ "$PLATFORM" = "linux" ]; then
  echo "  fusermount3 -uz '${NODE_LOCAL_MP}' && rm -f '${LINK_PATH}'"
else
  echo "  umount '${NODE_LOCAL_MP}' && rm -f '${LINK_PATH}'"
fi