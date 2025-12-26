#!/bin/bash
#
# One-time setup:
# mkdir -p ~/.config/rclone
# nano ~/.config/rclone/rclone.conf
# [s3_remote]
# type = s3
# provider = AWS
# env_auth = true
# region = us-east-1
# acl = public-read
#
# Examples:
# chmod u+x s3_bucket_mount.sh
# ./s3_bucket_mount.sh ./s3_buckets teamspace-lrm
#
# To unmount later (on the SAME NODE):
#   /bin/umount -l /tmp/$USER/rclone/$(hostname -s)/${SLURM_JOB_ID:-interactive}/teamspace-lrm
#   # or: fusermount3 -uz <that path>  (or: fusermount -uz)
# Then remove the symlink if desired:
#   rm -f ./s3_buckets/teamspace-lrm
#
# Note: mounts are per-node. Run unmounts on the same node.

set -euo pipefail

# ---- Args & usage -----------------------------------------------------------
if [ $# -ne 2 ]; then
  echo ""
  echo "==> s3_bucket_mount.sh usage:"
  echo ""
  echo "Usage: $0 <mount_path> <bucket_name>"
  echo "Example: $0 ./s3_buckets teamspace-lrm"
  exit 1
fi

MOUNT_PATH="$1"
BUCKET_NAME="$2"

# Expand ~ in MOUNT_PATH
MOUNT_PATH=$(eval echo "$MOUNT_PATH")

# Basic deps
command -v rclone >/dev/null 2>&1 || { echo "ERROR: rclone not found in PATH"; exit 1; }
[ -e /dev/fuse ] || { echo "ERROR: /dev/fuse not present on this node"; exit 1; }

# Node-local mountpoint (per-host, per-job or 'interactive')
HOST_SHORT="$(hostname -s || echo node)"
JOB_TAG="${SLURM_JOB_ID:-interactive}"
NODE_LOCAL_MP="/tmp/$USER/rclone/${HOST_SHORT}/${JOB_TAG}/${BUCKET_NAME}"

# Keep logs OUTSIDE the mountpoint so they remain visible even if mount fails
LOG_ROOT="/tmp/$USER/rclone-logs/${HOST_SHORT}/${JOB_TAG}/${BUCKET_NAME}"
LOG_FILE="${LOG_ROOT}/mount.log"
mkdir -p "$LOG_ROOT"

# Symlink location in your repo
LINK_PATH="${MOUNT_PATH%/}/${BUCKET_NAME}"

echo "Starting rclone setup..."
echo "Bucket:        ${BUCKET_NAME}"
echo "Repo symlink:  ${LINK_PATH}"
echo "Node-local MP: ${NODE_LOCAL_MP}"
echo "Log file:      ${LOG_FILE}"

# ---- Pre-flight checks -------------------------------------------------------
# Ensure rclone config exists
if [ ! -f ~/.config/rclone/rclone.conf ]; then
  echo "ERROR: Missing rclone config at ~/.config/rclone/rclone.conf"
  echo "See setup instructions at the top of this script."
  exit 1
fi

# Test AWS creds and listable remote
echo "Testing S3 access..."
if ! rclone lsd s3_remote: > /dev/null 2>&1; then
  echo "ERROR: Cannot access S3 with current credentials (rclone lsd s3_remote: failed)."
  exit 1
fi

# Verify bucket exists
echo "Verifying bucket access..."
if ! rclone lsd "s3_remote:${BUCKET_NAME}" > /dev/null 2>&1; then
  echo "ERROR: Cannot access bucket '${BUCKET_NAME}'. Check name/permissions."
  exit 1
fi

# Ensure parent dir of LINK_PATH exists (we create *parent*, not LINK itself)
mkdir -p "$(dirname "$LINK_PATH")"

# Refuse to proceed if LINK_PATH is currently a mountpoint (old direct mount)
if mountpoint -q "$LINK_PATH" 2>/dev/null; then
  echo "ERROR: ${LINK_PATH} is a mountpoint already. Unmount it first."
  echo "Hint: fusermount3 -uz '$LINK_PATH'  (or /bin/umount -l '$LINK_PATH')"
  exit 1
fi

# If LINK_PATH exists as a real directory (not a symlink), don't clobber it
if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
  echo "ERROR: ${LINK_PATH} exists and is not a symlink."
  echo "Please move/remove it or unmount any stale mount before proceeding."
  exit 1
fi

# ---- Ensure node-local mountpoint exists and is EMPTY ------------------------
mkdir -p "$NODE_LOCAL_MP"

# If it's not already a mountpoint, make sure it's empty (fixes "not empty" error)
if ! mountpoint -q "$NODE_LOCAL_MP" 2>/dev/null; then
  # Only auto-clean under /tmp/$USER/rclone/* for safety
  case "$NODE_LOCAL_MP" in
    "/tmp/$USER/rclone/"*) ;;
    *) echo "ERROR: Refusing to clean non-/tmp path: $NODE_LOCAL_MP"; exit 1 ;;
  esac

  # If directory contains anything (including dotfiles), nuke contents
  if [ -n "$(ls -A "$NODE_LOCAL_MP" 2>/dev/null || true)" ]; then
    echo "INFO: ${NODE_LOCAL_MP} not empty; cleaning stale files from previous run…"
    # Remove all entries safely (files, dirs, dotfiles)
    rm -rf -- "$NODE_LOCAL_MP"/* "$NODE_LOCAL_MP"/.[!.]* "$NODE_LOCAL_MP"/..?* 2>/dev/null || true
  fi
fi

# If already mounted there, we’re done—just (re)point the symlink
if mountpoint -q "$NODE_LOCAL_MP" 2>/dev/null; then
  echo "INFO: Node-local mount already active at ${NODE_LOCAL_MP}"
else
  # ---- Do the mount (loud + logged) -----------------------------------------
  echo "Mounting S3 bucket '${BUCKET_NAME}' to node-local path..."
  set +e
  rclone mount "s3_remote:${BUCKET_NAME}" "$NODE_LOCAL_MP" \
    --daemon \
    --vfs-cache-mode writes \
    --s3-chunk-size 50M \
    --s3-upload-cutoff 50M \
    --buffer-size 50M \
    --dir-cache-time 30s \
    --timeout 30s \
    --contimeout 30s \
    --log-level DEBUG \
    --log-file "${LOG_FILE}"
  RC=$?
  set -e

  if [ $RC -ne 0 ]; then
    echo "❌ rclone mount exited with code $RC"
    echo "----- rclone log (tail) ----------------------------------------"
    tail -n 120 "${LOG_FILE}" || true
    echo "----------------------------------------------------------------"
    exit $RC
  fi

  echo "Waiting for node-local mount to become active..."
  for i in {1..20}; do
    if mountpoint -q "$NODE_LOCAL_MP" 2>/dev/null; then
      echo "✅ Node-local mount is active: $NODE_LOCAL_MP"
      break
    fi
    if [ $i -eq 20 ]; then
      echo "❌ S3 mount did not come up at ${NODE_LOCAL_MP}"
      echo "----- rclone log (tail) ----------------------------------------"
      tail -n 200 "${LOG_FILE}" || true
      echo "----------------------------------------------------------------"
      exit 1
    fi
    sleep 1
  done

  echo "Mount entry (grep):"
  mount | grep -E "fuse\.rclone.*${BUCKET_NAME}" || true
fi

# ---- Create/refresh the symlink in your repo --------------------------------
ln -sfn "$NODE_LOCAL_MP" "$LINK_PATH"

# Verify the link resolves
if [ "$(readlink -f "$LINK_PATH" || true)" != "$(readlink -f "$NODE_LOCAL_MP" || true)" ]; then
  echo "ERROR: Symlink at ${LINK_PATH} did not resolve to ${NODE_LOCAL_MP}"
  exit 1
fi

echo ""
echo "✅ Setup completed successfully!"
echo "S3 bucket '${BUCKET_NAME}' is mounted node-locally at:"
echo "  ${NODE_LOCAL_MP}"
echo "and symlinked into your repo at:"
echo "  ${LINK_PATH}"
echo ""
echo "To UNMOUNT later on this SAME NODE:"
echo "  /bin/umount -l -- '${NODE_LOCAL_MP}'"
echo "  # or: fusermount3 -uz -- '${NODE_LOCAL_MP}'"
echo "Then remove the symlink if desired:"
echo "  rm -f -- '${LINK_PATH}'"
echo ""
echo "Log file:"
echo "  ${LOG_FILE}"
