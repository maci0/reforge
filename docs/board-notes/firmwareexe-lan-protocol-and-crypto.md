# firmwareExe — legacy LAN protocol, discovery, and crypto/keys

Two areas of the stock app (not stripped): the raw-TCP FlashForge LAN protocol + UDP discovery
(`ServerListener`, `OrcaMulticast`), and the embedded crypto / key material. **Both reveal serious
security weaknesses relevant to ReForge's hardening.**

## (1) ServerListener — raw TCP FlashForge/FlashPrint protocol (port 8899)
`common/ServerListener.cpp` (`ServerListener::ServerListener` `0xe6981`). The classic FlashForge
network-printer protocol FlashPrint/OrcaSlicer speak. Line-oriented ASCII G/M-code, request/response,
**no framing magic, no checksum, no auth**.
- `dataReceived(...)` `0xebd9d` reassembles frames → `cmdReceived(...)` `0xede3d` (integer dispatch
  on the M-code number).
- Handlers (real symbols): `cmd_M27` (SD progress), `cmd_M105` (temps `T0:.. B:..`), `cmd_M114`
  (position), **`cmd_M115`** (machine info: model/serial/MAC/firmware — **unauth identity leak**),
  `cmd_M119` (endstops/status/LED/current file), `cmd_M23` (select/start SD file), **`cmd_M28`/
  `cmd_M29`** (**file upload begin/end**), **`cmd_M601`** ("take control" → `Control Success V2.1.`),
  `cmd_M602` (release), `cmd_M610` (file write), `cmd_M650/661/662/663` (calibration/device-list/info),
  `cmd_G1/G28/G90/G91/G92` (motion). Heartbeat `slot_checkHeartBeat` `0xe6cf1` (`connection time out`).
- **Port 8899** (`0x22c3`). **Auth: NONE** — any LAN host can `M601` take control, `M28/M23`
  upload+print arbitrary gcode, `M115/M119` read full identity. 🔴

## (1b) OrcaMulticast — UDP discovery on 225.0.0.9
`httplib/orcaMulticast.cpp`. `initOrcaMulticast` (`0xe5a11`) advertises:
| field | value |
|---|---|
| `m_port` | 8898 |
| `m_mcport` | **8899** (multicast/listen) |
| `m_bcport` | 19000 (broadcast) |
| `m_magic` | **0xBF03 / 48899** |
| `m_vid`/`m_pid` | USB VID/PID |
| `m_httpPort` | 8898 (OrcaServer REST) |
| `m_connectMode`/`m_bindStatus` | LAN-vs-cloud mode / cloud-bind flag |

Group literal `225.0.0.9`. Dual mcast+bcast sockets, `select()` pthread. **Beacon payload**
(`MulticastReply`): printer name, **serial number, model, IP**, magic, VID/PID, ports 8899+8898,
and **cloud-bind status — all in cleartext**. 🔴 Any LAN observer learns identity + cloud-bind state;
combined with the unauthenticated TCP 8899, the LAN attack surface is fully open
(discover → M601 take-control → M28/M23 upload+print).

The only authenticated LAN path is the **OrcaServer REST API** (8898) gated by the weak
serial+access-code `check_sn_access` (see OrcaServer doc).

## (2) Crypto / signing / embedded keys
### Embedded RSA-2048 private key (🔴 critical)
- A complete **PKCS#1 RSA PRIVATE KEY** PEM is embedded in `.rodata` (~offset `0x42f7de`, ~1674 B,
  `e=65537`). It is **bracketed by PNG data** → a **Qt resource (qrc) blob = a default `key.priv`
  shipped identically on every unit**. (Value not reproduced.)
- **Weakness:** the whole fleet ships the *same* private key in the read-only binary. Until a factory
  reset regenerates a per-device key, the Polar challenge-response below can be forged by anyone who
  extracts this key from any one firmware image.

### create-rsa.sh → /opt/key.priv + /opt/key.pub
- `system("create-rsa.sh /opt/")` run from **`MachineInfo::on_btnReset_clicked()`** (`0x18618d`) —
  the UI **Factory Reset** flow. So `/opt/key.priv`+`/opt/key.pub` are the **per-device** keypair
  (re)generated at factory reset; the embedded `.rodata` key is the first-boot default.

### Request signing (Polar Cloud, NOT firmware)
- `echo -n '<challenge>' | openssl dgst -sign /opt/key.priv | openssl base64`, run from
  **`PolarClient::handleCmdWelcome`** (`0x150629`). Signs the Polar `welcome` **`challenge`**; the
  base64 RSA-SHA256 signature goes in the `registerDevice`/`hello` JSON **`signature`** field
  (alongside `publicKey`/`myInfo`/`challenge`). Polar Cloud = `https://printer2.polar3d.com` (socket.io).
- 🟠 **Shell-injection surface:** the cloud-supplied `challenge` is interpolated into a single-quoted
  `echo -n '%1'` and shelled out — a `'` in `challenge` (server-trusted input) → local command
  injection. Same pattern in the OSS video-upload `curl -F 'X-Amz-Signature=...'` path.

### Alibaba OSS signing
`AlibabaCloud::OSS::HmacSha1Signer` (vtable `0x64c900`) for OSS request HMAC-SHA1; plus an STS/
presigned `X-Amz-*` path (`X-Amz-Credential/Date/Signature`, `Policy`) used by the camera/timelapse
**video upload** (shelled `curl -X POST -F 'key=..' -F 'X-Amz-Signature=..' -F 'file=@..'`). OSS
creds handed to the printer by Polar `getUrlResponse` and relayed via shell.

### TLS — trust store, not pinning
- `/opt/cacert.pem` (also qrc `:/res/icon/main/cacert.pem`, copied by `main` at startup) is a
  **145-cert Mozilla-style CA bundle** (~302 KB) loaded by `NimManager::nimInit` + OpenSSL
  (`SSL_CTX_load_verify_locations`, `X509_check_host`). **No certificate pinning.** 🟡 `/opt/cacert.pem`
  is device-writable → a local attacker with FS access can inject a rogue CA to defeat verification.
- The lone embedded RSA **public** key (`:/res/icon/main/rsapub.pem`, mirror `/usr/share/public.pem`)
  is used by `QrencodeApp::rsaEncrypt` to RSA-encrypt binding payloads rendered into on-screen QR codes.
- (Note: an earlier overview mentioned a `ws.cloud.flashforge.com` leaf cert — the crypto deep-dive
  did **not** find it in this image; the cloud control plane here is Polar + the FlashForge REST/MQTT
  endpoints. Treat the leaf-cert claim as unconfirmed for this firmware variant.)

## Security summary
1. 🔴 Hardcoded RSA-2048 **private key in the binary** (default `/opt/key.priv`, same across units).
2. 🔴 **Unauthenticated LAN raw-TCP control** (8899): take-control + arbitrary gcode upload/print +
   identity leak.
3. 🔴 **Unauthenticated UDP discovery** (225.0.0.9:8899 / bcast 19000) leaks serial/MAC/model/IP/
   cloud-bind status.
4. 🟠 **Shell-interpolated signing/upload** with cloud-supplied fields → command-injection surface.
5. 🟠 Weak OrcaServer HTTP auth (public serial + short access code).
6. 🟡 No TLS pinning; writable `/opt/cacert.pem` → rogue-CA injection.

For ReForge: dropping `ServerListener` + `OrcaMulticast` (or firewalling 8899/19000/225.0.0.9)
closes the unauthenticated LAN surface; regenerating per-device keys and removing shelled-out
crypto closes the rest.
