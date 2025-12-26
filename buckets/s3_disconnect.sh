# s3_disconnect.sh
MOUNT_PATH="${1:-.}/s3_buckets"
for mp in /tmp/$USER/rclone/*/; do
  [ -d "$mp" ] && umount "$mp" 2>/dev/null
done
rm -f "$MOUNT_PATH"/* 2>/dev/null
echo "Disconnected"