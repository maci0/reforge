# Stock firmware / recovery image landscape (AD5M Pro)

**Question:** can we reproduce the stock "golden" baseline from a published FlashForge
factory/recovery image instead of relying on our own device dump? And does FlashForge
publish a full image anywhere?

**Short answer:** the **base rootfs is publicly obtainable** — but only as a
**community-assembled artifact** (a device dump re-hosted by the modders). **FlashForge
itself publishes only incremental OTA overlay updates — no full/factory/recovery disk
image, anywhere.** Verified against FF's own download page + wiki and a web scour.

Pinned URLs + sha256: [`tools/recovery/recovery-sources.md`](../../tools/recovery/recovery-sources.md).
Artifacts archived locally under `tools/recovery/archive/` (gitignored).

## How FF firmware is actually delivered

FF firmware is an **overlay update model**, proven by reading FF's own `flashforge_init.sh`
inside the official packages:

- An OTA/USB package (`Adventurer5MPro-<ver>.tgz`, ~66 MB) contains:
  - `software-<ver>.tar.xz` (~11 MB) — the **application** (firmwareExe, klipper cfg, scripts) → `/opt`, `/data`
  - `library-*.tar.xz`, `kernel-*.tar.xz`, `control-*.tar.xz` (**MCU fw**: Mainboard.bin + Eboard.hex + mcu.img)
  - `boot.img` / `start.img` / `end.img` — **3 MB framebuffer splash/logo images** (`cat … > /dev/fb0`), *not* partitions
- The installer **`tar -x`'s the overlays onto an existing rootfs** — no `mkfs`, no `dd`,
  no block-device or base-filesystem write.

So an OTA package **patches a pre-existing base**; it never carries the base root filesystem.
The base (busybox/glibc/Qt skeleton) is factory-programmed at the eMMC level and FF does not
distribute it.

## What the "recovery" / "factory" images actually are

Two community full-state images exist (both **carry the base rootfs**):

1. **`Adventurer5M-factory.tar.xz`** (ghzserg / zmod) — **155 MB → 632 MB** unpacked. A
   complete stock rootfs (`bin/busybox`, `etc/init.d/*`, `lib`, `opt`, `usr`, `var`, …, plus a
   `THIS_IS_NOT_YOUR_ROOT_FILESYSTEM` guard). The unbrick launcher
   (`Adventurer5MPro-factory-3.1.3.tgz`, 192 KB) extracts it `-C /`. *"Install only if the
   printer won't start at all; takes ~1 h."*
2. **`…-recovery-full.tgz`** (DrA1ex / forge-x) — **212 MB**. The stock rootfs **chunked**
   into `system/system_2..65.tar.gz`, restored file-by-file for a corrupted-file repair, plus
   `bins/` helpers and a `recovery.img.xz` (another fb splash). "Contains a full system data
   backup."

For a **completely dead eMMC**, forge-x's `RECOVERY.md` documents an **FEL** path:
`xfel_t113_ds … write 0x0 dump.bin` — flashing a full eMMC **`dump.bin`** hosted on a
**Yandex disk** link. Also a **community dump**, plus UART/`xfel` tooling
([`xboot/xfel`](https://github.com/xboot/xfel), [`szemzoa/awboot`](https://github.com/szemzoa/awboot)).

## Did FF publish any of this? — No (verified)

- FF's official download page lists only incremental `Firmware_<ver>.tgz/.rar/.zip` —
  *"no full disk images or factory recovery files."*
- FF wiki / "Upgrade Firmware via USB" describes OTA + USB `.tgz` only.
- The only FF-official endpoints present in our archives are the **OTA update API**
  (`update.flashforge.com/api/updates/...`, `cloud.sz3dp.com`, `api.fdmcloud.flashforge.com`).
- A web scour (FF site, FF wiki, forums, GitHub) surfaced **no** FF-published full/factory/
  recovery image. Total-brick recovery is officially RMA; the community fills the gap with
  device dumps (`xfel`, UART).

Sources: [FF AD5M Pro downloads](https://www.flashforge.com/blogs/download-document/adventurer-5m-pro),
[FF wiki firmware upgrade](https://wiki.flashforge.com/en/adventurer-series/manual/firmware-upgrade),
[ghzserg/FF releases](https://github.com/ghzserg/FF/releases),
[DrA1ex/ff5m RECOVERY](https://github.com/DrA1ex/ff5m/blob/main/docs/RECOVERY.md),
[xblax klipper_mod](https://github.com/xblax/flashforge_ad5m_klipper_mod),
[xboot/xfel](https://github.com/xboot/xfel).

## Implication for ReForge's golden / testing

We can build a **reproducible stock baseline from 100% public, hash-pinned artifacts**, with
**no private device dump**:

```
stock golden @ version X  =  Adventurer5M-factory.tar.xz   (pinned base rootfs, public)
                           +  apply pinned FF OTA overlay   (software/library/kernel/control)
```

- Base layer: the pinned `Adventurer5M-factory.tar.xz` (or forge-x `recovery-full`).
- Version layer: the FF-official OTA `software-X.tgz` (pinnable; applied via FF's own
  `flashforge_init.sh` logic, which we have).
- MCU fw for **Plan 4** comes from the same OTA `control-*.tar.xz` (Mainboard.bin + Eboard.hex).

Caveats to keep honest:
- Base provenance is **community** (a dump), not vendor-signed — pin by sha256, state it.
- This reproduces the **rootfs/app**, not the bootloader/partition table; **un-bricking a
  wiped eMMC still needs a full `dump.bin` via FEL** (community-hosted) or our own dump.
- Our existing `tools/recovery/golden-stock-clean.img.gz` remains the trusted local baseline;
  this public path is an *additional*, fully-reproducible source.
