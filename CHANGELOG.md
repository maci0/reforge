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
