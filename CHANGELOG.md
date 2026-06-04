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
