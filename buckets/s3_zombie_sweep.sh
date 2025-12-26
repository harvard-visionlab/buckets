#!/bin/bash
# s3_zombie_sweep.sh
#
# Scan the CURRENT NODE for rclone FUSE mounts for this user, report status,
# and optionally clean up orphaned/zombie mounts (fix mode).
#
# Usage:
#   ./s3_zombie_sweep.sh            # report (default)
#   ./s3_zombie_sweep.sh report     # report only
#   ./s3_zombie_sweep.sh fix        # kill orphan rclone processes and lazy-unmount

set -euo pipefail

MODE="${1:-report}"
HOST_SHORT="$(hostname -s || echo node)"
USER_NAME="$(id -un)"
USER_ID="$(id -u)"

echo "Host: ${HOST_SHORT}  User: ${USER_NAME} (UID ${USER_ID})"
echo "Mode: ${MODE}"
echo

# list: remote and mountpoint for fuse.rclone lines
# mount output looks like: "<remote> on <mp> type fuse.rclone (…)"
mapfile -t MOUNTS < <(mount | awk '/type fuse\.rclone/ {print $1"||"$3}')

if [ ${#MOUNTS[@]} -eq 0 ]; then
  echo "No rclone FUSE mounts found on this node."
  exit 0
fi

printf "%-42s  %-64s  %-s\n" "REMOTE" "MOUNTPOINT" "STATUS"
printf "%-42s  %-64s  %-s\n" "------" "----------" "------"

# helper: unmount one mountpoint safely
unmount_one() {
  local mp="$1"
  # prefer kernel lazy unmount, then fall back to fusermount
  /bin/umount -l -- "$mp" 2>/dev/null \
    || (command -v fusermount3 >/dev/null 2>&1 && fusermount3 -uz -- "$mp" 2>/dev/null) \
    || (command -v fusermount  >/dev/null 2>&1 && fusermount  -uz -- "$mp" 2>/dev/null) \
    || return 1

  # Clean empty /tmp/$USER/rclone dirs (safe guard)
  case "$mp" in
    "/tmp/$USER/rclone/"*)
      rmdir "$mp" 2>/dev/null || true
      rmdir "$(dirname "$mp")" 2>/dev/null || true
      rmdir "$(dirname "$(dirname "$mp")")" 2>/dev/null || true
      ;;
  esac
  return 0
}

for line in "${MOUNTS[@]}"; do
  remote="${line%%||*}"
  mp="${line##*||}"
  # bucket name is the part after the first colon (handles the {….} suffix)
  bucket="${remote#*:}"

  # Find any rclone mount process that mentions this bucket (best-effort)
  # (pgrep -fa prints "pid cmd…"; we only need to know if anything matches)
  if pgrep -fa "rclone mount .*${bucket}(\$|[^[:alnum:]_-])" >/dev/null 2>&1; then
    status="OK (owned by rclone)"
  else
    status="ORPHAN (no rclone pid)"
  fi

  printf "%-42s  %-64s  %-s\n" "$remote" "$mp" "$status"

  if [ "$MODE" = "fix" ] && [ "$status" != "OK (owned by rclone)" ]; then
    # Try killing any stale rclone for this bucket anyway, then lazy-unmount
    pkill -f "rclone mount .*${bucket}(\$|[^[:alnum:]_-])" 2>/dev/null || true
    if mountpoint -q "$mp" 2>/dev/null; then
      if unmount_one "$mp"; then
        printf "  -> cleaned: %s\n" "$mp"
      else
        printf "  -> FAILED to unmount: %s (still mounted)\n" "$mp"
      fi
    else
      printf "  -> not a mountpoint anymore (ok): %s\n" "$mp"
    fi
  fi
done

echo
if [ "$MODE" = "fix" ]; then
  echo "Sweep complete."
else
  echo "No changes made (report mode)."
fi
