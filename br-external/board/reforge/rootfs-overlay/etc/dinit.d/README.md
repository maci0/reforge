# ReForge dinit services (staged — not wired yet)

dinit service descriptions for the ReForge printer stack. **dinit is not PID 1
yet**: today the chroot boots via the sequential `/mod/start.sh` S-loop
(`reforge-boot`, see `docs/boot.md` §7). These files mirror that S-loop so that
when dinit takes over as the `switch_root` PID 1 it supervises the same services
with dependency ordering and restart-on-failure. Until then they are inert.

## Services

| service | type | what | source of truth |
|---|---|---|---|
| `boot` | internal | top-level target; depends on the core set | — |
| `prepare` | scripted | mkdir runtime dirs (`/var/log`, `/run`, moonraker logs) | inline |
| `cloudblock` | scripted | pin FF cloud hosts in `/etc/hosts` | `init.d/S00cloudblock` |
| `zram` | scripted | insmod + zram swap + VM sysctls | `init.d/S35zram` |
| `eboard` | scripted | one-time toolhead MCU handshake (before klipper) | `usr/bin/reforge-boot-eboard` |
| `klipper` | process | klippy host (no jemalloc) | mirrors `init.d/S60klipper` |
| `moonraker` | process | API/WS `:7125` (jemalloc) | mirrors `init.d/S65moonraker` |
| `httpd` | process | busybox httpd → Mainsail `:80` (`-f` foreground) | mirrors `init.d/S70httpd` |
| `camera` | process | ustreamer MJPEG `:8080` — **conditional** (`/dev/video0`) | mirrors `init.d/S72camera` |
| `guppyscreen` | process | LVGL touch UI — **conditional** (`SCREEN_MODE=GUPPY` + `/dev/fb0`) | mirrors `init.d/S75guppyscreen` |
| `ok` | scripted | services-up sentinel → promote mod to LKG | `init.d/S99ok` |

The one-shots deliberately call the existing `init.d/S*` scripts as their
implementation, so there is a single source of truth for the host-list, zram
setup and LKG logic. The daemons are rewritten as supervised foreground
processes (no `start-stop-daemon -b`, no pidfiles — dinit is the supervisor),
with per-service env applied via `env` since dinit execs the command directly.

`camera` and `guppyscreen` are defined but **not** in the `boot` target's
`depends-on`: they are conditional and will be started on demand by a future
`SCREEN_MODE` / camera selector.

## Validation

`tests/release/dinit-services-test.sh` lints these files (required keys present,
no dangling `depends-on`/`waits-for` targets). When wiring dinit for real,
also run the ARM `dinit-check` under qemu against this dir.
