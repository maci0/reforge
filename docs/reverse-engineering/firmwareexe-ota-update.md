# firmwareExe — OTA / firmware-update path (and why it's insecure)

Reverse-engineered from `firmwareExe` (not stripped). OTA logic lives in `common/UpdateManager.cpp`
(Qt `UpdateManager`) on top of the **`ffupserver`** namespace (~85 methods, a libcurl-based cloud
update *client* — despite the name it opens no port). Directly informs ReForge's own OTA design.

## TL;DR security verdict
**Firmware is MD5-checked only — NO cryptographic signature verification on the update path.** The
RSA/openssl code in the binary is for cloud *account binding* (`UI/qrencodeApp.cpp`) and *Polar
Cloud* challenge signing (`cloud/PolarClient.cpp`), **not** firmware. An attacker who serves a
tampered package (or MITMs the download) and ships a matching `md5sum.list` can push **arbitrary
unsigned firmware**, unpacked into `/opt/PROGRAM/...` and executed as root via `system(".../run.sh")`.
A **plaintext-HTTP dev update server is compiled into the shipping binary**.

## 1. Update check
Two endpoint generations:
- **v2 (voxelshare/dev):** `https://update.voxelshare.com/api/updates/check` and
  **`http://10.33.11.172:32112/api/updates/check`** (internal dev server, plaintext HTTP, shipped).
  POST JSON (`getCheckParamJson`); download-URL GET query `?app_id=&platform=&version=&entity_id=&hardware_version=`.
  Response fields: `message`, `detail`, `language`, `changelist`, `force_update`, `version`.
- **legacy (sz3dp):** `https://update.sz3dp.com:10443` / `update.cn.sz3dp.com:10443` path `/update`,
  `hz.sz3dp.com:11002`. Request: `ClientSN/Name/OEM/Version/BuildTime/Hardware`. Response:
  `KernelPackage/ControlPackage/LibraryPackage/SoftwarePackage` + per-component versions/descriptions.
- Runs on a worker thread (`UpdateManager::startCheckUpdatePthread`→`ffupserver::checkThreadFunc`);
  on hit emits `sig_findNewVersion()` → `UpdateMainDialog::findNewFirmware()`.

## 2. Download
- `UpdateManager::downloadLatestVersion()` → `ffupserver::UpdateServerImpl::download(...)` →
  `downloadThreadFunc`, per-component progress CBs (kernel/control/library/software).
- Download URL via `/api/updates/v2/download_url`; payload ultimately from **Alibaba OSS**
  (aliyun-sdk-cpp linked).
- **Package format = per-component `.tar.xz`** (`kernel-`/`control-`/`library-`/`software-`+ver+`.tar.xz`).
  Four `PackageType`s. No signed-container format.
- Staging under **`/opt/PROGRAM/{kernel,control,library,software}/`**; `software/` holds versioned
  subdirs. Temp-then-swap: `decompressPacketToTempDir()` → `renameTempDirToVersionDir()`.

## 3. Integrity — MD5 only, no signature
`common/UpdateManager.cpp` string group: `tar -xvf`, `rm -rf`, `/run.sh`, `software/`, `kernel-`,
`.tar.xz`, `/md5sum.list`, `md5sum.list check error.`, `system`. Functions: `getFileMD5SUM`,
`checkPacketDamage`, `checkAllPacketDamage`, `checkDecompressedPacketDamage` — each compares against
the package's bundled **`/md5sum.list`** (attacker-controlled, travels inside the package).
The only RSA/verify primitives in the binary belong to qrencode cloud-binding and PolarClient
challenge — **not firmware**. **Consequence: no firmware authenticity.**

## 4. Apply / flash
`startInstallUpdatePackets()` → `upgradeFirewareToPrinter()`:
1. MD5-verify each `.tar.xz` vs `/md5sum.list`.
2. `system("tar -xvf <pkg>")` into temp dir, re-verify extracted files.
3. `renameTempDirToVersionDir()` swaps into `/opt/PROGRAM/software/<version>/` (+ kernel/control/
   library), `rm -rf` old.
4. `system(".../run.sh")` — the per-package install/activation script **shipped inside the
   (unsigned) package**, run as root → tampered package = direct root RCE.
   Then `sig_upgradeCompleted()` → reboot.
