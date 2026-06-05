# docs/

Living **reference docs** are at the top level (kept current). Dated **snapshots** (specs, plans,
research, RE reports) live in subdirs, each with its own index README.

## Reference (current)
| path | what |
|---|---|
| [`architecture.md`](architecture.md) | system architecture, runtime stack, data flow (diagrams) |
| [`boot.md`](boot.md) | **the boot reference**: stock chain (BROM→U-Boot→init) + intervention points + brick-safety + forge-x hook + stock USB-update detection, *and* the installed-ReForge service chain (incl. the eboard MCU handshake) |
| [`build-process.md`](build-process.md) | pins → vendor fetch → Buildroot → image → `.tgz` (diagram; now also builds the kernel — `make kernel` / `kernel-virt`) |
| [`deployment-modes.md`](deployment-modes.md) | the deployment matrix — live-USB vs `.tgz` install vs stock, and how they relate |
| [`live-mode.md`](live-mode.md) | run the stack from USB — brick-free hardware trials |
| [`ota.md`](ota.md) | git-free in-place updates + last-known-good rollback (diagrams; designed) |
| [`optimizations.md`](optimizations.md) | **all tuning/optimizations + measured impact** (memory, size) — canonical numbers |
| [`REPO-LAYOUT.md`](REPO-LAYOUT.md) | **source of truth** for the repo structure (product / vendor / lab) |
| [`BACKLOG.md`](BACKLOG.md) | unscheduled ideas |

## Snapshots & findings (dated, per-dir index)
| dir | what |
|---|---|
| [`research/`](research/README.md) | dated findings, grouped: **Kernel & SoC** (T113 mainline support, BSP rebuild, byte-identical, brick-safe test, PID1), **Memory** (128 MB experiments), **UI/camera/video**, **printer stack** |
| [`reverse-engineering/`](reverse-engineering/README.md) | stock-firmware RE reports — full `firmwareExe` teardown, stock Klipper pin map, MCU firmware, stock kernel/modules + byte-identical build |
| [`board-notes/`](board-notes/README.md) | device/hardware reference: device overview, partition map, forge-x boot/camera, stock-rootfs provenance, USB-serial kmod |
| [`specs/`](specs/) | design specs (dated) — archival |
| [`plans/`](plans/) | implementation plans (dated) — archival |
| [`screenshots/`](screenshots/README.md) | qemu renders + boot console / bootsplash |

**Convention:** `specs/`, `plans/`, and `research/` are *snapshots* — they record decisions as
written and aren't rewritten on later refactors (a `## Update <date>` is appended if re-verified).
The reference docs above and `REPO-LAYOUT.md` reflect the current tree.
