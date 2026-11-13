# FlashForge AD5M Pro — security findings and ReForge closure status

**Scope:** the FlashForge stock UI binary (`/opt/PROGRAM/software/<ver>/firmwareExe`) and the
supporting userland on the AD5M Pro running firmware **5.1.4 / 5.x**.
Hardware reverse-engineered: T113-S3 SoC, Buildroot rootfs, Qt4 single-binary UI app.
Source dumps verified against `tools/recovery/golden.img.gz`.

**Provenance:** each finding cites the reverse-engineering note that recorded it.
Severity icons follow the source notes (🔴 critical, 🟠 high, 🟡 medium).

**Evidence level:** the closure tables are derived from the boot scripts, not
from port scans of a running unit. Mode 2a follows from source: `reforge-boot`
returns once `/mod/start.sh` has backgrounded the services, so the stock `rcS`
continues to `/opt/auto_run.sh`, whose last step launches the stock UI. No
install-mode hardware trial is recorded. The cloud block does not reach that
UI either: `S00cloudblock` runs inside the chroot and edits the chroot's
`/etc/hosts`, while `firmwareExe` resolves through the stock `/etc/hosts`. The
Mode 2a cells below therefore record every finding as still present (see
[cloud-block details](#-3-cleartext-mqtt-over-websocket-cloud-control-plane)).
Mode 1/2b/3 closures are design expectations. Today's USB launcher is not zero-write: it creates `/reforge` on
p6 and persists gcode on p7. See the
[current deployment definitions](deployment-modes.md) and [write topology](live-mode.md#write-topology).

**Closure-status legend (right-hand columns):**
- **✅ closed** — the attack surface does not exist when this mode is running.
- **🟦 mitigated** — exposure is reduced but a documented part remains (for example a retained cleartext PSK).
- **⚠ still present** — stock binary still runs alongside ReForge (today's Mode 2 chroot path).
- **n/a** — finding doesn't apply to this mode by construction.

**ReForge modes referenced** (see `docs/deployment-modes.md` for the full definitions):
- **Mode 1 — planned zero-touch USB**: all writes would be redirected to RAM. The current live launcher instead runs from `/opt/auto_run.sh`'s USB hook, before its stock UI launch; it does not use `S01reforge`.
- **Mode 2a — today's chroot install**: ReForge installed at `/data/.mod/.reforge/`, runs via `chroot` from `S01reforge`. `reforge-boot` returns after starting the services, so the rest of the stock `rcS` and `/opt/auto_run.sh` still run, including its USB hook and its final `ffstartup-arm` launch of the stock UI (`firmwareExe`).
- **Mode 2b — PID-1 swap (planned, Option A in `docs/boot.md` §2)**: ReForge replaces `/init` with `reforge-init`; everything in the stock boot chain after PID 1 is skipped including `/etc/init.d/S?*`, `/opt/auto_run.sh`, and `firmwareExe`.
- **Mode 3 — full replacement (Plan 5)**: our kernel + our rootfs replace the stock boot/runtime stack. The verified stock kernel path is FAT p1, not p4 (see [boot.md](boot.md#1-the-boot-chain-verified)); the final replacement layout remains planned. Nothing of stock exists at runtime except the firmware on both mainboard and eboard MCUs.

---

The live-USB columns assume successful entry into today’s USB launcher, not an
early failure that falls back to stock and not the proposed zero-touch Mode 1; the canonical [mode definitions](deployment-modes.md) distinguish them.

## Findings

### 🔴 1. Fleet-wide hardcoded RSA-2048 private key in the shipping binary

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §2.

**What:** `/opt/key.priv` ships as a default Qt resource (.qrc blob bracketed by PNG data) and is **byte-identical on every unit out of the factory**. The cloud-binding challenge-response (Polar) signs cloud-supplied challenges with this key to prove device identity. Anyone who extracts the key from one image (trivial: it's in the read-only `.text` of `firmwareExe`) can forge the challenge for **every device that has not done a factory-reset key regeneration**.

**Mitigation in stock:** the UI's "Factory Reset" flow runs `create-rsa.sh` which writes a per-device pair to `/opt/key.priv` + `/opt/key.pub`. Users who never trigger factory reset stay on the fleet-default key.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present: the stock UI runs and uses the key | ✅ closed | ✅ closed |

**Note:** Live USB and Mode 2b do not erase the binary or key material on stock p6. Their closure labels mean the stock UI is not using it at runtime, not that the secret has been removed. Mode 2a leaves the key file on disk because we never touch the stock `/opt/` tree. Anyone who falls back to stock via `SKIP_MOD` (`docs/architecture.md`) and never factory-resets is back on the fleet default. **In Mode 2b and Mode 3, the stock Qt app that uses the key is not invoked, so the file on disk is dormant evidence rather than a live attack surface.**

---

### 🔴 2. Unauthenticated LAN raw-TCP control on port 8899

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §1.

**What:** `ServerListener` opens TCP 8899 with **Auth: NONE**. Any host on the same network can:
- `M601` — take control of the printer (locks the UI)
- `M28 <name>` / `M23` — upload + start arbitrary g-code (= "print this without asking")
- `M115` / `M119` — read full identity (model / serial / MAC / firmware version)
- Movement commands, including extruder, heater-disabled (cold extrude bypass possible if temp guards off)

**Mitigation in stock:** none. The protocol is a 2014-era FlashForge/FlashPrint compatibility surface.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed (`firmwareExe` not running) | ⚠ **still present** — stock `firmwareExe` runs alongside ReForge today | ✅ closed | ✅ closed |

**The big argument for elevating Mode 2b**: today's Mode 2a does NOT close this. Stock `firmwareExe` listens on :8899 in parallel with our Moonraker on :7125. Mainsail users may assume the printer's "only" web interface is theirs and not realize :8899 is wide open.

---

### 🔴 3. Cleartext MQTT-over-WebSocket cloud control plane

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-command-surface.md`](reverse-engineering/stock-ui/firmwareexe-cloud-command-surface.md).

**What:** Cloud control runs over `ws://<host>:8083/mqtt` — **plaintext, no TLS, no server-certificate verification.** `buildConnectOptions` (`0x3a6b1`) only sets user / password / clean-session / version, never `set_ssl` / `set_trust_store`. A LAN/WAN MITM on this link can issue any of the unauthenticated `*_cmd` JSON keys → heater (`temperatureCtl_cmd → M104/M140`), motion, prints, fan/light. Broker-credential compromise = total fleet takeover.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ **still present**: the chroot's `/etc/hosts` block does not reach the stock UI; the intended block would only stop name resolution | ✅ closed | ✅ closed |

**Cloud-block details:** see `docs/specs/2026-05-31-reforge-firmware-design.md` §"cloud-block applied on every boot". The host list is in `br-external/board/reforge/rootfs-overlay/etc/init.d/S00cloudblock`, which pins the listed names to `127.0.0.1` in `/etc/hosts`. It is a name-resolution mitigation, not a binary-level fix. As shipped, `/mod/start.sh` runs it inside the chroot, so it edits the chroot's `/etc/hosts` (see `packaging/README.md`, "Minimal stock footprint"); a `firmwareExe` running outside the chroot in Mode 2a still resolves through the unmodified stock `/etc/hosts`.

---

### 🔴 4. Unauthenticated UDP discovery on `225.0.0.9:8899` / bcast `:19000`

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §1b.

**What:** `OrcaMulticast` announces serial / MAC / model / IP / **cloud-bind status in cleartext** to a multicast group + broadcast port. Any LAN observer trivially enumerates printers and learns whether each is cloud-bound (= phishing target). Combined with finding #2, the LAN surface is fully open without even a port scan.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ **still present** — same reasoning as finding #2 | ✅ closed | ✅ closed |

---

### 🟠 5. OTA has MD5-only integrity, no signature

**Source:** [`reverse-engineering/stock-ui/firmwareexe-ota-update.md`](reverse-engineering/stock-ui/firmwareexe-ota-update.md) §3.

**What:** Update packages (`software-<ver>.tar.xz`, `kernel-`, `control-`, `library-`) ship a bundled `md5sum.list`. The integrity check verifies the package contents against this list — but **the list itself ships inside the package**, so an attacker who serves a tampered package (or MITMs the download) can update the list to match. No code signing, no out-of-band trust root, no A/B partition, no recovery slot.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| 🟦 stock network OTA is absent after successful live startup; unsigned USB and ReForge update paths remain | ⚠ stock network and USB update paths remain | 🟦 stock UI OTA is skipped; ReForge assets remain unsigned and any USB recovery hook needs its own validation | 🟦 stock UI OTA is removed; planned retained recovery/update paths still need signature validation |

**Note:** ReForge does not rely on FF OTA in any mode, but the stock USB-`.tgz` recovery path (`/opt/auto_run.sh` reading `Adventurer5MPro-*.tgz`) is still a way to install stock-format firmware. We intentionally preserve this path as the user's stock-recovery escape hatch (`docs/board-notes/fw-upgrade-mechanisms.md`). The trade-off is documented: a malicious USB stick can still drop a tampered `.tgz` and the stock installer will accept it.

---

### 🟠 6. Plaintext-HTTP internal dev infrastructure compiled into production

**Source:** [`reverse-engineering/stock-ui/firmwareexe-ota-update.md`](reverse-engineering/stock-ui/firmwareexe-ota-update.md) §1, [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) #4.

**What:** The shipping binary contains hard-coded internal FlashForge dev/staging endpoints that were never stripped at release:
- `http://10.33.11.172:32112/api/updates/check` (plaintext HTTP, internal IP)
- `10.33.23.222` (legacy update host)
- `rtmp://115.231.29.49:2045/Adventurer5M/SNMOMC9900796` (hard-coded test RTMP URL with a real-looking serial number)

If a private update endpoint is selected, an attacker who controls routing to it could
redirect an unsigned update fetch. The public RTMP literal is a separate video endpoint,
not evidence of a code-update path.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present: the chroot's `/etc/hosts` block does not reach the stock UI, and the **IP literals are not hostnames**, so no hosts entry could block them | ✅ closed | ✅ closed |

**Gap noted:** hostname blocking cannot cover these literals. Filtering
`10.33.11.0/24`, `10.33.23.0/24` and `115.231.29.49` on-device needs a replacement
kernel with Netfilter and the required iptables matches/targets, plus iptables
userspace. Stock has `CONFIG_NETFILTER` disabled; adding the package or a module
alone is insufficient. External filtering is an alternative only where the printer's
traffic crosses that firewall. A Netfilter-enabled kernel retaining the stock UI is
not a planned mode: planned Mode 2b stops the UI, and Mode 3 removes it while its
board config omits Netfilter. For current Mode 2a, external filtering is the available
network control; these on-device rules are not implemented. See the
[cloud-block hardening backlog](BACKLOG.md#cloud-block-hardening-iptables-for-ip-literal-stock-endpoints).

---

### 🟠 7. `curl -k` on authenticated cloud requests

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md`](reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md) §"Security / privacy".

**What:** Multipart-upload paths that carry the device `authToken` are invoked with `curl -k` — **TLS server-cert verification disabled**. So even when the URL is HTTPS, the auth token is MITM-able.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present: the chroot's `/etc/hosts` block does not reach the stock UI | ✅ closed | ✅ closed |

---

### 🟠 8. Hardcoded HMAC secrets in the binary

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md`](reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md), [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) #13.

**What:** Two HMAC keys used for cloud log-upload signing are baked into the read-only text segment:
- `A7dK9xP2LmQ4sT8Z`
- a second one in the same area of `.rodata`

Same on every device. Anyone with the keys can sign log-upload metadata as any device.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present: the stock UI runs and can sign uploads; the keys are also extractable from the binary on disk | ✅ closed | ✅ closed |

---

### 🟠 9. Shell-injection surface in challenge signing

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §2.

**What:** The cloud-binding challenge handler interpolates the cloud-supplied `challenge` field into a **single-quoted shell command**:

```
echo -n '<challenge>' | openssl dgst -sign /opt/key.priv | openssl base64
```

A cloud-side actor (or anyone who can MITM the cleartext MQTT link — finding #3) can shape `<challenge>` to escape the single-quote and inject arbitrary shell. The shell runs as the `firmwareExe` user (`root` on stock).

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present: the chroot's `/etc/hosts` block does not reach the stock UI | ✅ closed | ✅ closed |

---

### 🟠 10. Weak OrcaServer LAN HTTP auth on port 8898

**Source:** [`reverse-engineering/stock-ui/firmwareexe-orcaserver-lan-api.md`](reverse-engineering/stock-ui/firmwareexe-orcaserver-lan-api.md) §"Auth — check_sn_access".

**What:** `check_sn_access` accepts a serial number (**already broadcast in cleartext** via finding #4's multicast and via `M115` on the port-8899 protocol) + a short access code. Effectively a shared-secret over a known-leaked identifier. Routes covered include `/detail` (full live telemetry), `/control` (command table), `/gcodeList`, `/gcodeThumb`, `/product`.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ **still present** — port 8898 served by `firmwareExe`, which runs in parallel with our chroot | ✅ closed | ✅ closed |

---

### 🟡 11. Default credentials in shipped config

**Source:** [`reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md`](reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md) §"Security notes".

**What:** Stock config files ship with `userID: admin` / `userPass: ff123456`.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present — stock UI runs with the shipped defaults | ✅ closed | ✅ closed |

---

### 🟡 12. Hardcoded log-export zip password

**Source:** [`reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md`](reverse-engineering/stock-ui/firmwareexe-filesystem-and-system.md) §"Security notes", [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) #2.

**What:** Diagnostic archives the user can export are encrypted with the constant password `FFP0286&*%root`. Same across the fleet. Anyone who collects an exported log can decrypt it.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed (no stock log-export path) | ⚠ still present in stock UI's export menu | ✅ closed | ✅ closed |

---

### 🟡 13. Authentication token in URL query parameters

**Source:** [`reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md`](reverse-engineering/stock-ui/firmwareexe-cloud-rest-and-oss.md) §"REST endpoint catalog".

**What:** `/firmware/device/oss_access?deviceID=&authToken=` puts the device ID and bearer token in the request URL. URL logging by a reverse proxy, CDN, WAF or TLS-intercepting proxy can expose that token, potentially allowing later retrieval of Alibaba OSS short-lived STS credentials. The STS keys themselves are returned in the response body; URL logging alone does not show that those keys were logged.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present: the chroot's `/etc/hosts` block does not reach the stock UI | ✅ closed | ✅ closed |

---

### 🟡 14. No TLS certificate pinning + writable trust store

**Source:** [`reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md`](reverse-engineering/stock-ui/firmwareexe-lan-protocol-and-crypto.md) §2.

**What:** `firmwareExe` uses OpenSSL with `SSL_CTX_load_verify_locations` + `X509_check_host` but **no certificate pinning**. The trust store `/opt/cacert.pem` (also embedded as `:/res/icon/main/cacert.pem` and copied at startup) is **device-writable** at runtime. A local attacker with FS access can inject a rogue CA and defeat HTTPS verification for every host the stock UI talks to.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| ✅ closed | ⚠ still present: the stock UI runs and uses the writable trust store | ✅ closed | ✅ closed |

---

### 🟡 15. Cleartext WiFi PSK on command line and on disk

**Source:** [`reverse-engineering/stock-ui/firmwareexe-network-wifi.md`](reverse-engineering/stock-ui/firmwareexe-network-wifi.md) §"Station" / "SoftAP".

**What:**
- Station mode: `wpa_cli set_network N psk "%s"` exposes the PSK in `/proc/<pid>/cmdline` for the duration of the call. Any unprivileged process (if any existed) or `ps` listing captures it.
- SoftAP mode: `echo wpa_passphrase='%s' >> hostapd.conf` writes the AP password in cleartext to disk.

| Live USB (today) | Mode 2a (chroot) | Mode 2b (PID-1) | Mode 3 |
|---|---|---|---|
| 🟦 stock-UI command-line exposure absent; the stock cleartext PSK file remains and is reused | ⚠ stock UI and stored cleartext credentials remain | 🟦 stock UI absent; existing PSK files are not erased | unverified: replacement-network credential storage is not specified |

---

## Summary table

| # | Finding | Sev | Live USB | Chroot today (M2a) | PID-1 (M2b) | Full (M3) |
|---|---|---|---|---|---|---|
| 1 | Fleet RSA-2048 private key | 🔴 | ✅ | ⚠ | ✅ | ✅ |
| 2 | Unauth :8899 LAN control | 🔴 | ✅ | ⚠ | ✅ | ✅ |
| 3 | Cleartext MQTT control plane | 🔴 | ✅ | ⚠ | ✅ | ✅ |
| 4 | Unauth UDP discovery | 🔴 | ✅ | ⚠ | ✅ | ✅ |
| 5 | OTA MD5-only, no sig | 🟠 | 🟦 | ⚠ | 🟦 | 🟦 |
| 6 | Plaintext-HTTP dev infra | 🟠 | ✅ | ⚠ | ✅ | ✅ |
| 7 | `curl -k` on auth uploads | 🟠 | ✅ | ⚠ | ✅ | ✅ |
| 8 | Fleet HMAC secrets | 🟠 | ✅ | ⚠ | ✅ | ✅ |
| 9 | Shell injection in signing | 🟠 | ✅ | ⚠ | ✅ | ✅ |
| 10 | Weak OrcaServer auth | 🟠 | ✅ | ⚠ | ✅ | ✅ |
| 11 | `admin/ff123456` default | 🟡 | ✅ | ⚠ | ✅ | ✅ |
| 12 | Log-export zip password | 🟡 | ✅ | ⚠ | ✅ | ✅ |
| 13 | Authentication token in URL | 🟡 | ✅ | ⚠ | ✅ | ✅ |
| 14 | Writable trust store | 🟡 | ✅ | ⚠ | ✅ | ✅ |
| 15 | Cleartext WiFi PSK | 🟡 | 🟦 | ⚠ | 🟦 | unverified |

**Score-card across the 15 findings:**

| Mode | ✅ closed | 🟦 mitigated | ⚠ still present | unverified |
|---|---:|---:|---:|---:|
| Current live USB | 13 | 2 | 0 | 0 |
| Mode 2a — chroot install (today) | 0 | 0 | 15 | 0 |
| Mode 2b — PID-1 swap (planned) | 13 | 2 | 0 | 0 |
| Mode 3 — full replacement | 13 | 1 | 0 | 1 |

Today's Mode 2a install leaves all 15 surfaces reachable: the stock UI still runs, and
the cloud block edits only the chroot's `/etc/hosts` (see the evidence note above).
Applying the block to the stock `/etc/hosts` could restrict cloud paths involved in
findings #3, #5, #7, #9 and #13, but cannot block finding #6's IP literals. The LAN
surfaces, including unauthenticated `:8899` control and multicast discovery, need the
stock UI stopped. Mode 2b is intended to stop it without waiting for an own-kernel build.

---

## ReForge's general security posture

What we commit to (from `docs/specs/2026-05-31-reforge-firmware-design.md`):

- **No cloud / telemetry of any kind.** `S00cloudblock` pins the known NetEase IM, VoxelShare and MQTT hosts to `127.0.0.1`; as shipped this covers only the ReForge chroot (see the evidence note at the top), and OSS upload hosts are generated at runtime, so `/etc/hosts` cannot block them. ReForge's own `.tgz` ships a stub `library-<ver>.tar.xz`; it does not remove the stock library already installed. We do not introduce our own equivalent telemetry.
- **No `firmwareExe`** as the goal. The Qt4 stock UI carries all 15 findings. Live mode and the planned Mode 2b/3 do not invoke it; today's Mode 2a install still lets `auto_run.sh` launch it (see the mode list above).
- **Klippy + Moonraker + Mainsail + optional GuppyScreen** replace the entire stock UI and cloud surface. These have their own (smaller, better-audited) attack surfaces; cf. Moonraker's well-known LAN trust model.
- **Stock recovery path preserved (USB `.tgz`)** as the user's escape hatch. This is the one place finding #5 is intentionally inherited: a user who chooses to flash a stock-format `.tgz` accepts stock's MD5-only verification. ReForge's own update path uses GitHub Release downloads without artifact signatures (see `docs/specs/2026-06-01-reforge-ota-design.md`).

What we do NOT commit to:

- **No formal CVE assignment / disclosure to FlashForge.** This document is a reverse-engineering note for ReForge-internal context, not a coordinated disclosure. Several of these findings are likely already known internally at FlashForge or have been independently reported on forums. We are not running a disclosure clock.
- **No certificate / signature on our own OTA today.** Our OTA design uses GitHub Release artifacts; the trust root is "you trust this GitHub repository". A future improvement (tracked in `docs/BACKLOG.md`) is sigstore / cosign signatures on the release artifacts. Not blocking.

---

## Action items captured from this writeup

- [ ] **Elevate Mode 2b (PID-1 swap) to a near-term ship target.** This is the largest single security win available without an own-kernel build. The `reforge-init` script is already staged (commit `d409bf7`) and qemu-tested (commit `ba54205`). What's missing is the installer wiring to swap `/init` on stock p6.
- [ ] **Choose a control for finding #6 in Mode 2a.** An external firewall on the traffic
  path can block `10.33.11.0/24`, `10.33.23.0/24` and `115.231.29.49`. Planned Mode 2b
  instead stops the stock UI. A custom Netfilter-enabled kernel retaining that UI is
  outside the current mode roadmap, not part of Plan 5.
  See the [backlog](BACKLOG.md#cloud-block-hardening-iptables-for-ip-literal-stock-endpoints).
- [x] Track in `docs/BACKLOG.md`: sigstore signatures on ReForge OTA artifacts (lifts the trust story above "trust GitHub").
- [x] Cross-link this doc from `README.md` ("Why") and `docs/architecture.md` ("Deployment modes").

---

## See also

- [`reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md`](reverse-engineering/stock-ui/firmwareexe-reverse-engineering.md) — the master RE index, all 15 findings cite their detailed source from here.
- [`docs/deployment-modes.md`](deployment-modes.md) — the three modes referenced in the closure-status tables.
- [`docs/boot.md`](boot.md) §2 — the intervention table that gates Mode 2b.
- [`docs/research/kernel/2026-06-05-replacing-pid1.md`](research/kernel/2026-06-05-replacing-pid1.md) — the design of the PID-1 swap that closes findings #2 and #4.
- [`docs/specs/2026-05-31-reforge-firmware-design.md`](specs/2026-05-31-reforge-firmware-design.md) — the cloud-block + no-telemetry posture.
- [`br-external/board/reforge/rootfs-overlay/etc/init.d/S00cloudblock`](../br-external/board/reforge/rootfs-overlay/etc/init.d/S00cloudblock) — the cloud-host list written into `/etc/hosts`.
