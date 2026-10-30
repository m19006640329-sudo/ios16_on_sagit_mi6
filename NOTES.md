# iOS 16 on Xiaomi Mi 6 (sagit, MSM8998) - working notes

## 2026-10-30 — sagit port handoff

### Goal

Boot XNU 8796 + iPhone X (D22AP, iOS 16.7.16) userspace on Xiaomi Mi 6
(`sagit`, MSM8998) to the SpringBoard/lock screen with working touch.
Upstream base: `luuu20309/ios16_on_polaris_mix2s` (Mi MIX 2S-adapted
ios-sweet). This repository is the sagit port; the Polaris-specific
patches/tools/docs were replaced.

### What is done (verified offline)

- `tools/mkadt.py --sagit --ram 6|4`: MSM8998 8-CPU nodes (kryo470+kryo280,
  1.9/2.45GHz), 1080x1920 splash at 0x9d600000, UFS 0x1da4000, GICR
  0x17b00000, root compat `D22AP iPhone10,3 xiaomi,sweet xiaomi,sagit
  qcom,msm8998 AppleARM`. Output `out/sagit.adt` 10048 B, dump checked.
- `shim` `SAGIT` platform: console FB 0x9d600000/1920, GICR 0x17b00000,
  UFS 0x1da4000, build.sh PLATFORM=sagit (gzip kernel + DTB tail,
  header v1/4096, dtb 0x1e00000, payload limit 0xE00000).
- `dtb/sagit/*.dtb`: compiled from MiCode `sagit-o-oss` DTS (v2.0, v2, v2.1)
  with dtc. board-id 30/0, msm-id 0x124+0x20000/0x20001, splash 0x9d600000.
  `tools/sagit_dtb.py` concatenates and validates them (also --from-boot).
- `out/shim-sagit-boot.img`: 1,253,376 B probe image (header v1, 4096,
  kernel+gzip shim+DTB tail, empty ramdisk). Unpacked and field-checked.
- `xnu/patches/0082-sagit-mi6-xnu-port.patch` (1307 lines): replaces the
  twelve Polaris display/touch/GPU patches. Adds `sagit_touch_diag.c`,
  `sagit_touch_i2c.c`, sagit board gates, `sweetfb_sagit` scaling to
  1080x1920 (886x1920 content, 97 px bars), RELEASE launchd gate, and the
  0083 early-fb logic renamed. Verified: 0001-0082 apply cleanly in order
  to `xnu-8796.141.3`; no polaris/sdm845 strings remain in C sources.
- Host tests: `python3 -m unittest tools/test_sagit_cpu_topology.py -v`.

### Not done / blockers

- **XNU is not compiled.** No macOS/Xcode/clang SDK in the Kali VM and no
  GitHub write access/token. `0082` has only `git apply` evidence. Use
  `.github/workflows/xnu.yml` on macOS (machine_config=SWEET) to build
  `kernel.development.sweet`.
- **Deployment blocker (2026-10-30):** this Windows host can reach
  `api.github.com` but **not** `github.com` (git push times out), and the Kali
  VM cannot reach github.com either. Use `tools/upload-to-github.ps1`, which
  creates the repo and uploads the tree through the REST API with a classic
  PAT (`repo` + `workflow` scopes) — no git and no github.com needed.
  `docs/PUSH-TO-GITHUB.md` has the steps. The `macos-14` runner image is
  deprecated and scheduled to be unsupported on 2026-11-02; run the build
  before that, otherwise fall back to a local macOS 14 VM with Xcode 15.4.
- **No Mi 6 attached.** Probe image, full boot image, touch, and boot to
  desktop are NOT hardware-validated. Do not claim otherwise.
- Touch is a port of the Polaris GPIO bit-bang RMI4 driver: SDA GPIO87 /
  SCL GPIO88 (TLMM EAST 0x03d00000), reset GPIO89, IRQ GPIO125. Mi 6 ships
  S3330/S3331/TD4322 touch variants; F12 layout may differ, so the PDT
  check was relaxed (F01 2c23, F12 49 + data base >=4) and raw frames are
  logged. Reset release no longer aborts if LK already released GPIO89.
- No GPU (Adreno 540), Wi-Fi, modem, audio, camera, sensors, SEP.

### Key numbers

| item | value |
| --- | --- |
| splash | 0x9d600000, 0x2400000, stride 4320 |
| UFS | 0x1da4000 |
| GICD/GICR | 0x17a00000 / 0x17b00000 |
| RAM (XNU managed) | 0x100000000 + 0x7cc00000 (4GB: 0x3cc00000) |
| boot header | v1, page 4096, kernel 0x8000, ramdisk 0x1000000, dtb 0x1e00000 |
| payload limit | 0xE00000 |
| touch | RMI4 0x20, GPIO87/88/89/125, VDDIO GPIO50 |

### Commands

```sh
python3 tools/mkadt.py out/sagit.adt --sagit --ram 6
python3 tools/mkpayload.py xnu/out/kernel.development.sweet out/sagit.adt \
  out/sagit-payload.bin --check-sagit-cpus --max-payload-size 0xE00000 \
  --cmdline 'debug=0xc serial=3 cpus=4 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_sagit=1 sweettouch=0 sweetkeys=0 sagittouchdiag=1 sagittouch=1 sagittouchhid=1 sagittouchreset=1'
PLATFORM=sagit shim/build.sh out/sagit-payload.bin
python3 tools/unpack_bootv2.py out/shim-sagit-xnu.img out/check-sagit
```

### Next concrete actions

1. On a Mac/CI runner: build the kernel (all 0001-0082 patches), download,
   verify SHA-256, package payload + boot image, temporary `fastboot boot`.
2. On the phone: probe image first (`fastboot boot out/shim-sagit-boot.img`);
   if black but it resets after ~3 min, rebuild with FB_BASE 0x9d400000.
3. Extract this phone's stock DTB (`tools/sagit_dtb.py --from-boot`) if the
   probe reports the wrong board/model.
4. Touch bring-up order: `sagittouchdiag=1` (read-only GPIO), then
   `sagittouch=1` (PDT/raw frames), then `sagittouchhid=1`.

### Environment

Kali 2026.3 VM (4 vCPU / 6GB) at `/home/kali`; host shares the workspace at
`/mnt/hgfs/ios16`. Installed: gcc-aarch64-linux-gnu 16.2, device-tree-compiler,
hfsprogs, android-sdk-libsparse-utils, python3. XNU source at
`/home/kali/src/xnu-xnu-8796.141.3`; patched test tree at
`/home/kali/src/xnu-port`. No Apple SDK and no usable macOS build host.

### Historical note

The previous 488-line NOTES covered the sweet/Polaris experiments (A630 GPU,
SE14 clock votes, touch F12 rings, 0090 phone test). Those apply to
different hardware and were removed from this branch; see the upstream
repository and this repo's git history.
