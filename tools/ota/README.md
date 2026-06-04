# tools/ota — FlashForge update-server check

`check-ff-update.py` — read-only checker that asks FlashForge's official cloud update
server whether a newer AD5M / AD5M Pro firmware is offered for the version you're running.
It only **checks** — never downloads, unpacks, or flashes. Stdlib-only Python 3, so it runs
on the printer as-is.

Endpoints + request shapes were reverse-engineered from the stock `firmwareExe`; see
[`../../docs/reverse-engineering/firmwareexe-ota-update.md`](../../docs/reverse-engineering/firmwareexe-ota-update.md).

## Use

```sh
# off-device: give it the version you're running
python3 check-ff-update.py --version 3.1.3 --name Adventurer5Mpro

# on the printer: autodetect version + identity from the stock filesystem
python3 check-ff-update.py --auto

# machine-readable
python3 check-ff-update.py --version 3.1.3 --json
```

Channels: `v2` (default, `update.voxelshare.com`), `v2-cn` (`api.voxelshare.com`),
`legacy` / `legacy-cn` (`update[.cn].sz3dp.com:10443`). The `dev` channel
(`http://10.33.11.172:32112`, the plaintext internal server compiled into the stock binary)
is **blocked** unless you pass `--allow-dev`.

Exit codes: `0` up to date · `10` update available · `1` error.

## Live API (probed 2026-06-04)

The current server is **`GET https://update.voxelshare.com/api/updates/check?appId=&platform=&version=&entityId=&hardwareVersion=`**
(POST → `405`). It answers a `{"code","message","data"}` envelope: `code` `0`/`200` + a
`data` object = a release; `code` `1306` ("Latest release version not found") + `data:null`
= no release for that `appId`/`platform`. `appId` and `platform` must be **non-empty
numbers** (the backend casts them to `java.lang.Long`).

**Blocker (reverse-engineered, not guessed):** `app_id`/`platform`/`entity_id` are runtime
`int` members of `PackageUpdateInfo` (`%d` in the URL), **initialised to `-1` and
cloud-provisioned** via device registration — they are *not* constants in the firmware, not
in its cloud config, and not parsed from any JSON key. The binary only hardcodes the
printer's **USB VID `0x2B71` / PID `0x0024`** (Adventurer 5M Pro, in
`UpdateManager::checkUpdate`); the voxelshare backend maps a registered device's `app_id`
server-side. So the version list **cannot be enumerated offline** — supply the real ids via
`--app-id`/`--platform` read off a registered AD5M Pro (or captured from its check request).
Full teardown: `../../docs/reverse-engineering/firmwareexe-ota-update.md`. The legacy `sz3dp`
endpoints are unreachable (connection refused).

## Security

The stock update path it talks to verifies firmware with **MD5 only — no signature** — and
runs an in-package `run.sh` as root. This tool just reports availability; do **not** wire its
output into an auto-flasher. ReForge's own OTA (signed) is the intended update path.

## Tests

```sh
python3 test_check_ff_update.py            # unit + fuzz (FUZZ_ITERS=2000 default)
FUZZ_ITERS=20000 python3 test_check_ff_update.py
```

Every function has an example-based unit test and a randomized fuzz test (version ordering
is property-checked for total order; parsers are fuzzed for no-crash on arbitrary input).
Network is never touched — the transport is injected.
