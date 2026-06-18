# Stock recovery / firmware image sources — pinned manifest

Authoritative list of where a stock AD5M (Pro) image (or its pieces) can be obtained, with
content hashes. Large blobs live in `tools/recovery/archive/` (gitignored); this manifest
is the tracked record. Background + provenance analysis:
[`docs/research/kernel/2026-06-01-stock-recovery-images.md`](../../docs/research/kernel/2026-06-01-stock-recovery-images.md).

> **Full firmware archive moved out of this repo.** Every downloadable AD5M / AD5M Pro OTA
> release (2.3.x → 5.1.7, both models — 22 packages), its sha256 + component-fingerprint
> manifest, the fetch tooling, and the per-version changelog now live in the shared,
> workspace-level **`fw-archive/`** repo (sibling of `reforge/`) — not here. This file pins only
> the full-eMMC **recovery** images that the recovery/qemu tooling consumes directly (golden,
> factory, unbrick).
>
> The hand-pinned rows below are the few images used directly by other tooling (recovery,
> qemu); the manifest is the complete record.

## Curated local full-eMMC images (naming convention)

Large binaries — **gitignored**, kept on local disk / external backup. The names encode
*content*, not capture method (renamed 2026-06-01 to remove the old ambiguous `golden-<host>`):

| name | content | how produced | role |
|---|---|---|---|
| `golden.img.gz` | **pristine stock** (forge-x removed) | `make-clean-golden.sh` (offline) | **canonical golden** — recovery baseline + qemu stock-rootfs source |
| `forge-x-<ts>.img.gz` | raw device dump **with forge-x installed** | `dump_golden.sh` of a forge-x device | forge-x reference snapshot only |
| `dump-<host>-<ts>.img.gz` | raw device dump, **as-is** (any state) | `dump_golden.sh` | uncurated capture — classify into one of the above by content |

Rule: **"golden" = clean stock only.** A raw device dump is never "golden" until cleaned.
Each image carries `.sha256` + `.size` (uncompressed full-eMMC byte count) sidecars; the
forge-x dump also keeps a `.partitions.txt` GPT map.

## Pinned artifacts (sha256)

| artifact | sha256 | size | kind | carries base rootfs? |
|---|---|---|---|---|
| `Adventurer5M-factory.tar.xz` | `06375d74d684e8b9195cb2737cfe78aea2bade8481e6fd015fb6bbea902632e1` | 155 MB (632 MB unp.) | full stock rootfs tarball (extract `-C /`) | **YES** |
| `Adventurer5M-3.x.x-2.2.3-recovery-full.tgz` | `07268f627fada7fd9299274dbed8d53877fec58fed4fd363eecc19b1afb7cad7` | 212 MB | forge-x file-chunk system backup (`system/system_*.tar.gz`) | **YES** (chunked) |
| `Adventurer5MPro-factory-3.1.3.tgz` | `7917f992121b79e68bf77031cae373e34ff806ec287fe95396538a7a44e55764` | 192 KB | unbrick launcher (expects `Adventurer5M-factory.tar.xz` on USB) | no (loader only) |

## URLs

| artifact | URL | host / provenance |
|---|---|---|
| `Adventurer5M-factory.tar.xz` | https://github.com/ghzserg/FF/releases/download/R/Adventurer5M-factory.tar.xz | ghzserg (zmod author) — **community dump** |
| recovery-full | https://github.com/DrA1ex/ff5m/releases/download/1.2.0/Adventurer5M-3.x.x-2.2.3-recovery-full.tgz | DrA1ex (forge-x) — **community dump** |
| Pro unbrick launcher | https://github.com/ghzserg/FF/releases/download/R/Adventurer5MPro-factory-3.1.3.tgz | ghzserg |
| FEL full eMMC `dump.bin` | https://disk.yandex.ru/d/oie2Chx1rexkgw | community (Yandex), flashed via `xfel`/`xfel_t113_ds` |
| FF official OTA firmware | https://www.flashforge.com/blogs/download-document/adventurer-5m-pro | **FlashForge official — OTA overlays only, no full image** |

## Verify

```sh
sha256sum tools/recovery/archive/Adventurer5M-factory.tar.xz   # must match table
```

> **Provenance note:** the full-rootfs artifacts are **community-assembled from device dumps**,
> not FlashForge-published. FF officially distributes **only OTA overlay updates** (verified —
> see the research doc). Trust them as community artifacts; pin by sha256.
