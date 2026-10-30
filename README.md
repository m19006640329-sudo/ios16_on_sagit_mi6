# iOS 16 on Xiaomi Mi 6（`sagit` / MSM8998）

把 [luuu20309/ios16_on_polaris_mix2s](https://github.com/luuu20309/ios16_on_polaris_mix2s)
（小米 MIX 2S / `polaris` / SDM845）的 XNU + iPhone X 用户态方案移植到
**小米 6（`sagit`，骁龙 835 / MSM8998）**。仓库里的 ADT、设备树、boot shim、
启动参数、XNU 补丁、打包工具和文档都已改为 sagit。

> **当前状态（2026-10-30）**
>
> - **源码移植已完成**：`tools/mkadt.py --sagit`、`shim` 的 `SAGIT` 平台、
>   小米 6 设备树尾、XNU 补丁 `0082-sagit-mi6-xnu-port.patch`（板型门控 / 显示
>   缩放 / RMI4 触摸）、sagit 启动参数与打包脚本；补丁已在
>   `xnu-8796.141.3` 上顺序 `git apply` 验证通过（全系列 0001–0082 无冲突）。
> - **可离线构建的产物**：`out/sagit.adt`、`out/sagit-dtb.bin`、
>   `out/shim-sagit-boot.img`（探针镜像，不含内核，不写分区）。
> - **未完成/未验证**：本环境没有 macOS/Xcode，无法编译 XNU；也**没有连接
>   小米 6 真机**，因此「开机进桌面 + 触摸」尚未在硬件上验收。内核需在
>   macOS 或 GitHub Actions 上编译（工作流已配置），再打包成完整 boot 镜像。
> - 没有 GPU（Adreno 540 无驱动，CPU framebuffer 合成）、没有 Wi‑Fi/基带/
>   音频/相机/传感器/SEP。GPU 部分（原 A630 代码）已从 sagit 分支移除。

## 1. 与 polaris 版的差异（全部已改）

| 项目 | polaris（MIX 2S） | sagit（小米 6） |
| --- | --- | --- |
| SoC / CPU | SDM845，4×A55 + 4×A75 | MSM8998，4×A53 1.9GHz + 4×A73 2.45GHz |
| ADT 板型 | `--polaris`，`xiaomi,polaris` + `qcom,sdm845` | `--sagit`，`xiaomi,sagit` + `qcom,msm8998` |
| 面板 | 1080×2160 | 1080×1920 |
| splash framebuffer | 0x9d400000 | **0x9d600000**（36MiB，stride 4320） |
| UFS 控制器 | 0x1d84000 | **0x1da4000** |
| GIC redistributor | 0x17a60000 | **0x17b00000** |
| 触摸 | Synaptics S3330，GPIO33/34，reset99 | S3330/S3331/TD4322 RMI4 @0x20，**GPIO87/88**，reset89，IRQ125 |
| 触摸 I²C | QUPv3 SE14 时钟域 | BLSP1 QUP5（0xc179000），TLMM EAST tile 0x03d00000 |
| boot.img 头 | v1/4096，dtb 0x1dea000 | v1/4096，**dtb 0x1e00000**，payload 上限 0xE00000 |
| XNU 补丁 | 0082–0093（12 个） | **0082-sagit-mi6-xnu-port.patch**（合并为 1 个） |
| 启动参数 | `sweetfb_polaris`、`polaristouch*` | `sweetfb_sagit`、`sagittouch*` |

XNU 仍使用上游的 `SWEET` machine config（`config/MASTER.arm64.sweet`），
板级差异全部由 ADT + 启动参数 + 这一个补丁完成；内核二进制名仍是
`kernel.development.sweet`。**不要**把它当成"给 Redmi 用的镜像"。

## 2. sagit 关键参数

| 项目 | 值 |
| --- | --- |
| 平台 | Qualcomm MSM8998（4×Cortex-A53 + 4×Cortex-A73，Adreno 540） |
| 设备树身份 | iPhone X `D22AP` / `iPhone10,3`（用户态） |
| 逻辑显示 | 1125×2436，按高度缩放到 1080×1920，左右各 97px 黑边 |
| 物理面板 | 1080×1920，stride 4320，BGRA |
| splash | `0x9d600000`，长 36MiB（`0x2400000`） |
| UFS | `0x1da4000`，LUN 0，GPT 分区名 `userdata` |
| GIC | distributor `0x17a00000`，redistributor `0x17b00000` |
| 高位内存 | `0x100000000` + `0x7cc00000`（6GB 安全；4GB 机型用 `--ram 4`） |
| 定时器 | 19.2MHz，虚拟定时器 PPI 19 |
| 触摸 | Synaptics RMI4 0x20；SDA GPIO87，SCL GPIO88，reset GPIO89，IRQ GPIO125 |
| 触摸供电 | `disp_vddts` GPIO50（ABL 通常已开），VDD L6A 1.8V |
| boot 头 | v1，pagesize 4096，kernel 0x8000，ramdisk 0x1000000，tags 0x100，dtb 0x1e00000 |

## 3. 先跑探针镜像（不写任何分区）

`out/shim-sagit-boot.img` 是**不含 XNU** 的诊断镜像：接管屏幕，打印板型、
内存、UFS GPT，约 3 分钟后自动重启。它只读 UFS，不写分区。

```sh
fastboot devices                 # 只能有一台
fastboot getvar product          # 必须是 sagit
fastboot boot out/shim-sagit-boot.img
```

预期屏幕（红色背景）：

```
SHIM    sagit milestone 4: xnu loader
BOARD   Qualcomm Technologies, Inc. MSM 8998 v2 ...
RAM     hi=00000001 lo=00000000
RAM     MiB=... idx=0
...
UFS PART userdata lba=... MiB=...
UFS     probe done, reset in ~3 min
```

- `BOARD` 是 MSM8998 且 `RAM` 有高位段 → DTB/ABL 链路正常。
- 屏幕能显示 → `0x9d600000` 这个 framebuffer 地址对该固件成立。
- 若黑屏但 3 分钟后会自动重启，说明 shim 在跑、只是 FB 地址不对：把
  `shim/console.h` 的 `FB_BASE` 改成 `0x9d400000` 重新 `PLATFORM=sagit shim/build.sh`。
- 若 `fastboot boot` 直接报错，先确认 bootloader 已解锁、`product=sagit`。

## 4. 编译内核（macOS / GitHub Actions）

> 完整逐步教程（PAT、上传脚本、构建、打包、刷机、触摸调试）：
> [docs/STEP-BY-STEP-ZH.md](docs/STEP-BY-STEP-ZH.md)

XNU 只能在 macOS 上编译。仓库自带 `.github/workflows/xnu.yml`：

1. fork / push 本仓库到自己的 GitHub；
2. Actions → **xnu** → Run workflow：
   - `kernel_config=DEVELOPMENT`（触摸调试）或 `RELEASE`（体积小）；
   - `machine_config=SWEET`（保持默认，sagit 复用该配置）；
3. 产物 `kernel.development.sweet` / `kernel.release.sweet` 下载到
   `xnu/out/`，核对 SHA-256。

补丁序列 0001–0082 已在本机对 `xnu-8796.141.3` 全量 `git apply` 验证；
**尚未在本环境编译**（没有 Apple SDK/clang）。CI 若报错，先确认补丁按编号
全部应用、`bsd/conf/files` 含 `sagit_touch_diag.c` 与 `sagit_touch_i2c.c`。

## 5. 打包完整 boot 镜像

一条命令：

```sh
tools/build-sagit-boot.sh xnu/out/kernel.development.sweet 6
# RAM 4 用于 4GB 机型；脚本会生成 ADT/payload/boot.img 并解包核对
```

等价的逐步命令：

```sh
# 1) ADT（6GB 机型；4GB 机型用 --ram 4）
python3 tools/mkadt.py out/sagit.adt --sagit --ram 6

# 2) payload（内核 + ADT + 启动参数）
python3 tools/mkpayload.py xnu/out/kernel.development.sweet \
  out/sagit.adt out/sagit-payload.bin \
  --check-sagit-cpus --max-payload-size 0xE00000 \
  --cmdline 'debug=0xc serial=3 cpus=4 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_sagit=1 sweettouch=0 sweetkeys=0 sagittouchdiag=1 sagittouch=1 sagittouchhid=1 sagittouchreset=1'

# 3) shim + Android boot.img（自动追加 dtb/sagit/*.dtb）
PLATFORM=sagit shim/build.sh out/sagit-payload.bin

# 4) 解包核对
python3 tools/unpack_bootv2.py out/shim-sagit-xnu.img out/check-sagit
cmp out/check-sagit/ramdisk out/sagit-payload.bin
sha256sum out/shim-sagit-xnu.img
```

`out/sagit-dtb.bin` 默认由 `dtb/sagit/*.dtb`（MiCode msm8998 设备树编译，
board-id 30/0，v2 与 v2.1）拼成；也可以从**你自己手机的原厂 boot.img** 提取：

```sh
python3 tools/sagit_dtb.py --from-boot backup/boot.img out/sagit-dtb.bin
```

CPU 先按 `cpus=4`（A53 簇）启动；确认能进系统后再试 `cpus=8`。`--check-sagit-cpus`
只校验 ADT/命令行连续前缀，不证明 PSCI 真的拉起了核心。

## 6. iOS 根镜像与刷写

根镜像仍需你自己合法取得 iPhone X（D22AP）iOS 16.7.16 IPSW，用
`tools/mkiosroot.sh` + `tools/sweet-root-tweaks.py` 在 Linux 上生成
`ios16-root.simg`（脚本名沿用历史，内容对 sagit 同样适用）。完整步骤见
[docs/COOLAPK-SAGIT-INSTALL.md](docs/COOLAPK-SAGIT-INSTALL.md)。

**会清空数据**：`fastboot flash userdata` 覆盖 Android 用户分区；`flash boot`
替换原启动镜像。先备份 `boot`、`persist`、`modemst*` 等，确认能恢复。

## 7. 已知限制

- 触摸驱动是「GPIO bit-bang RMI4 + F12 8 字节对象」的移植：引脚/复位/时钟域
  已按 MiCode 与主线 DTS 改好，但**未在真机验证**；小米 6 有 S3330/S3331/
  TD4322 三种触摸批次，F12 固件布局可能不同，驱动已放宽 PDT 校验并打印原始帧。
- 显示为 CPU 软件合成/缩放，没有 GPU、没有硬件视频加速。
- 没有 Wi‑Fi、蓝牙、蜂窝、音频、相机、传感器、GPS、SEP/Face ID。
- 安全机制大幅放宽（AMFI/沙箱/AppleKeyStore 桩），**不要存放个人数据**。

## 8. 验证

```sh
python3 tools/validate-repo.py
python3 -m unittest tools/test_sagit_cpu_topology.py -v
python3 -m py_compile tools/*.py
```

## English

Port of the Polaris (Mi MIX 2S, SDM845) XNU/iOS-16 bring-up to the Xiaomi Mi 6
(`sagit`, MSM8998): new `--sagit` ADT profile (MSM8998 CPU nodes, 1080x1920,
0x9d600000 splash, UFS 0x1da4000, GICR 0x17b00000), a `SAGIT` shim platform,
Mi 6 device-tree tail (board-id 30/0), sagit boot arguments and a single
consolidated XNU patch (`0082-sagit-mi6-xnu-port.patch`) replacing the twelve
Polaris display/touch/GPU patches. The patch series applies cleanly to
xnu-8796.141.3. The XNU kernel itself still has to be compiled on macOS/CI
(no Apple toolchain here), and **no Mi 6 was attached**, so boot-to-springboard
and touch are not yet hardware-validated. Probe image `out/shim-sagit-boot.img`
is read-only and safe to `fastboot boot`.
