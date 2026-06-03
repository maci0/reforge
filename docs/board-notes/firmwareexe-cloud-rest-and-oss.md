# firmwareExe — cloud REST API + Alibaba OSS file flow

Three cooperating cloud clients, all libcurl. Companion to the cloud-command-surface doc (which
covers the inbound MQTT/NIM command path).

| Client | Host | Role |
|---|---|---|
| `AppClient` | `api.voxelshare.com` / `update.voxelshare.com` | primary FlashForge cloud (register, status, OSS upload, MQTT) |
| `CloudClient` | `cloud.sz3dp.com` (legacy `hz.sz3dp.com:11002`, `update.sz3dp.com:10443`) | legacy FlashCloud (RegistrationCode→AuthToken, status push) |
| `PolarClient` | `printer2.polar3d.com` | optional Polar Cloud (socket.io, S3 form POST) |

## REST endpoint catalog (AppClient / VoxelShare)
Headers: `Content-Type: application/json` + `authToken:` + `deviceId`. (`curl -k` — TLS verify
**disabled** on the multipart auth'd calls.)

| Path | Method | Purpose |
|---|---|---|
| `/api/v2/external/truck/firmware/register` | POST | register → `{authToken, deviceId, userName, commonTopics}` |
| `/firmware/unregister` | POST | deregister |
| `/device/mqtt/config` | POST | MQTT creds (`mqttName/mqttPassword/gTopic/pTopic`); req `clientId: device_<SN>` |
| `/firmware/device/status/upload` | POST | periodic telemetry (`device_keep_alive`) |
| `/firmware/device/oss_access` | GET `?deviceID=&authToken=` | **STS creds** (`accessKeyID/Secret/securityToken/bucket/endpoint`) |
| `/device/upload/config` | POST | presigned URL config (`keyMap{contentType,storageKey,storageUrl}`) |
| `/firmware/device/local_job` | POST multipart | register local job + thumb |
| `/firmware/device/local_file/callback` | POST | confirm OSS upload |
| `/firmware/device/localFileName` / `localFileThum` | POST | sync file list / upload thumb |
| `/firmware/device/delay_video` | POST multipart | timelapse video |
| `/firmware/device/thumbnail/delete` | POST | delete OSS thumb |
| `/api/v3/message/device/event?id=` | GET/POST | ack device message |
| `/api/v3/model/log/upload` | POST (HMAC-signed) | notify log upload |
| `/api/v3/model/upload/encryptConfig` | POST | OSS config for encrypted log upload |
| `/api/updates/check`, `/api/updates/v2/download_url` | POST/GET | firmware update (see OTA doc) |

CloudClient (legacy): `/printer/register` (RegistrationCode→AuthToken), `/printer/status`
(telemetry + base64 JPEG `Snapshot`, polled `setInterval`).

## AuthToken lifecycle
Boot → `mainStartAppClient` → POST `/firmware/register` with a **RegistrationCode** → response
`authToken` (long-lived bearer) + `deviceId` + `commonTopics`. Stored in **`FlashConfig`**
(`AppRegInfo`). No auto-rotation; cleared on unregister. Sent as `authToken:` header (JSON REST),
`?authToken=` query (oss_access/event), or `-F authToken=` (multipart). User-Agent
`Flashforge-3DPrinter/ (Adventurer 5M Pro)` (register path has a typo `User-Agen:`).

## OSS upload flow
1. **STS fetch**: `AppClient::ossInfo` (`0x1a407d`) GET `/oss_access` → `accessKeyID/Secret/
   securityToken/bucket/endpoint`.
2. **PutObject**: `OssClient(endpoint, Credentials(id,secret,sessionToken), config)` →
   `AlibabaCloud::OSS::OssClient::PutObject`. Thumbnail keys prefixed `device/thumbnail/`.
3. **Artifacts uploaded**: gcode files, thumbnails (`/data/updateFile.bmp`), camera snapshot
   `/data/camera/cloud/cloud.jpg`, timelapse `*.mp4` (→ `/delay_video`), and **log bundle**
   (`/data/logFiles/*.log` zipped) via a separate raw-curl signed path (`OssLogUploader`).
4. **Presigned alt**: `/device/upload/config` → PUT to `storageUrl` → `/local_file/callback`.

## Status telemetry payload
`AppClient::printerInfoTojson` (`0x199799`, 3860 B) → `/status/upload`. Fields: firmware version,
IP, filament/cumulative, job id/status/error, gcode path/name, progress/duration, all temps
(nozzle/bed/chamber cur+target), estimates, disk free, light/camera/fan state, HLS/RTMP stream URL
(`rtmp://…?auth_key=`, `.m3u8?auth_key=`), base64 snapshot. Cadence: full on connect + fast
`device_keep_alive` + event-driven on state change (`checkNeedUploadStatus` dedup).

## Security / privacy
- **`curl -k`** = TLS verify off on auth'd multipart → authToken MITM-able.
- **Hardcoded HMAC secrets in the binary** for log-upload signing: `A7dK9xP2LmQ4sT8Z` and
  `s9Kf3Lx2Pq8Vn4TzA1mR6YwB` (const `model_log_upload`) → anyone with the firmware can forge
  `/api/v3/model/log/upload` signatures.
- STS creds returned in a URL keyed only by `deviceID`+`authToken` (lands in intermediary logs).
- **Everything leaves the device** when cloud is on: identity (SN/MAC/IP), every gcode file +
  thumbnails + camera snapshots + timelapse to OSS, continuous telemetry, live RTMP/HLS camera, and
  **full log bundles** (may contain network/config). Three clouds: FlashForge (voxelshare/sz3dp),
  Alibaba OSS, optional Polar.

Symbols: `AppClient::{ossInfo 0x1a407d, ossSendLocalFileList 0x1a9519, doUploadStatus 0x19fa31,
printerInfoTojson 0x199799}`, `AlibabaCloud::OSS::OssClient::PutObject`.
