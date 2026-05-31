# Research: Why Buildroot? Why not Alpine userspace + our own kernel/U-Boot?

**Date:** 2026-05-31
**Question:** Do we need Buildroot at all? Couldn't we take an Alpine armhf userspace, build a kernel + U-Boot ourselves, and have it work?

**Short answer:** Yes, that *would boot and run Klipper* — it's a valid architecture and people do it. But it quietly reverses several decisions ReForge made on purpose (glibc, immutable+reproducible image, ABI matched to the runtime kernel, surgical 128 MB minimalism). Alpine is an excellent **mutable distro**; ReForge wants an **immutable firmware image**. Those are different products. Buildroot is the right tool for the second. Details below.

---

## What each tool actually is

- **Buildroot** — a *firmware image builder*. Cross-compiles a complete, minimal rootfs **from source**, together with a matched toolchain, kernel, U-Boot, and final flashable image (`genimage`), all pinned and reproducible. No runtime package manager — the image is immutable. This is the standard embedded-firmware model.
- **Alpine** — a *general-purpose minimal distro*. musl + busybox + the `apk` package manager, with a large prebuilt binary repository. You assemble a rootfs and mutate it at runtime with `apk add`. Optimized for containers/servers/SBC hosts.

Critically: **Alpine does not build your kernel or U-Boot.** That work is identical either way. So "Alpine + build kernel+uboot" does **not** save the kernel/U-Boot effort — it only swaps *how the rootfs is produced*. Buildroot integrates rootfs + kernel + U-Boot + image into one pinned, reproducible flow; Alpine gives you only the rootfs and you bolt the rest on and manage two worlds.

## Could it work? Yes.

- There is a maintained `alpine-klipper` project (knoopx) that installs Klipper/Moonraker/Mainsail/Fluidd on Alpine via `apk` + a Python venv. So the stack runs on Alpine/musl.
- An Alpine armhf rootfs + our own mainline kernel + mainline U-Boot would boot on the T113-S3.

So this is not "impossible" — it's a real fork in the road. The question is whether it's the *right* one for ReForge's goals.

## Why Buildroot is the better fit for ReForge

### 1. libc: Alpine is musl-only; we deliberately chose glibc
We already decided glibc (see spec §3 and the glibc-vs-musl analysis) because Klipper's input-shaper path pulls in **numpy** and the scientific-Python C-extension graph, and the proven AD5M firmware (xblax) uses glibc — even enabling Fortran in its toolchain to build numpy/scipy from source.

musl + numpy is a documented friction point:
- numpy test failures on musl (trig functions, missing FP overflow/underflow exceptions),
- recurring "platform extension suffix" mismatches between numpy and Python on musl,
- general "works but with caveats" status.

Choosing Alpine = choosing musl = re-inheriting exactly the risk we rejected. Buildroot lets us stay on glibc with full control.

### 2. Immutable + reproducible vs mutable apk state
Firmware wants an **immutable, byte-reproducible image** for OTA integrity and supportability ("every unit on version X is bit-identical"). We just proved the Buildroot rootfs is reproducible (two clean builds → identical 47-file manifests, `BR2_REPRODUCIBLE=y`). Alpine's model is a **mutable rootfs** that drifts as `apk` runs; reproducibility is weaker and harder to guarantee. For a flashed firmware with OTA, immutable wins.

### 3. ABI matched to the runtime kernel — which we just exploited
Because Buildroot builds the toolchain too, we pinned **glibc against 5.4.61 kernel headers** to exactly match the stock kernel the rootfs rides in P1–P3 (otherwise glibc aborts "kernel too old" on-device). Alpine's binaries are built against Alpine's own musl + its chosen headers, not matched to our kernel — we'd lose that lever and the precise control over the min-kernel ELF note.

### 4. Surgical minimalism on 128 MB RAM
Buildroot builds **exactly** the packages the printer needs and nothing else. Alpine's base is small (~5–8 MB) but a working install (apk metadata + Python venv + the dependency closure) is heavier and less tailored. On a 128 MB device every MB of resident footprint matters; Buildroot's from-source minimalism is the tighter fit.

### 5. armv7 longevity
Alpine still ships **armv7** as of 3.23 (2025/2026) — but the project has *repeatedly* floated dropping 32-bit ARM since 2019. For a firmware meant to live for years, betting the userspace on a tier the upstream keeps eyeing for removal is a risk. Buildroot has no such tier politics — it builds whatever we point it at.

### 6. Integration & pinning
Buildroot gives one pinned, reproducible pipeline: toolchain → rootfs → kernel → U-Boot → `genimage` image, with `pins.lock` as the single source of truth. Alpine gives a rootfs; you separately build/track kernel + U-Boot + image tooling and reconcile apk state. More moving parts, weaker single-source pinning.

## Where Alpine would actually win

Honest accounting — Alpine is better when:
- **Iteration speed / no compiling.** `apk add py3-numpy` beats a 10-minute numpy cross-compile. Buildroot's from-source builds are slower to iterate (our toolchain rebuild is ~8 min).
- **Familiarity & a huge binary repo.** Easy to add arbitrary software later.
- **Mutable host model is desired.** If ReForge were a Pi-class, SD-card, apt/apk-managed host (mainsailOS / Debian style), Alpine/Debian would be the natural choice.

If we ever want a *mutable, apk-managed* ReForge variant for power users, Alpine is the candidate. It just isn't the immutable-firmware product we're building.

## Myth to retire

One blog claims "Moonraker can't run on Buildroot because it needs `ip` with JSON output and BusyBox doesn't provide it." That's only true for a **busybox-only** rootfs. Buildroot ships full **iproute2** as a package (real `ip`, JSON-capable), and the proven xblax firmware runs Moonraker + Mainsail on Buildroot. So this is a non-issue — just include iproute2 (Plan 2 will).

## Precedent

Every working AD5M Klipper firmware — **xblax** (klipper_mod), **zmod**, **forge-x** — uses the Buildroot/from-source model. **None** use Alpine. That's a strong empirical signal for this exact board and stack.

## Decision

**Keep Buildroot.** It's the correct tool for an immutable, reproducible, glibc-based, ABI-matched, surgically-minimal firmware image — which is precisely what ReForge is. Alpine remains a documented alternative *if and only if* the project's goal ever shifts to a mutable, package-managed host. Revisit only on that shift.

### Sources
- Alpine on ARM / armv7 status: https://wiki.alpinelinux.org/wiki/Alpine_on_ARM , https://www.howtogeek.com/alpine-linux-3-23-released/ , armhf-drop discussions on alpine-devel lists.
- numpy on musl/Alpine issues: numpy/numpy#7128, numpy/numpy#27932, astral-sh/uv#16349.
- Klipper on Alpine: github.com/knoopx/alpine-klipper.
- Buildroot Klipper precedent + the `ip`/Moonraker caveat: stefanocottafavi.com/buildroot_klipper3d ; xblax/flashforge_ad5m_klipper_mod.
</content>
