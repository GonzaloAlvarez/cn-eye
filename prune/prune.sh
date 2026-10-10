#!/bin/sh
# cn-eye prune — keep the media dir under EYE_MAX_GB by deleting the oldest files.
#
# motionEye retains by age only ("preserve movies N days"). This loop runs every
# EYE_PRUNE_INTERVAL seconds; when the tree exceeds the cap it deletes the oldest
# regular files (by mtime) together with their motionEye sidecar (<file>.thumb)
# until the deficit is covered, then removes empty day folders. Sidecars
# (*.thumb, lastsnap.jpg) and the volume marker are never candidates themselves.
# Busybox-compatible: du -sk, stat -c, find -empty -delete (no find -printf).
set -u

MAX_GB="${EYE_MAX_GB:-50}"
INTERVAL="${EYE_PRUNE_INTERVAL:-300}"
ROOT="${EYE_PRUNE_ROOT:-/recordings}"
ONESHOT="${EYE_PRUNE_ONESHOT:-0}"
CAP_KB="${EYE_PRUNE_CAP_KB:-$(( MAX_GB * 1024 * 1024 ))}"   # KiB override for tests

used_kb() { du -sk "$ROOT" | cut -f1; }

prune_once() {
  used=$(used_kb)
  [ "$used" -gt "$CAP_KB" ] || return 0
  deficit_kb=$(( used - CAP_KB ))
  freed_kb=0
  n=0
  list=$(mktemp)
  # "<mtime> <size> <path>", oldest first. Paths may contain spaces: `read`
  # puts the remainder of the line into $path.
  find "$ROOT" -type f ! -name '*.thumb' ! -name 'lastsnap.jpg' ! -name '.cn-eye-volume' \
      -exec stat -c '%Y %s %n' {} + 2>/dev/null | sort -n > "$list"
  while IFS=' ' read -r _mtime size path; do
    [ "$freed_kb" -ge "$deficit_kb" ] && break
    rm -f -- "$path" "$path.thumb"
    freed_kb=$(( freed_kb + (size + 1023) / 1024 ))
    n=$(( n + 1 ))
  done < "$list"
  rm -f "$list"
  find "$ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null
  echo "[prune] $(date '+%F %T') ${used} KiB > cap ${CAP_KB} KiB: deleted ${n} file(s) (~${freed_kb} KiB), now $(used_kb) KiB"
}

echo "[prune] cap ${MAX_GB} GiB (${CAP_KB} KiB) on ${ROOT}, every ${INTERVAL}s"
while :; do
  prune_once
  [ "$ONESHOT" = "1" ] && exit 0
  sleep "$INTERVAL"
done
