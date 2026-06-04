# forge-x camera — `mjpg_streamer` MJPEG passthrough

How the forge-x (ff5m) mod streams the AD5M camera, and how to configure it. Verified live on
`kunos`. Companion to [forge-x-boot-architecture.md](forge-x-boot-architecture.md).

## What it is

The mod's camera is **`mjpg_streamer`** forwarding the UVC camera's **native MJPEG frames 1:1**
over HTTP — **no decode, no re-encode, no transcode** (near-zero CPU; the cost is only buffer
RAM). The sensor (`U0AS01A-0`, `ab20:1276`) emits MJPG natively, so `input_uvc.so` grabs the
JPEG frames as-is and `output_http.so` serves them as `multipart/x-mixed-replace`.

This is the natural path because the **T113-S3 has no H.264 hardware encoder** (only JPEG/MJPEG
— see [../reverse-engineering/firmwareexe-ota-update.md] and
[../../lab/venc-vendor/FINDINGS.md]); any H.264 would force an MJPEG-decode→x264-**software**
round-trip on the dual-A7. So forge-x just forwards the MJPEG.

## Source

- **Mod project (ff5m):** <https://github.com/DrA1ex/ff5m> (authors: DrA1ex, ghzserg) — the
  `S98camera` service, the patched `mjpg_streamer` build, and `docs/CAMERA.md` live here.
- **Streamer:** **MJPG-streamer v2.0** — the `jacksonliam/mjpg-streamer-experimental` fork,
  ff5m-patched for reduced RAM (the `-fs` frame-size cap + single-buffer `-b 1`). On-device:
  `/opt/bin/mjpg_streamer`, plugins `/opt/lib/mjpg-streamer/{input_uvc,output_http}.so`, web
  root `/opt/mjpg-streamer/www`.

## Service + gating

`/opt/config/mod/.shell/S98camera {start|stop|restart|reload}`:
- Skipped entirely under `SKIP_MOD` / `SKIP_MOD_SOFT` / `SKIP_MOD_HARD` (stock-only boot).
- Only starts if the mod **`camera` variable = 1** (`/opt/config/mod_data/variables.cfg`,
  enable with `SET_MOD PARAM='camera' VALUE=1`). Default is `0` (off).
- Sets the v4l2 format then launches `mjpg_streamer` via `start-stop-daemon` (PID
  `/run/camera.pid`). Applies image effects (brightness/contrast/…) if `POST_PROCESSING=1`.

Launch line (as deployed):
```
mjpg_streamer \
  -o "/opt/lib/mjpg-streamer/output_http.so -w /opt/mjpg-streamer/www -p 8080" \
  -i "/opt/lib/mjpg-streamer/input_uvc.so -d /dev/video0 -r ${WIDTH}x${HEIGHT} -f ${FPS} -b 1 [-fs W*H*2]"
```

## Endpoints (port 8080)

- `http://<printer>:8080/?action=stream` — the live MJPEG stream (`multipart/x-mixed-replace`).
- `http://<printer>:8080/?action=snapshot` — a single JPEG frame.
- `http://<printer>:8080/control.htm` — v4l2 control tuning UI.

## Config — `/opt/config/mod_data/camera.conf`

(default copy: `/opt/config/mod/.cfg/default/camera.conf`; edited live or via Fluidd/Mainsail
→ Configuration → mod_data → camera.conf)

| key | meaning |
|---|---|
| `WIDTH` / `HEIGHT` | resolution (must be a v4l2-enumerated MJPG size: 640×480, 1280×720, 1280×960, 1440×1080, 1920×1080) |
| `FPS` | frame rate (per-resolution; 720p supports 30/20/15/10/7.5/5) |
| `VIDEO` | `auto` or `videoN` |
| `REDUCE_MEMORY` | `1` adds `-fs W*H*2` (frame-size cap, lower RAM); `0` = uncapped |
| `POST_PROCESSING` | `1` applies the `E_*` image effects |
| `E_*` | brightness/contrast/gain/gamma/hue/saturation/sharpness/exposure/… (v4l2 ctrls) |

Apply changes with `S98camera restart` (or `reload`). The setting persists across reboot
(S98camera re-reads `camera.conf` and the `camera` var each boot).

## 720p30 (set 2026-06-04 on `kunos`)

Changed from 640×480@15 → **1280×720@30** and enabled the camera:
```
# camera.conf
WIDTH=1280
HEIGHT=720
FPS=30
# + variables.cfg: camera=1, then S98camera restart
```
Verified: `mjpg_streamer … -r 1280x720 -f 30`, `:8080` serving a 1280×720 JPEG (~183 KB/frame).
Backup of the prior config at `camera.conf.bak720`.

**RAM note:** 720p frames are ~3–4× larger than 480p (~150–200 KB each). On the 128 MB box
this is fine for idle/streaming, but if RAM gets tight during a print, set `REDUCE_MEMORY=1`
(adds the `-fs` cap) or drop to 720p@15 / 480p.
