# ReForge — lab notebook

## 2026-06-04 — autoresearch loop: close the +128 B kernel-reproduction gap

Started experiment loop. Goal: drive `|bytes(Image.ours-linaro) - bytes(Image.stock)|`
to 0 (currently +128 B, from byte-identical reproduction work earlier this session).

Baseline: +128 B size delta, IKCONFIG.gz already byte-identical, first divergence
at file offset 0x15c (kernel Image header — likely embedded size constants that
shift with any code change downstream). 6.07 MB of cmp-diff dominated by
kallsyms address cascade — that's a noise floor, not a real metric.

Lever: `vendor/kernels/patches/0001-byte-identical-reproduction.patch`.
Build script applies/reverts; BSP submodule stays pristine at 349a0b9.

Dashboard: `autoresearch.md`. Per-iter log: `autoresearch.jsonl`.

### 2026-06-04 — autoresearch loop ended at iter 2 (diagnosis complete)

Loop stopped at iter 2 with the gap fully diagnosed but not closed.

**Root cause found**: kallsyms decoder revealed our build has 41 net extra
symbols (529 ours-only vs 490 stock-only). +824 B in kallsyms, −696 B in
non-kallsyms code → net +128 B. The cause is BSP submodule snapshot drift:
- IR driver renamed (`sunxi_ir_recv_*` → `sunxi_irrx_*`)
- Old `sunxi_pwm.c` chrdev driver removed (9 PWM functions gone)
- Bootlogo handoff helpers removed (3 functions)
- Realtek BT coex stack added (30 functions we now have, stock didn't)
- Newer-SoC plumbing added (sun20iw1, sun55i, DCXO, RTC v201)

All five changes left Kconfig identical → our IKCONFIG matched stock's
byte-for-byte, but the resulting `obj-$(CONFIG_*)` selections differ.
Not closable without the older BSP source snapshot (Auto SDK blocked on
Baidu link).

Confirmed my reconstructed `sunxi_can_asm.h` was a non-factor: zero
`sunxican_*` / `can_asm_*` symbols appear on the diff list. The earlier
hypothesis that the CAN reconstruction was responsible was wrong.

Artifacts:
- `autoresearch.md` — dashboard with full iter table + diagnosis
- `autoresearch.jsonl` — raw iter log
- `autoresearch.sh` — benchmark wrapper (`bash autoresearch.sh`)
- `outputs/kallsyms-symbol-diff.md` — full symbol-set diff with classification

Decision: documented current +128 B as the iLotusK9-vs-FF snapshot drift
ceiling and stopping. Will revisit if Auto SDK arrives.

### 2026-06-04 — autoresearch iters 3+4: substitution wins (size still +128 B)

After diagnosing the iter-2 symbol-set drift, ran two more iterations that
substitute the deltas we could close from public GitHub sources:

**Iter 3** — PWM substitution from ayueying/linux-5.4 @ 2022-09-08:
- Added `vendor/upstream-snippets/pwm-sunxi-g_dev/pwm-sunxi-g_dev.c`
  (5668 B, sha256 f53450ae74…, Copyright (C) 2019 AllWinner)
- Patch appends new file + Makefile line `obj-$(CONFIG_PWM_SUNXI_GROUP) += pwm-sunxi-g_dev.o`
- Result: all 9 stock-only PWM symbols (sunxi_pwm_class/dev/exit/fops/init/
  open/release/unlocked_ioctl + __initcall_sunxi_pwm_init6) now present in
  ours. Image total unchanged at +128 B. cmp_l_count −28 KB.

**Iter 4** — Realtek BT-coex stack removal:
- Comment out `#define BTCOEX` in drivers/bluetooth/hci_uart.h
- Drop `hci_uart-y += rtk_coex.o` from drivers/bluetooth/Makefile
- Result: all 30 BT-coex ours-only symbols (rtk_btcoex_*, rtk_handle_*,
  rtl_l2_*, udpsocket_*, etc.) gone. Net symbol Δ +41 → +15.
  cmp_l_count 6.07M → 5.92M (−2.5 %). first_diff_off 0x15c → 0xf968c
  (first MB now byte-identical to stock).

**Size delta diagnosis**: 128 B is a **256-byte linker alignment artifact**:
  ours mod 128 = stock mod 128 = 44 (same cache line)
  ours mod 256 = 44, stock mod 256 = 172 (Δ = 128)

The ~15 remaining net-extra symbols (sunxi_irrx_* IR rename, DCXO,
sun20iw1/sun55i newer-SoC, closed-source bootlogo helpers) tip ours past
a 256-byte alignment boundary, costing exactly +128 B of `.data` padding.

Closing this further requires either the Auto SDK source (3-5 specific
files, still blocked on broken Baidu link) OR finding a code change that
shifts us by exactly 128 B more (fragile, could land +256 or −128).

Patch now: `vendor/kernels/patches/0001-byte-identical-reproduction.patch`
26,719 B (was 19,293 B). Build script applies/reverts as before.
