#!/usr/bin/env bash
# cn-eye — idempotent bring-up on the host (eye.lan).
#
#   git clone https://github.com/GonzaloAlvarez/cn-eye.git ~/cn-eye
#   cd ~/cn-eye && ./setup.sh
#
# Everything here is idempotent; sudo is used only for the host bits.
#   1. .env from .env.example when missing (no secrets in it — edit freely).
#   2. Media dir on the SD card + the .cn-eye-volume marker the unit gates on.
#      The dir MUST sit on a non-root mount (the unit BindsTo that mount).
#   3. host/90-cn-eye.rules + the rendered host/cn-eye.service are installed,
#      udev/systemd reloaded and video4linux re-triggered (coldplug → the unit
#      starts right away if a camera is attached).
#   4. UFW: allow 8765/tcp in on tailscale0 only (host network ⇒ UFW gates it).
#   5. Pinned images are pulled ONLY when missing locally — the single step
#      that needs internet (first install and upgrades).
#   6. If the unit was already active: `up -d --force-recreate` (recreate,
#      never reload — bind mounts and the digest pin change under it).
#
# Requires: docker + compose plugin (`amun docker`), passwordless sudo.
set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
RUN_USER="$(id -un)"

case "${1:-}" in
  -h|--help) sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

log() { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
env_get() { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }

command -v docker >/dev/null || die "docker not installed — run: amun docker"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing — run: amun docker"
sudo -n true 2>/dev/null || die "passwordless sudo required"

# ── 1. .env ──────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  log "creating .env from .env.example (no secrets; edit as needed)"
  cp .env.example .env
fi
MEDIA_DIR="$(env_get EYE_MEDIA_DIR)"; MEDIA_DIR="${MEDIA_DIR:-/mnt/sd/eye}"
MAX_GB="$(env_get EYE_MAX_GB)";       MAX_GB="${MAX_GB:-50}"
[[ "$MAX_GB" =~ ^[0-9]+$ ]] || die "EYE_MAX_GB must be a whole number of GiB (got '$MAX_GB')"

# ── 2. Media dir on the real SD volume ───────────────────────────────────────
MOUNT_POINT="$(findmnt -no TARGET --target "$(dirname "$MEDIA_DIR")" 2>/dev/null || true)"
[[ -n "$MOUNT_POINT" && "$MOUNT_POINT" != "/" ]] \
  || die "$(dirname "$MEDIA_DIR") is not a mounted non-root filesystem — is the SD card mounted?"
MOUNT_UNIT="$(systemd-escape -p --suffix=mount "$MOUNT_POINT")"
sudo mkdir -p "$MEDIA_DIR"
sudo touch "$MEDIA_DIR/.cn-eye-volume"
mkdir -p config
log "media: $MEDIA_DIR on $MOUNT_POINT ($MOUNT_UNIT), cap ${MAX_GB} GiB"

# ── 3. udev rule + systemd unit ──────────────────────────────────────────────
WAS_ACTIVE=0; systemctl is-active --quiet cn-eye.service && WAS_ACTIVE=1
log "installing /etc/udev/rules.d/90-cn-eye.rules and /etc/systemd/system/cn-eye.service"
sudo install -m 0644 host/90-cn-eye.rules /etc/udev/rules.d/90-cn-eye.rules
sed -e "s|__REPO_DIR__|${REPO_DIR}|g" \
    -e "s|__MEDIA_DIR__|${MEDIA_DIR}|g" \
    -e "s|__MOUNT_UNIT__|${MOUNT_UNIT}|g" \
    -e "s|__USER__|${RUN_USER}|g" host/cn-eye.service \
  | sudo tee /etc/systemd/system/cn-eye.service >/dev/null
sudo systemctl daemon-reload
sudo udevadm control --reload

# ── 4. UFW: tailnet-only ─────────────────────────────────────────────────────
if sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ! sudo ufw status | grep -q '^8765/tcp on tailscale0 '; then
    log "ufw: allow 8765/tcp in on tailscale0"
    sudo ufw allow in on tailscale0 to any port 8765 proto tcp comment 'cn-eye motionEye (tailnet only)' >/dev/null
  fi
else
  echo "WARNING: ufw is not active — :8765 would be reachable from any network" >&2
fi

# ── 5. Images (only step that needs internet) ────────────────────────────────
while read -r img; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    log "pulling $img"
    docker compose pull --ignore-buildable 2>/dev/null || docker compose pull
    break
  fi
done < <(docker compose config --images)

# ── 6. Start / recreate ──────────────────────────────────────────────────────
if [[ $WAS_ACTIVE -eq 1 ]]; then
  log "unit active — recreating containers with the current compose/env"
  docker compose -p cn-eye up -d --force-recreate --remove-orphans
else
  log "re-triggering video4linux (starts cn-eye.service if a camera is attached)"
  sudo udevadm trigger --subsystem-match=video4linux --action=add
  sleep 3
fi

cat <<MSG

===============================================================
cn-eye

  unit    : systemctl status cn-eye          ($(systemctl is-active cn-eye.service 2>/dev/null || true); starts only while a USB camera is plugged in)
  camera  : $([ -e /dev/cam0 ] && readlink -f /dev/cam0 || echo 'none plugged in (/dev/cam0 absent)')
  stack   : docker compose -p cn-eye ps
  UI      : http://$(hostname -s).ts.gn.al:8765   (tailnet only; UFW on tailscale0)
  break-glass from the LAN: ssh -L 8765:127.0.0.1:8765 $(hostname -s).lan
  media   : $MEDIA_DIR  (cap ${MAX_GB} GiB, prune every $(env_get EYE_PRUNE_INTERVAL)s)

First run: log in as admin (empty password), set the password, Add Camera →
Local V4L2 → /dev/video0 (README "First run" has the recommended settings).
===============================================================
MSG
