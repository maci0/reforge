# Stock firmware 5.1.7 — diff vs 5.1.4 (and 5.1.2)

What changed in the official FlashForge Adventurer 5M **Pro** OTA between the
version our analysis baselined on (**5.1.4**, the `golden.img` rootfs) and the
current release (**5.1.7**). Short version: **5.1.7 is a firmwareExe-only
maintenance bump — nothing ReForge depends on changed.**

## Provenance

| field | value |
|---|---|
| artifact | `Adventurer5MPro-5.1.7-2.2.3-20260605.tgz` |
| released | 2026-06-05 (page lists 5.1.7-2.2.3; previous public Pro build is 5.1.4-2.2.3, 2026-05-15) |
| source | FlashForge official OSS — `https://flashforge-resource.oss-us-east-1.aliyuncs.com/AD5MP%E5%9B%BA%E4%BB%B6/Adventurer5MPro-5.1.7-2.2.3-20260605.tgz` (linked from the official [download page](https://www.flashforge.com/blogs/download-document/adventurer-5m-pro)) |
| size / sha256 | 68290560 B · `58076910fe0a659f212c19150b780272bdbc09ccc8a8eb30479b650b3f7a5ffd` |
| container | despite the `.tgz`/`.tar.xz` names, **every archive is plain uncompressed `tar`** — extract with `tar -xf`, not `-z`/`-J` |

There is no public 5.1.5/5.1.6 for the Pro; 5.1.7 follows 5.1.4 directly.

## Package layout (unchanged shape)

The OTA `.tgz` is a tar of component tarballs + boot blobs:

```
software-<ver>.tar.xz   firmwareExe (Qt UI) + run.sh + ntpclient + md5sum.list
kernel-2.1.6.tar.xz     uImage, sunxi.dtb, 8821cu.ko, rcS, bootlogo, udhcpd.conf
library-2.5.0.tar.xz    ffstartup-arm, nim.tar (NetEase IM), create-rsa.sh, *.cfg
control-2.2.3.tar.xz    MCU fw: Mainboard-20230831.bin, Eboard-20231012.hex + commands
boot.img start.img end.img  splash/boot images
flashforge_init.sh inittab shadow mencoder play Cube-PLA-Test.gx
```

## 5.1.4 → 5.1.7 (our baseline → current)

Every component is **byte-identical** except the UI app. Verified by extracting
the 5.1.7 tarballs and comparing against the installed 5.1.4 tree in
`golden.img` (`debugfs dump` from `tests/qemu-harness/build/stock-clean-rootfs.ext4`):

| component | 5.1.4 | 5.1.7 | result |
|---|---|---|---|
| kernel `uImage` / `sunxi.dtb` / `8821cu.ko` / `rcS` / bootlogo | 2.1.6 | 2.1.6 | **IDENTICAL** (8821cu.ko + dtb byte-compared) |
| MCU `Mainboard-20230831.bin` / `Eboard-20231012.hex` | 2.2.3 | 2.2.3 | **IDENTICAL** |
| library `nim.tar` (NetEase IM) / `ffstartup-arm` | 2.5.0 | 2.5.0 | **IDENTICAL** |
| `flashforge_init.sh` / `inittab` / `shadow` | — | — | **IDENTICAL** |
| `boot.img` / `start.img` / `end.img` / `mencoder` / `play` | — | — | **IDENTICAL** |
| `run.sh` (software) | — | — | **IDENTICAL** |
| **`firmwareExe`** | 9 564 448 B | 9 564 802 B | **changed (+354 B)** |

The only delta is `firmwareExe` (the Qt touchscreen app), and it is tiny. The
human-readable string diff:

- **removed:** the paho-MQTT `SSLSocket.c` https-proxy log strings
  (`Setting https proxy to %s`, `… proxy auth …`, `https_proxy`) — paho version
  is unchanged (`paho.mqtt.c-1.3.13`); this is a build/codepath trim, not a
  feature or library change.
- **added:** references to `/opt/klipper/klippy/extras/virtual_sdcard.py` and
  `/root/version`.
- **hostnames / endpoints: no change** — the set of FlashForge / NetEase /
  VoxelShare / 127.net hosts embedded in `firmwareExe` is identical to 5.1.4.

So functionally 5.1.7 is a maintenance/bugfix rebuild of the UI; the printer
backbone (kernel, Wi-Fi driver, MCU firmware, cloud SDK, boot scripts) is the
exact same bytes as 5.1.4.

## 5.1.2 → 5.1.4 (context — the bigger jump)

Most of what looks "new in 5.1.7" relative to our older 5.1.2 reference actually
landed in **5.1.4**:

- **`ntpclient` added** (Larry Doolittle's `ntpclient v2015`, ARM ELF). `run.sh`
  gained a block that copies it to `/opt/`; `firmwareExe` drives it and the NTP
  host is **`pool.ntp.org`** (passed via `-h` at runtime, not hardcoded in the
  binary). → stock now does SNTP time-sync.
- `firmwareExe` shrank ~49 KB.
- The 5.1.4 cloud-host reshuffle we already track (OTA → `update.voxelshare.com`,
  video → `liveplay`/`livepush.flashforge.com`) is present and unchanged through
  5.1.7 — all already in our cloudblock list.

## ReForge impact: none required

- **cloudblock** (`S00cloudblock`): host set is **complete and current** for
  5.1.7 — no new endpoints in `firmwareExe`, and `nim.tar` (the NetEase host
  source) is byte-identical. No entries to add.
- **`pool.ntp.org`**: a genuine stock outbound endpoint (since 5.1.4) that we do
  **not** block — intentional. NTP is benign time-sync and a correct clock
  matters for TLS/logs; blocking it would only make the app misjudge time. Noted
  here so it isn't mistaken for an un-tracked telemetry host. Block at the router
  if a full air-gap is wanted.
- **kernel / dtb / 8821cu.ko**: byte-identical → the
  [byte-identical stock-kernel build](stock-kernel-byte-identical-build.md) and
  module-packaging analysis stay valid for 5.1.7.
- **MCU firmware**: unchanged (same `Mainboard-20230831` / `Eboard-20231012`).
- **install hooks** (`flashforge_init.sh`, `auto_run.sh`/`inittab`): unchanged →
  ReForge's `.tgz` install hook + stock dual-boot remain compatible.

## Reproduce

```sh
A=tools/recovery/archive
curl -fsSL -o "$A/Adventurer5MPro-5.1.7-2.2.3-20260605.tgz" \
  'https://flashforge-resource.oss-us-east-1.aliyuncs.com/AD5MP%E5%9B%BA%E4%BB%B6/Adventurer5MPro-5.1.7-2.2.3-20260605.tgz'
mkdir -p /tmp/fw517 && tar -xf "$A/Adventurer5MPro-5.1.7-2.2.3-20260605.tgz" -C /tmp/fw517
tar -xf /tmp/fw517/software-5.1.7.tar.xz -C /tmp/fw517   # inner archives are plain tar too
# baseline 5.1.4 comes from the golden rootfs:
R=tests/qemu-harness/build/stock-clean-rootfs.ext4   # or: make qemu-stock-rootfs
debugfs -R "dump /opt/PROGRAM/software/5.1.4/firmwareExe /tmp/fw517/firmwareExe.514" "$R"
cmp /tmp/fw517/firmwareExe.514 /tmp/fw517/firmwareExe   # the only changed payload
```
