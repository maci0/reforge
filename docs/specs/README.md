# specs/

Design specs for ReForge. **Snapshots:** each spec records the design as written;
it is not rewritten as work lands (a dated `## Update` note may be appended if a
decision is re-verified). The parts that survived implementation are folded into
the living reference docs ([`../architecture.md`](../architecture.md),
[`../boot.md`](../boot.md), [`../ota.md`](../ota.md),
[`../build-process.md`](../build-process.md)).

Filenames are `YYYY-MM-DD-<slug>.md`. Implementation of each spec is tracked in
[`../plans/`](../plans/README.md) and [`../BACKLOG.md`](../BACKLOG.md).

## Specs (oldest → newest)

- [`2026-05-31-reforge-firmware-design.md`](2026-05-31-reforge-firmware-design.md)
  — the master design: from-scratch Buildroot userland on the stock kernel
  (P1–P3), deployment modes, partition/brick-safety model, memory plan, and the
  P4/P5 roadmap (own MCU firmware / mainline kernel + U-Boot).
- [`2026-06-01-plan3-installer-design.md`](2026-06-01-plan3-installer-design.md)
  — the `.tgz` installer (`flashforge_init.sh`), the qemu-system-arm test
  harness, and the stock-UI feasibility spike.
- [`2026-06-01-reforge-ota-design.md`](2026-06-01-reforge-ota-design.md)
  — the OTA / release channel: Moonraker `update_manager` against self-published
  per-component release zips, the draft-then-publish CI pipeline, and the
  trial/last-known-good rollback. Shipped — see [`../ota.md`](../ota.md).
