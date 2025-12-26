#!/bin/bash
#
# s3_connect_lightning.sh
# Simplified S3 mount for Lightning Studio (single-node, ephemeral)
#
# Usage:
#   ./s3_connect_lightning.sh <mount_path> <bucket_name>
#   ./s3_connect_lightning.sh ./s3_buckets teamspace-lrm
#
# To unmount:
#   fusermount3 -uz /tmp/$USER/rclone/<bucket_name>
#   rm -f ./s3_buckets/<bucket_name>

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <mount_path> <bucket_name>"
  echo "Example: $0 ./s3_buckets teamspace-lrm"
  exit 1
fi

MOUNT_PATH="$(eval echo "$1")"
BUCKET_NAME="$2"

# Paths
NODE_LOCAL_MP="/tmp/$USER/rclone/${BUCKET_NAME}"
LOG_DIR="/tmp/$USER/rclone-logs"
LOG_FILE="${LOG_DIR}/${BUCKET_NAME}.log"
LINK_PATH="${MOUNT_PATH%/}/${BUCKET_NAME}"

echo "Bucket:        ${BUCKET_NAME}"
echo "Symlink:       ${LINK_PATH}"
echo "Mount point:   ${NODE_LOCAL_MP}"

# Pre-flight checks
command -v rclone >/dev/null 2>&1 || { echo "ERROR: rclone not found"; exit 1; }
[ -e /dev/fuse ] || { echo "ERROR: /dev/fuse not present"; exit 1; }
[ -f ~/.config/rclone/rclone.conf ] || { echo "ERROR: Missing rclone config"; exit 1; }

echo "Testing S3 access..."
rclone lsd s3_remote: >/dev/null 2>&1 || { echo "ERROR: Cannot access S3"; exit 1; }
rclone lsd "s3_remote:${BUCKET_NAME}" >/dev/null 2>&1 || { echo "ERROR: Cannot access bucket '${BUCKET_NAME}'"; exit 1; }

mkdir -p "$(dirname "$LINK_PATH")" "$LOG_DIR" "$NODE_LOCAL_MP"

# Check for existing mount/symlink issues
if mountpoint -q "$LINK_PATH" 2>/dev/null; then
  echo "ERROR: ${LINK_PATH} is already a mountpoint. Unmount first."
  exit 1
fi

if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
  echo "ERROR: ${LINK_PATH} exists and is not a symlink"
  exit 1
fi

# If already mounted, just refresh symlink
if mountpoint -q "$NODE_LOCAL_MP" 2>/dev/null; then
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
    if mountpoint -q "$NODE_LOCAL_MP" 2>/dev/null; then
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
echo "  fusermount3 -uz '${NODE_LOCAL_MP}' && rm -f '${LINK_PATH}'"