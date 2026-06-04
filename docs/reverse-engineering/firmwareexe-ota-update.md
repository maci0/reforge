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

## Live server probe (2026-06-04)
Confirmed against the running production server:
- `getCheckParamJson` (the shipping 5.1.4 client) posts JSON keyed
  **`SN/VID/PID/Name/OEMName/Version/BuildTime/HardwareVersion/{Kernel,Control,Library,Software}Version`**
  (`Version` formatted `%d.%d.%d`, `BuildTime` `%Y-%m-%d %H:%M:%S`).
- The **live** server has migrated past that scheme: update check is now
  **`GET /api/updates/check?appId=&platform=&version=…`** (POST → `405`), replying a
  `{"code","message","data"}` envelope. `appId`/`platform` are required **numeric** ids
  (`java.lang.Long`); `code 1306` = "Latest release version not found".
- The AD5M Pro `appId`/`platform` are **not** in the 5.1.4 binary (older scheme) and a
  bounded brute (appId 1–400) didn't surface them — needs a captured live request.
- Legacy `update[.cn].sz3dp.com:10443` + `hz.sz3dp.com:11002` are unreachable (refused).
