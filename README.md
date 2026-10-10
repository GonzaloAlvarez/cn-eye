# cn-eye

motionEye for the USB camera on **eye.lan** (Radxa ZERO 3, the operator's "on the go" box). A USB camera is plugged in → the stack starts; motion events are recorded to a size-capped folder on the SD card; the UI is reachable over the tailnet only. Nothing needs the internet at runtime, and a dead tailnet changes nothing but reachability.

## Health checks

```sh
systemctl status cn-eye                         # active (exited) while a camera is plugged in; inactive otherwise
readlink -f /dev/cam0                           # the USB capture node the udev rule picked (absent = no camera)
docker compose -p cn-eye ps                     # motioneye + prune Up
docker compose -p cn-eye logs --tail 20 prune   # one line per pass that deleted something
df -h /mnt/sd/eye && du -sh /mnt/sd/eye         # recordings live on mmcblk1p1, under EYE_MAX_GB
curl -sI --socks5-hostname 127.0.0.1:1055 http://eye.ts.gn.al:8765/ | head -1   # from the work Mac via cn-socksnode
sudo ufw status | grep 8765                     # 8765/tcp on tailscale0 ALLOW IN — the only hole
```

| Surface | URL | Who |
|---|---|---|
| Tailnet | `http://eye.ts.gn.al:8765` | operator devices (`gonzaloab` → `tag:svc:*` in the Headscale ACL) |
| LAN | none — UFW default-deny; break-glass `ssh -L 8765:127.0.0.1:8765 eye.lan` then `http://127.0.0.1:8765` | — |

motionEye has its own login (user `admin`, password set on first run) on top of the network gate.

## Services

| Service | Image | Net | Purpose |
|---|---|---|---|
| `motioneye` | `ghcr.io/motioneye-project/motioneye:0.44.0@sha256:7da31d6…` (pinned by digest) | host | UI/API on `:8765`; runs motion against `/dev/video0` (= host `/dev/cam0`); config in `./config`, media in `EYE_MEDIA_DIR` |
| `prune` | `alpine:3.20` | none | Size cap: deletes the oldest movies (+ `.thumb`) whenever `EYE_MEDIA_DIR` exceeds `EYE_MAX_GB`; motionEye itself only retains by age |

Host side, installed by `setup.sh`: `/etc/udev/rules.d/90-cn-eye.rules` (any USB V4L2 *capture* node → `/dev/cam0`, `SYSTEMD_WANTS=cn-eye.service`) and `/etc/systemd/system/cn-eye.service` (`BindsTo` the camera device and the SD mount, `RequiresMountsFor` + a marker-file condition, `docker compose up -d` / `stop` — stopped containers keep their logs across an unplug). Plug → start; unplug → stop; boot with the camera attached → coldplug starts it. No `[Install]`: udev is the only trigger.

## Setup

Host prerequisites (once): `amun docker`; `amun tailscale` then

```sh
# on the VPS: one-shot key under the operator user (id 2), tagged tag:svc
docker exec cloudnet-headscale-1 headscale preauthkeys create --user 2 --tags tag:svc --expiration 1h
# on eye — --accept-dns=false keeps NetworkManager's resolv.conf (no .lan breakage, no dependency on headscale)
sudo tailscale up --login-server=https://hs.gn.al --authkey=<key> --hostname=eye --accept-dns=false --accept-routes=false
```

Then:

```sh
git clone https://github.com/GonzaloAlvarez/cn-eye.git ~/cn-eye
cd ~/cn-eye
./setup.sh        # .env, SD marker, udev rule + unit, UFW hole, image pull (internet, once), start
```

`.env` holds no secrets (`TZ`, `EYE_MEDIA_DIR`, `EYE_MAX_GB`, `EYE_PRUNE_INTERVAL`); re-run `./setup.sh` after changing it.

### First run (UI)

1. `http://eye.ts.gn.al:8765` → user `admin`, empty password → *Settings → General → Admin Password*: set one.
2. *Add Camera → Local V4L2 → `/dev/video0`* (`/dev/video1` may be listed too — it is the UVC metadata node, not usable).
3. Recommended for the RK3566 (software x264; the fans are for this): *Video Device* 1280x720 @ 10 fps · *Movies* "Motion Triggered", format **MP4** — *not* "MP4 (h264_v4l2m2m)", which motionEye pre-selects because ffmpeg lists that wrapper, but the vendor kernel has no V4L2 M2M encoder and no movie is ever written — max length 300 s, preserve 30 days (the byte cap is `prune`'s job) · *Motion Detection* on · *Video Streaming* on, 5 fps, quality 50 %.
4. Apply. Wave at the camera; a movie appears under `/mnt/sd/eye/Camera1/<date>/` and in the media browser.

The *Streaming URL* the UI shows (`:9081`) is motion's own MJPEG port; it is deliberately not opened in UFW (the UI gets frames through 8765). Open it only if you want the raw stream: `sudo ufw allow in on tailscale0 to any port 9081 proto tcp`.

## Operations

```sh
docker compose -p cn-eye logs -f motioneye
sudo systemctl restart cn-eye                   # whole-stack restart (down + up)
sudo udevadm test "$(udevadm info -q path -n /dev/video0)" 2>&1 | grep -E 'cam0|SYSTEMD_WANTS'   # rule sanity
journalctl -u cn-eye -b                         # why it did not start: condition (marker), mount, docker
```

Deploy a change: `git pull && docker compose -p cn-eye up -d --force-recreate --no-deps <svc>` (recreate, never reload: `./prune` is a directory bind, `./config` is state). Unit/rule changes: `./setup.sh`.

### Upgrading motionEye

Pinned by OCI index digest; no Watchtower on this host. Resolve the new release's digest (`docker buildx imagetools inspect ghcr.io/motioneye-project/motioneye:<tag>` or the GHCR manifest), bump tag **and** digest in `docker-compose.yml`, commit, then on the host `git pull && ./setup.sh` (pulls the missing image and recreates). Back up `./config` first (`tar czf ~/cn-eye-config.tgz config`) — motionEye rewrites its config on upgrade.

### State, backup, restore

`./config` (motioneye.conf, motion.conf with the `# @admin_password` hash, camera-1.conf) is host state, gitignored, **not backed up**: a rebuild = `./setup.sh` + the *First run* steps again. Recordings are retention-bound (`EYE_MAX_GB`, "preserve movies") and not backed up either.

## Deviations from the homelab conventions (deliberate)

- **No `ts-*` sidecar**: the host is the tailnet node (`eye`, `tag:svc`). A sidecar in `network_mode: service:` would make the app unreachable even on the LAN when tailscaled is down, and its `tailscale ip` healthcheck would block the app from starting offline.
- **No `resiliency.yml`**: the lifecycle is udev-driven (`BindsTo=dev-cam0.device`); amun-docker's boot unit and reconcile cron would start/heal the stack without a camera and fight that. `amun docker` still installs Docker; it simply finds no manifest here.
- **No Consul/traefik-lab route, no Authentik, no promtail/exporters/Grafana, no Watchtower, no backup, no Kauket** — offline-first mobile box; motionEye's own login is the auth; the operator asked for no metrics or home links.
- **Host files installed by `setup.sh`**, not an `amun-eye` plugin: one host, two files, no fleet.
- **Both containers on `network_mode: host`** so UFW gates them (published ports bypass UFW); the only hole is 8765/tcp on `tailscale0`.

## Troubleshooting

- *Unit inactive, camera plugged*: `journalctl -u cn-eye -b`. "Condition check" = marker `/mnt/sd/eye/.cn-eye-volume` missing (wrong/absent card → `./setup.sh`); "dependency failed" = `/mnt/sd` not mounted; `udevadm info -q property -n /dev/videoN | grep ID_V4L_CAPABILITIES` must show `:capture:`.
- *No movies although motion is detected*: `sudo grep movie_codec config/camera-1.conf` says `mp4:h264_v4l2m2m` (or `hevc_v4l2m2m`) — switch the camera's *Movie Format* to plain **MP4**; `docker compose -p cn-eye logs motioneye` shows motion's encoder errors. All encoding here is software.
- *Camera dropped on its own* (`journalctl -k | grep 'USB disconnect'`, often after `uvcvideo … Non-zero status (-71)` lines): a flaky hub/cable path — plug the camera straight into the board; the unit stops on unplug and restarts on replug by design.
- *UI up, camera "Unable to open video device"*: another process holds it (`sudo fuser /dev/video0`), or the camera re-enumerated — `sudo systemctl restart cn-eye`.
- *Not reachable from the tailnet*: `tailscale status` on eye; `headscale nodes list` on the VPS (tags `tag:svc`, online); `sudo ufw status | grep 8765`; the client must be the operator's identity (ACL `gonzaloab → tag:svc:*`).
- *Hot*: `cat /sys/class/thermal/thermal_zone0/temp`; lower resolution/fps in the camera settings — all encoding is software (no rkmpp in Debian's ffmpeg; `/dev/mpp_service` is unused).
- *SD card full anyway*: the janitor caps only `EYE_MEDIA_DIR`; `EYE_MAX_GB` is whole GiB and must leave headroom for the filesystem.

## History

2026-10-10: host `radxa03` renamed `eye`, joined the tailnet (`tag:svc`), Docker installed, and the Sept-2025 experiments removed (`record_video.service`, `~/mediamtx`, `~/webcam.sh`, `ufw allow 8554`, the two test mp4s on `/mnt/sd`).

## License

GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007 — Copyright (c) 2026 Gonzalo Alvarez