- **No A/B or recovery partition.** (`RecoveryProgressDialog`/`checkz` = print-resume-after-power-loss,
  NOT firmware recovery. `mainStartUncompress`/`UncompressDialog` = 3MF/gcode job extraction.
  `checkAppFrist`/`checkZFrist` = Config first-run UI flags.)

## ffupserver role
Embedded cloud-update *client* (libcurl). `NetworkManager::{get,post,download}`,
`UpdateServerImpl::{checkUpdate,checkUpdateForNewServer,download,getUpdateDownLoadUrl,feedback}`,
types `CheckParam/ResponseResult/PackageUpdateInfo/DownloadParam/PackageType`. No listen/bind.

## Security issues → ReForge OTA requirements
1. **Add real firmware authenticity**: detached signature (Ed25519 / RSA-PSS) over the whole package
   with a baked-in trusted pubkey, verified **before** unpack. Never trust an in-archive checksum
   manifest as the trust root.
2. Strip dev endpoints (`http://10.33.11.172:32112`) from production.
3. Even HTTPS-to-OSS without payload signing = arbitrary firmware if the bucket/check server is abused.
4. `system("tar")` + `system("run.sh")` is root RCE by design — signing must cover `run.sh`.
5. Use SHA-256+ (MD5 is broken) and only as a post-signature corruption check.
6. Consider dual-bank A/B with rollback (current flow can brick on a bad swap).

## Companion tool
`tools/ota/check-ff-update.py` — read-only checker built from this teardown: queries the
v2/legacy endpoints above, compares the advertised version against the running one, reports
availability (never downloads/flashes). See `tools/ota/README.md`.

## Update-check request — full RE (2026-06-04)

Two request generations live in the binary; the live server only honours the newer one.

**Old scheme** — `ffupserver::UpdateServerImpl::getCheckParamJson` POSTs JSON keyed
`SN / VID / PID / Name / OEMName / Version / BuildTime / HardwareVersion /
{Kernel,Control,Library,Software}Version` (`Version` = `%d.%d.%d`, `BuildTime` =
`%Y-%m-%d %H:%M:%S`). The production server now answers **`405`** to POST, so this path is dead.

**New scheme** — `ffupserver::UpdateServerImpl::checkUpdateForNewServer` builds a **GET**:

```
/api/updates/check?app_id=%d&platform=%d&version=%d.%d.%d&entity_id=%d&hardware_version=%s
```

(internal validation string: `invalid params(vid|pid|packageVersions)`.) Response is a
`{code,message,data{list[{version, changelist, force_update, language(zh-CN/en), detail}]}}`
envelope; `code 1306` = "Latest release version not found".

**The real request — captured from a live AD5M Pro (2026-06-04).** Resolved by preloading a
libcurl `CURLOPT_URL` logger into the stock firmwareExe (`LD_PRELOAD` via its `env.cfg`) and
reading the boot-time check it logs:

```
https://update.voxelshare.com/api/updates/check?app_id=38&platform=29&version=2.1.6&entity_id=SNMOME9701306&hardware_version=2.0.0
```

So for the **AD5M Pro**: `app_id=38`, `platform=29` (FlashForge **product constants** baked
into firmwareExe — they are the `38`/`29` immediates visible in
`UpdateManager::checkUpdate`, alongside the printer's USB **VID `0x2B71` / PID `0x0024`**,
name `Flashforge Adventurer 5M Pro`, and `hardware_version=2.0.0`). `entity_id` is the
printer **serial number** (`SNMOME…`, a *string*) — **not** a cloud-assigned int, which is
why the check needs no cloud account. Params are **snake_case** in the wire request even
though the server's Spring validator also accepts the camelCase `appId`/`platform` names.
(This corrects an earlier hypothesis that the ids were cloud-provisioned `-1` defaults.)

**Server answer.** Replaying the exact request returns `{"code":1306,"message":"Latest
release version not found","data":null}` for every `version` (incl. `0.0.1`) — i.e.
FlashForge currently publishes **no release on voxelshare for `app_id=38`/`platform=29`**, so
the printer's own check shows "no update". A parsed `1306` (not a `401`) confirms it isn't an
auth/header gate. Legacy `update[.cn].sz3dp.com:10443` + `hz.sz3dp.com:11002` are unreachable
(refused). The companion tool bakes these constants in: `check-ff-update.py --model ad5m-pro`.
