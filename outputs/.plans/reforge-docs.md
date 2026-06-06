# Audit plan — `@reforge/docs` vs code

**Slug:** `reforge-docs`
**Artifact target:** `outputs/reforge-docs-audit.md` (exactly one)

## What is being audited

This is **not** a third-party academic paper audit. The "paper" is ReForge's
own design + reverse-engineering documentation under `docs/` (67 markdown
files, ~8 thousand lines). The "code" is the same repository's implementation
(`br-external/`, `packaging/`, `Makefile`, `tools/`).

So the audit is a self-consistency check: are the claims our docs make about
what ReForge does — paths, scripts, modes, file layouts, OTA mechanism,
security posture — accurate against the code as it currently exists?

## Scope (which claims to verify)

### Tier 1 — load-bearing claims a user/dev would rely on

| Doc | Claim category | Code to check against |
|---|---|---|
| `docs/architecture.md` | chroot model, paths, runtime services | `.shell/reforge-boot`, `etc/init.d/S60klipper`, `etc/init.d/S65moonraker`, `packaging/flashforge_init.sh` |
| `docs/boot.md` | intervention table (8 rows), what fires when | `etc/init.d/S??`, `sbin/reforge-init`, `packaging/live/flashforge_init.sh` |
| `docs/deployment-modes.md` | three modes; what each actually does today | `packaging/{flashforge_init.sh,live/flashforge_init.sh}`, `sbin/reforge-init` |
| `docs/security-findings.md` | per-mode closure status of 15 RE findings | the `firmwareExe` cloud-block in `reforge-boot`, `/etc/hosts`, no PID-1 swap yet |
| `docs/board-notes/partition-map.md` | GPT layout vs golden image | `tools/recovery/golden.img.gz` (just-cleaned), `tests/qemu-harness/lib/build-emmc-image.sh` |
| `docs/ota.md` | OTA mechanism today | `tools/release/build-release.sh`, `br-external/package/moonraker/`, the new immutable plan |
| `packaging/README.md` | installer flow (steps 1-3 of Install Flow) | `packaging/flashforge_init.sh` (especially the new `pre_install_conflict_check`) |

### Tier 2 — important, smaller surface

| Doc | Claim category |
|---|---|
| `docs/live-mode.md` | live-USB launcher behavior |
| `docs/build-process.md` | pins → fetch → buildroot → image → tgz |
| `docs/REPO-LAYOUT.md` | repo layout matches reality |
| `docs/plans/2026-06-05-immutable-reforge.md` | the just-written plan; check the cited evidence base is real |
| `docs/research/2026-06-05-overlayfs-on-bsp-spike.md` | the just-written spike; numbers match what the test harness actually produced |

### Tier 3 — out of scope (reverse-engineering notes about stock)

The 13 files under `docs/reverse-engineering/` describe the *stock* firmware
(QT4 `firmwareExe`, stock kernel, etc.). They aren't claims about ReForge's
implementation, so they're not subject to docs-vs-code mismatch. We spot-check
that the 15 security findings in `docs/security-findings.md` actually match
what the RE notes say, but don't re-verify the RE notes themselves.

Plans / specs / older research notes get a quick consistency check (do the
files they reference still exist? do the commits they cite exist? are the
numbers they cite still current?) but no deep dive.

## What we're looking for

1. **Direct mismatches** — doc claims a path or a script line that doesn't
   match reality. E.g. "the chroot is at `/data/.mod/.reforge/mod/`" vs the
   actual chroot path in `reforge-boot`.
2. **Phantom features** — doc describes behavior the code doesn't yet have.
   E.g. "the installer refuses to install over forge-x" — does
   `flashforge_init.sh` actually have `pre_install_conflict_check`?
3. **Stale documentation** — doc was correct at write-time but has since
   drifted from code (e.g. a path migration the docs missed).
4. **Ambiguous defaults** — doc says "by default X" but code chooses Y, or
   code has multiple defaults that depend on environment.
5. **Reproduction risks** — claims of build reproducibility / test PASS
   that can be falsified by running the test.

## Method

1. Three parallel `researcher` subagents gather evidence:
   - **R1**: runtime story — `docs/{architecture,boot,deployment-modes,live-mode}.md` vs `.shell/`, `etc/init.d/`, `packaging/live/`.
   - **R2**: integrity story — `docs/{security-findings,ota.md,board-notes/partition-map.md}` vs `reforge-boot`, OTA tooling, golden GPT.
   - **R3**: build + install story — `docs/{build-process,REPO-LAYOUT}.md`, `packaging/README.md`, the two recent plans/research notes vs `Makefile`, `packaging/flashforge_init.sh`, `tools/release/build-release.sh`, the qemu test harness.

2. One `verifier` pass: any URLs / file paths / commit SHAs cited in the
   audit get checked for existence + correctness.

3. Synthesise the three research outputs + verifier corrections into
   `outputs/reforge-docs-audit.md`. Structure:
   - Executive summary (top-line findings)
   - Per-doc audit notes (one section per Tier-1 doc)
   - Cross-cutting issues (paths/migrations/stale links)
   - Reproduction risks
   - Sources

## Non-goals

- Not auditing the reverse-engineering findings themselves (those describe
  stock firmware, not our code).
- Not running the full build (~30 min) or the full qemu test suite to verify
  every PASS claim. Spot-check the load-bearing ones only.
- Not rewriting any docs. The audit is read-only; fixes are follow-up work
  for the user to commission.
