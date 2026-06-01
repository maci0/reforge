# Backlog

Ideas/tasks not yet scheduled into a plan.

## microgit — a tiny git client (Zig) for Moonraker's update_manager

**Why:** Moonraker's `git_repo` updater shells out to the full `git` CLI. Shipping real
git costs ~5–10 MB rootfs (git + `git-remote-https` + libcurl) just to satisfy one consumer.
A purpose-built client that implements *exactly* what Moonraker calls — and nothing else —
could be a fraction of that.

**Exact surface Moonraker requires** (from `moonraker/components/update_manager/git_deploy.py`,
verified 2026-06-01): the client is invoked as `git -C <path> <cmd>` and its **stdout/exit
codes are parsed**, so output must be byte-compatible with real git for:

| subcommand | form used |
|---|---|
| clone | `clone --branch <b> --filter=blob:none <url> …` (**partial clone** — needs the GitHub partial-clone protocol) |
| fetch | `fetch --all -p` / `fetch <remote> --prune --progress` |
| pull | `pull --progress` |
| checkout | `checkout -q <branch>` |
| reset | `reset --hard <ref>` |
| clean | `clean -d -f` |
| branch | `branch --list --no-color` |
| remote | `remote <get-url/set-url>` |
| config | `config <args>` |
| for-each-ref | `for-each-ref … --sort='-creatordate' --contains=HEAD` |
| rev-parse | `rev-parse <args>` |
| rev-list | `rev-list <args>` |
| describe | `describe <args>` |
| cat-file | `cat-file -e <commit>^{commit}` |
| merge-base | `merge-base --is-ancestor <a> <b>` |
| log | `log <current>..<ref>` |
| status | `status --porcelain -b` |
| fsck | `fsck --full` |

**Hard parts (why it's non-trivial):**
- **Smart-HTTP transport over TLS** to GitHub (the bulk of the work): pkt-line protocol,
  `git-upload-pack`, ref advertisement, want/have negotiation.
- **Partial clone** (`--filter=blob:none`) — blob-filtering + on-demand blob fetch.
- **Pack/delta**: parse packfiles, apply ofs/ref deltas, zlib inflate, verify SHA-1.
- **Output compatibility**: `status --porcelain`, `for-each-ref --format`-style output,
  `describe`, `rev-list` counts must match git's text exactly (Moonraker parses them).
- Loose+packed object store, refs, basic config.

**Scope notes:** read-mostly (no push, no merge, no rebase, no working-tree staging beyond
checkout/reset/clean). Could lean on libz (or Zig's deflate) + the system TLS already present.

**Status:** idea only. Lower priority than the OTA design below — if reforge OTA ships via
self-published `zip` releases (no git on device), this is unnecessary; it only matters if we
want true upstream `git_repo` OTA.

## reforge OTA design (decide before implementing)

Shipping `git` does **not** enable host (klipper/moonraker) OTA on the buildroot image:
`/opt/*` are not git checkouts, there's no `pip`, and no `gcc` (klipper's chelper recompiles
on source change). Working options:

1. **`web` updater for Mainsail** — git-free, works today (Mainsail ships GitHub release zips).
2. **`zip` updater against our own prebuilt reforge releases** — publish bundles in CI with the
   correct thumb2/NEON `c_helper.so` (timestamped so klippy won't recompile) + vendored deps;
   no git/gcc/pip on device. This is the clean path to full host OTA.
3. Status quo: USB `.tgz` reflash (no OTA).
