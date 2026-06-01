# docs/

| path | what |
|---|---|
| [`REPO-LAYOUT.md`](REPO-LAYOUT.md) | **source of truth** for the repo structure (product / vendor / lab) |
| [`BACKLOG.md`](BACKLOG.md) | unscheduled ideas (e.g. the Zig microgit; reforge OTA design) |
| `specs/` | design specs (dated) — archival snapshots |
| `plans/` | implementation plans (dated) — archival snapshots |
| `research/` | findings: memory experiments, T113 mainline support, stock recovery images, stock-UI spike, buildroot-vs-alpine, etc. |
| `board-notes/` | hardware probes + the captured stock kernel config |
| `screenshots/` | qemu-captured renders + the boot console / bootsplash (see its README) |

**Convention:** `specs/` and `plans/` are *snapshots* — they record paths/decisions as written
and are not rewritten on later refactors. `REPO-LAYOUT.md` reflects the current tree.
