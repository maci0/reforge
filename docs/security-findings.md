# FlashForge AD5M Pro — security findings and ReForge closure status

**Scope:** the FlashForge stock UI binary (`/opt/PROGRAM/software/<ver>/firmwareExe`) and the
supporting userland on the AD5M Pro running firmware **5.1.4 / 5.x**.
Hardware reverse-engineered: T113-S3 SoC, Buildroot rootfs, Qt4 single-binary UI app.
Source dumps verified against `tools/recovery/golden.img.gz`.

**Provenance:** each finding cites the reverse-engineering note that recorded it.
Severity icons follow the source notes (🔴 critical, 🟠 high, 🟡 medium).

**Closure-status legend (right-hand columns):**
- **✅ closed** — the attack surface does not exist when this mode is running.
- **🟦 mitigated** — surface is reachable but blocked at a higher layer (e.g. `/etc/hosts` cloud-block).
- **⚠ still present** — stock binary still runs alongside ReForge (today's Mode 2 chroot path).
- **n/a** — finding doesn't apply to this mode by construction.

**ReForge modes referenced** (see `docs/deployment-modes.md` for the full definitions):
- **Mode 1 — live USB**: ReForge boots from USB, stock rootfs on eMMC is read but not written. `firmwareExe` does NOT run because our launcher takes over at `S01reforge` before `/opt/auto_run.sh` reaches the firmwareExe launch line.
- **Mode 2a — today's chroot install**: ReForge installed at `/data/.mod/.reforge/`, runs via `chroot` from `S01reforge`. **Stock `firmwareExe` does NOT run** because S01 (ours) precedes the `/etc/init.d/S99firmwareExe` Tina init slot the stock UI uses, and `reforge-boot` does not return control to the parent rcS. **But the stock `auto_run.sh` USB hook and the Tina inittab earlier-than-S01 entries do still run.**
- **Mode 2b — PID-1 swap (planned, Option A in `docs/boot.md` §2)**: ReForge replaces `/init` with `reforge-init`; everything in the stock boot chain after PID 1 is skipped including `/etc/init.d/S?*`, `/opt/auto_run.sh`, and `firmwareExe`.
- **Mode 3 — full replacement (Plan 5)**: our kernel + our rootfs ship on `mmcblk0p4/p6`. Nothing of stock exists at runtime except the MCU firmware on the eboard.

---

## Findings

### 🔴 1. Fleet-wide hardcoded RSA-2048 private key in the shipping binary

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §2.

**What:** `/opt/key.priv` ships as a default Qt resource (.qrc blob bracketed by PNG data) and is **byte-identical on every unit out of the factory**. The cloud-binding challenge-response (Polar) signs cloud-supplied challenges with this key to prove device identity. Anyone who extracts the key from one image (trivial: it's in the read-only `.text` of `firmwareExe`) can forge the challenge for **every device that has not done a factory-reset key regeneration**.

**Mitigation in stock:** the UI's "Factory Reset" flow runs `create-rsa.sh` which writes a per-device pair to `/opt/key.priv` + `/opt/key.pub`. Users who never trigger factory reset stay on the fleet-default key.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present (stock binary present on eMMC, untouched) | ✅ closed | ✅ closed |

**Note:** Mode 2a leaves the key file on disk because we never touch the stock `/opt/` tree. Anyone who falls back to stock via `SKIP_MOD` (`docs/architecture.md`) and never factory-resets is back on the fleet default. **In Mode 2b and Mode 3, the stock Qt app that uses the key is not invoked, so the file on disk is dormant evidence rather than a live attack surface.**

---

### 🔴 2. Unauthenticated LAN raw-TCP control on port 8899

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §1.

**What:** `ServerListener` opens TCP 8899 with **Auth: NONE**. Any host on the same network can:
- `M601` — take control of the printer (locks the UI)
- `M28 <name>` / `M23` — upload + start arbitrary g-code (= "print this without asking")
- `M115` / `M119` — read full identity (model / serial / MAC / firmware version)
- Movement commands, including extruder, heater-disabled (cold extrude bypass possible if temp guards off)

**Mitigation in stock:** none. The protocol is a 2014-era FlashForge/FlashPrint compatibility surface.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed (`firmwareExe` not running) | ⚠ **still present** — stock `firmwareExe` runs alongside ReForge today | ✅ closed | ✅ closed |

**The big argument for elevating Mode 2b**: today's Mode 2a does NOT close this. Stock `firmwareExe` listens on :8899 in parallel with our Moonraker on :7125. Mainsail users may assume the printer's "only" web interface is theirs and not realize :8899 is wide open.

---

### 🔴 3. Cleartext MQTT-over-WebSocket cloud control plane

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-command-surface.md`](reverse-engineering/stock-ui/firmwareexe-cloud-command-surface.md).

**What:** Cloud control runs over `ws://<host>:8083/mqtt` — **plaintext, no TLS, no server-certificate verification.** `buildConnectOptions` (`0x3a6b1`) only sets user / password / clean-session / version, never `set_ssl` / `set_trust_store`. A LAN/WAN MITM on this link can issue any of the unauthenticated `*_cmd` JSON keys → heater (`temperatureCtl_cmd → M104/M140`), motion, prints, fan/light. Broker-credential compromise = total fleet takeover.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | 🟦 **mitigated** — `/etc/hosts` cloud-block prevents resolution of FF cloud hosts; binary still on disk, would reconnect if hosts were edited | ✅ closed | ✅ closed |

**Cloud-block details:** see `docs/specs/2026-05-31-reforge-firmware-design.md` §"cloud-block applied on every boot" + the host list in `vendor/forge-x/docs/FIRMWARE_5x_COMPAT.md`. The block is at `/etc/hosts`, applied by `reforge-boot`. It's a layer-3 mitigation, not a binary-level fix — `firmwareExe` still tries to connect; it just gets `NXDOMAIN`.

---

### 🔴 4. Unauthenticated UDP discovery on `225.0.0.9:8899` / bcast `:19000`

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §1b.

**What:** `OrcaMulticast` announces serial / MAC / model / IP / **cloud-bind status in cleartext** to a multicast group + broadcast port. Any LAN observer trivially enumerates printers and learns whether each is cloud-bound (= phishing target). Combined with finding #2, the LAN surface is fully open without even a port scan.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ **still present** — same reasoning as finding #2 | ✅ closed | ✅ closed |

---

### 🟠 5. OTA has MD5-only integrity, no signature

**Source:** [`reverse-engineering/stock-ui/firmwareexe-ota-update.md`](reverse-engineering/stock-ui/firmwareexe-ota-update.md) §3.

**What:** Update packages (`software-<ver>.tar.xz`, `kernel-`, `control-`, `library-`) ship a bundled `md5sum.list`. The integrity check verifies the package contents against this list — but **the list itself ships inside the package**, so an attacker who serves a tampered package (or MITMs the download) can update the list to match. No code signing, no out-of-band trust root, no A/B partition, no recovery slot.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed (no stock OTA path runs) | 🟦 mitigated — same `/etc/hosts` cloud-block prevents update-check; stock OTA still triggerable from USB `.tgz` though (see note) | 🟦 mitigated — same as 2a | ✅ closed |

**Note:** ReForge does not rely on FF OTA in any mode, but the stock USB-`.tgz` recovery path (`/opt/auto_run.sh` reading `Adventurer5MPro-*.tgz`) is still a way to install stock-format firmware. We intentionally preserve this path as the user's stock-recovery escape hatch (`docs/board-notes/fw-upgrade-mechanisms.md`). The trade-off is documented: a malicious USB stick can still drop a tampered `.tgz` and the stock installer will accept it.

---

### 🟠 6. Plaintext-HTTP internal dev infrastructure compiled into production

**Source:** [`reverse-engineering/stock-ui/firmwareexe-ota-update.md`](reverse-engineering/stock-ui/firmwareexe-ota-update.md) §1, [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) #4.

**What:** The shipping binary contains hard-coded internal FlashForge dev/staging endpoints that were never stripped at release:
- `http://10.33.11.172:32112/api/updates/check` (plaintext HTTP, internal IP)
- `10.33.23.222` (legacy update host)
- `rtmp://115.231.29.49:2045/Adventurer5M/SNMOMC9900796` (hard-coded test RTMP URL with a real-looking serial number)

A LAN attacker who can spoof IP routing to these RFC1918 addresses gets a code-update path.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | 🟦 mitigated (cloud-block) — but the **internal RFC1918 IP is not in the host list since it's an IP literal, not a hostname** | ✅ closed | ✅ closed |

**Gap noted:** the current `/etc/hosts` block is hostname-only. The hard-coded IP `10.33.11.172` would resolve fine from a LAN with that subnet. For Mode 2a we should add an `iptables -A OUTPUT -d 10.33.11.0/24 -j REJECT` rule (and similar for 10.33.23.0/24) to harden the cloud-block. Tracked: add to `docs/BACKLOG.md`.

---

### 🟠 7. `curl -k` on authenticated cloud requests

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md`](reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md) §"Security / privacy".

**What:** Multipart-upload paths that carry the device `authToken` are invoked with `curl -k` — **TLS server-cert verification disabled**. So even when the URL is HTTPS, the auth token is MITM-able.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | 🟦 mitigated (cloud-block prevents the upload from initiating) | ✅ closed | ✅ closed |

---

### 🟠 8. Hardcoded HMAC secrets in the binary

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md`](reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md), [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) #13.

**What:** Two HMAC keys used for cloud log-upload signing are baked into the read-only text segment:
- `A7dK9xP2LmQ4sT8Z`
- a second one in the same area of `.rodata`

Same on every device. Anyone with the keys can sign log-upload metadata as any device.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present (file dormant; binary not invoked because cloud-block kills upstream call) but a local FS attacker can extract the keys | ✅ closed | ✅ closed |

---

### 🟠 9. Shell-injection surface in challenge signing

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §2.

**What:** The cloud-binding challenge handler interpolates the cloud-supplied `challenge` field into a **single-quoted shell command**:

```
echo -n '<challenge>' | openssl dgst -sign /opt/key.priv | openssl base64
```

A cloud-side actor (or anyone who can MITM the cleartext MQTT link — finding #3) can shape `<challenge>` to escape the single-quote and inject arbitrary shell. The shell runs as the `firmwareExe` user (`root` on stock).

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | 🟦 mitigated (cloud-block prevents challenge delivery) | ✅ closed | ✅ closed |

---

### 🟠 10. Weak OrcaServer LAN HTTP auth on port 8898

**Source:** [`reverse-engineering/stock-ui/firmwareexe-orcaserver-lan-api.md`](reverse-engineering/stock-ui/firmwareexe-orcaserver-lan-api.md) §"Auth — check_sn_access".

**What:** `check_sn_access` accepts a serial number (**already broadcast in cleartext** via finding #4's multicast and via `M115` on the port-8899 protocol) + a short access code. Effectively a shared-secret over a known-leaked identifier. Routes covered include `/detail` (full live telemetry), `/control` (command table), `/gcodeList`, `/gcodeThumb`, `/product`.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ **still present** — port 8898 served by `firmwareExe`, which runs in parallel with our chroot | ✅ closed | ✅ closed |

---

### 🟡 11. Default credentials in shipped config

**Source:** [`reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md`](reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md) §"Security notes".

**What:** Stock config files ship with `userID: admin` / `userPass: ff123456`.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present (config file readable on stock rootfs) | ✅ closed | ✅ closed |

---

### 🟡 12. Hardcoded log-export zip password

**Source:** [`reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md`](reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md) §"Security notes", [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) #2.

**What:** Diagnostic archives the user can export are encrypted with the constant password `FFP0286&*%root`. Same across the fleet. Anyone who collects an exported log can decrypt it.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed (no stock log-export path) | ⚠ still present in stock UI's export menu | ✅ closed | ✅ closed |

---

### 🟡 13. STS credentials returned over URL query parameters

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md`](reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md) §"REST endpoint catalog".

**What:** `/firmware/device/oss_access?deviceID=&authToken=` returns Alibaba OSS short-lived STS credentials (`accessKeyID/Secret/securityToken/bucket/endpoint`). Because they're in the response body fetched via the GET query string, they land in any intermediate reverse-proxy / CDN / WAF / corporate-MITM log.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | 🟦 mitigated (cloud-block prevents request) | ✅ closed | ✅ closed |

---

### 🟡 14. No TLS certificate pinning + writable trust store

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §2.

**What:** `firmwareExe` uses OpenSSL with `SSL_CTX_load_verify_locations` + `X509_check_host` but **no certificate pinning**. The trust store `/opt/cacert.pem` (also embedded as `:/res/icon/main/cacert.pem` and copied at startup) is **device-writable** at runtime. A local attacker with FS access can inject a rogue CA and defeat HTTPS verification for every host the stock UI talks to.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ trust store file present and writable; stock binary doesn't run (chroot has its own CA bundle), but a fallback to stock via SKIP_MOD reopens the surface | ✅ closed | ✅ closed |

---

### 🟡 15. Cleartext WiFi PSK on command line and on disk

**Source:** [`reverse-engineering/stock-ui/firmwareexe-network-wifi.md`](reverse-engineering/stock-ui/firmwareexe-network-wifi.md) §"Station" / "SoftAP".

**What:**
- Station mode: `wpa_cli set_network N psk "%s"` exposes the PSK in `/proc/<pid>/cmdline` for the duration of the call. Any unprivileged process (if any existed) or `ps` listing captures it.
- SoftAP mode: `echo wpa_passphrase='%s' >> hostapd.conf` writes the AP password in cleartext to disk.

| Mode 1 (live) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed (we use `wpa_supplicant` config files directly, not the shell-interpolated path) | ⚠ stock binary still does this when user changes WiFi via the stock UI | ✅ closed | ✅ closed |

---

## Summary table

| # | Finding | Sev | Live (M1) | Chroot today (M2a) | PID-1 (M2b) | Full (M3) |
|---|---|---|---|---|---|---|
| 1 | Fleet RSA-2048 private key | 🔴 | ✅ | ⚠ | ✅ | ✅ |
| 2 | Unauth :8899 LAN control | 🔴 | ✅ | ⚠ | ✅ | ✅ |
| 3 | Cleartext MQTT control plane | 🔴 | ✅ | 🟦 | ✅ | ✅ |
| 4 | Unauth UDP discovery | 🔴 | ✅ | ⚠ | ✅ | ✅ |
| 5 | OTA MD5-only, no sig | 🟠 | ✅ | 🟦 | 🟦 | ✅ |
| 6 | Plaintext-HTTP dev infra | 🟠 | ✅ | 🟦 (IP gap) | ✅ | ✅ |
| 7 | `curl -k` on auth uploads | 🟠 | ✅ | 🟦 | ✅ | ✅ |
| 8 | Fleet HMAC secrets | 🟠 | ✅ | ⚠ | ✅ | ✅ |
| 9 | Shell injection in signing | 🟠 | ✅ | 🟦 | ✅ | ✅ |
| 10 | Weak OrcaServer auth | 🟠 | ✅ | ⚠ | ✅ | ✅ |
| 11 | `admin/ff123456` default | 🟡 | ✅ | ⚠ | ✅ | ✅ |
| 12 | Log-export zip password | 🟡 | ✅ | ⚠ | ✅ | ✅ |
| 13 | STS creds in URL | 🟡 | ✅ | 🟦 | ✅ | ✅ |
| 14 | Writable trust store | 🟡 | ✅ | ⚠ | ✅ | ✅ |
| 15 | Cleartext WiFi PSK | 🟡 | ✅ | ⚠ | ✅ | ✅ |

**Score-card across the 15 findings:**

| Mode | ✅ closed | 🟦 mitigated | ⚠ still present |
|---|---:|---:|---:|
| Mode 1 — live USB | 15 | 0 | 0 |
| Mode 2a — chroot install (today) | 0 | 6 | 9 |
| Mode 2b — PID-1 swap (planned) | 14 | 1 | 0 |
| Mode 3 — full replacement | 15 | 0 | 0 |

The 6 vs 9 split for Mode 2a is the case for elevating Mode 2b. Today's ReForge takes the cloud surface down but leaves nine stock-LAN surfaces intact — most importantly the unauthenticated `:8899` control port and the multicast discovery channel. Mode 2b takes those down without waiting for Mode 3's own-kernel work.

---

## ReForge's general security posture

What we commit to (from `docs/specs/2026-05-31-reforge-firmware-design.md`):

- **No cloud / telemetry of any kind.** NetEase IM, VoxelShare, MQTT, OSS uploads are actively blocked at `/etc/hosts` level and removed from `library-<ver>.tar.xz`. We do not introduce our own equivalent telemetry.
- **No `firmwareExe`.** The Qt4 stock UI that carries findings #1, #3, #5–9, #11–15 is not invoked.
- **Klippy + Moonraker + Mainsail + optional GuppyScreen** replace the entire stock UI and cloud surface. These have their own (smaller, better-audited) attack surfaces; cf. Moonraker's well-known LAN trust model.
- **Stock recovery path preserved (USB `.tgz`)** as the user's escape hatch. This is the one place finding #5 is intentionally inherited: a user who chooses to flash a stock-format `.tgz` accepts stock's MD5-only verification. ReForge's own update path uses GitHub-Release-signed downloads (see `docs/specs/2026-06-01-reforge-ota-design.md`).

What we do NOT commit to:

- **No formal CVE assignment / disclosure to FlashForge.** This document is a reverse-engineering note for ReForge-internal context, not a coordinated disclosure. Several of these findings are likely already known internally at FlashForge or have been independently reported on forums. We are not running a disclosure clock.
- **No certificate / signature on our own OTA today.** Our OTA design uses GitHub Release artifacts; the trust root is "you trust this GitHub repository". A future improvement (tracked in `docs/BACKLOG.md`) is sigstore / cosign signatures on the release artifacts. Not blocking.

---

## Action items captured from this writeup

- [ ] **Elevate Mode 2b (PID-1 swap) to a near-term ship target.** This is the largest single security win available without an own-kernel build. The `reforge-init` script is already staged (commit `d409bf7`) and qemu-tested (commit `ba54205`). What's missing is the installer wiring to swap `/init` on stock p6.
- [ ] **Extend `/etc/hosts` cloud-block with iptables for finding #6.** Hostname-only blocking misses the hard-coded `10.33.11.172` and `10.33.23.222` IP literals. One rule per RFC1918 subnet covers it.
- [ ] Track in `docs/BACKLOG.md`: sigstore signatures on ReForge OTA artifacts (lifts the trust story above "trust GitHub").
- [ ] Cross-link this doc from `README.md` (the "why does this project exist" paragraph) and from `docs/architecture.md` (security context for the chroot model).

---

## See also

- [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) — the master RE index, all 15 findings cite their detailed source from here.
- [`docs/deployment-modes.md`](deployment-modes.md) — the three modes referenced in the closure-status tables.
- [`docs/boot.md`](boot.md) §2 — the intervention table that gates Mode 2b.
- [`docs/research/kernel/2026-06-05-replacing-pid1.md`](research/kernel/2026-06-05-replacing-pid1.md) — the design of the PID-1 swap that closes findings #2 and #4.
- [`docs/specs/2026-05-31-reforge-firmware-design.md`](specs/2026-05-31-reforge-firmware-design.md) — the cloud-block + no-telemetry posture.
- [`vendor/forge-x/docs/FIRMWARE_5x_COMPAT.md`](specs/2026-05-31-reforge-firmware-design.md) — the full cloud-host list used by `/etc/hosts`.
