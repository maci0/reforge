# Disabled klipper patches

Patches kept here are **not** auto-applied by Buildroot — Buildroot only scans
`*.patch` files at the package root (`br-external/package/klipper/`), not in
subdirectories. To re-enable one, move it up:

```sh
mv br-external/package/klipper/disabled-patches/0002-...patch \
   br-external/package/klipper/
```

Re-verify it still applies against the pinned `KLIPPER_VERSION` in `klipper.mk`
before committing — drift since the patch was authored may need a refresh:

```sh
git -C "$(buildroot --get-source-dir klipper)" apply --check 0002-...patch
```

## Catalog

### `0002-relax-TRSYNC_TIMEOUT-ffad5m.patch`

- **What:** raises `TRSYNC_TIMEOUT` in `klippy/mcu.py` from `0.025` to `0.05`
  (25 ms → 50 ms).
- **Why disabled:** the user trial hasn't yet shown the failure mode this
  patch addresses (`E0011` MCU communication-timeout shutdowns). Carrying it
  upfront would mask the underlying root cause.
- **Re-enable trigger:** if hardware testing produces `E0011` / "communication
  timeout" shutdowns during normal printing on the AD5M / AD5M Pro v11 MCU,
  move this patch back to the package root.
- **Provenance:** ported from forge-x `ztune_klipper.sh` (`fix_enable_e11`),
  empirically proven against this same MCU. See
  `docs/research/2026-06-04-klipper-v0.11-fork-deltas.md` §5 for the carry/skip
  decision context.
