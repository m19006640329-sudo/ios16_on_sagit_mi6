# 小米 6（sagit）运行 iOS 16：内核打包、iOS 构建与 boot / userdata 刷入教程

> **第一步：警告——本流程会永久清空手机数据。** `fastboot flash userdata` 会覆盖
> Android 用户分区（照片、聊天记录、应用、内部存储）；`fastboot flash boot` 会替换
> 原 Android 启动镜像。请先在手机外完成并验证备份：`userdata`、原厂 `boot.img`、
> `dtbo`、`vbmeta`、`persist`、`modemst1/2`、`fsg`、`fsc`。不要上传含设备标识的备份。
> **只适用于自己已解锁 bootloader 的小米 6（`sagit`，MSM8998）**；任何一步不确定就停下。
> 不要重新锁 bootloader。
>
> 本文是手工构建指南，**不是一键 ROM**。仓库不提供 XNU 内核二进制、iOS 镜像、
> Qualcomm 固件或原厂 DTB；它们要你在自己的 macOS/CI 与 Linux 上生成。
> 没有在真机上验证过本文组合出的镜像，永久 `flash boot` 风险高于临时 `fastboot boot`。

## 0. 准备与资料来源

- 源码：本仓库（`ios16_on_sagit_mi6`）。上游：[dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet)、
  [luuu20309/ios16_on_polaris_mix2s](https://github.com/luuu20309/ios16_on_polaris_mix2s)。
- 自己手机的原厂 `boot.img`：用于提取**匹配自己固件**的 DTB 和恢复。不要用别人的。
- 一台 macOS（或 GitHub Actions）编译 XNU；一台 Linux（≥40GB 空闲）做 iOS 根卷。
- 需要：Python 3、`aarch64-linux-gnu-gcc` 或 Zig、Android platform-tools、
  `apfs-fuse`/`hfsprogs`/`img2simg`（构建根卷）、`blacktop/ipsw`（提取 Apple 设备树）。
- 本仓库**不分发** Apple IPSW/用户态、iOS 根卷、Qualcomm 固件、原厂 DTB 或成品 boot.img。

## 1. 备份、核对设备、先跑探针镜像

进入 fastboot（关机后按住电源+音量下）：

```sh
fastboot devices            # 只能有一台
fastboot getvar product     # 必须是 sagit
fastboot getvar unlocked    # 必须是 yes
```

先跑**不写分区**的探针镜像，确认屏幕、内存、UFS：

```sh
fastboot boot out/shim-sagit-boot.img
```

屏幕应出现红色诊断页，包含 `SHIM sagit ...`、`BOARD ... MSM 8998 ...`、
`RAM hi=00000001`、`UFS PART userdata ...`，约 3 分钟后自动重启。

- 黑屏但会重启：shim 在跑，改 `shim/console.h` 的 `FB_BASE` 为 `0x9d400000`
  重新 `PLATFORM=sagit shim/build.sh` 再试（不同固件的 splash 地址可能不同）。
- 若 `BOARD` 不是 MSM8998 或没有高位 RAM：DTB 尾不对，换用你自己 boot.img 提取的 DTB。

## 2. 编译 XNU（macOS / GitHub Actions）

XNU 只能用 Apple 工具链编译。把本仓库推到自己的 GitHub，Actions → **xnu** →
Run workflow，选：

- `kernel_config=DEVELOPMENT`（推荐，保留调试输出；RELEASE 体积更小）
- `machine_config=SWEET`（保持默认；sagit 复用该 machine config）
- `keep_going=true`

下载产物 `kernel.development.sweet` 到 `xnu/out/`。它**不是 boot.img**，
不能直接刷 boot 分区。

## 3. 生成 ADT 与 payload

```sh
mkdir -p out
# 6GB 机型；4GB 机型把 6 改成 4
python3 tools/mkadt.py out/sagit.adt --sagit --ram 6
```

若你有 iPhone X（D22AP，iOS 16.7.16）的 IPSW，先取出
`Firmware/all_flash/DeviceTree.d22ap.im4p`，用 blacktop/ipsw 解封装到
`research/ipsw-x/d22ap.adt`，`mkadt.py` 会自动把 `/product` 节点并入；
没有它也能开机，但 `MobileGestalt` 的设备身份不完整。

```sh
python3 tools/mkpayload.py xnu/out/kernel.development.sweet \
  out/sagit.adt out/sagit-payload.bin \
  --check-sagit-cpus --max-payload-size 0xE00000 \
  --cmdline 'debug=0xc serial=3 cpus=4 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_sagit=1 sweettouch=0 sweetkeys=0 sagittouchdiag=1 sagittouch=1 sagittouchhid=1 sagittouchreset=1'
```

- `--max-payload-size 0xE00000`：ABL 把 ramdisk 放在 `0x1000000`、DTB 放在
  `0x1e00000`，中间只有 14MiB；超限必须停下。
- `cpus=4` 先只启动 A53 簇；能进系统后再改 `cpus=8` 试 A73。
- `sweettouch=0 sweetkeys=0` 必须保留（sweet 的 SE7/PMIC 驱动不适用于 MSM8998）。
- `sagittouch*` 是小米 6 的 Synaptics RMI4 路径（GPIO87/88，reset89）。

## 4. 打包完整 boot 镜像

```sh
PLATFORM=sagit shim/build.sh out/sagit-payload.bin
# 产物 out/shim-sagit-xnu.img

python3 tools/unpack_bootv2.py out/shim-sagit-xnu.img out/check-sagit
cmp out/check-sagit/ramdisk out/sagit-payload.bin
sha256sum out/shim-sagit-xnu.img
```

确认输出是 Android boot.img v1、pagesize 4096、内含 shim 内核与完全一致的
payload ramdisk。DTB 尾默认来自 `dtb/sagit/*.dtb`；若你的固件 DTB 不同，用
`python3 tools/sagit_dtb.py --from-boot backup/boot.img out/sagit-dtb.bin`
重新生成后再打包。

## 5. 临时启动（推荐先做）

```sh
fastboot boot out/shim-sagit-xnu.img
```

不写分区，重启即回原系统。要看到 iOS 界面还需要 userdata 里已有 iOS 根卷
（见第 6 节）；否则可能在挂载根文件系统时 panic，这不证明 boot.img 错误。
首次启动 Apple logo 阶段可能停留 5–10 分钟。

## 6. 构建 iOS 根镜像（Linux，单独进行）

从 Apple 官方渠道取得匹配 iPhone X（`iPhone10,3`，D22AP）的 iOS 16.7.16
(20H392) IPSW，按 `BuildManifest.plist` 解出 OS/SystemOS/AppOS 三个 DMG：

```sh
sudo apt install apfs-fuse hfsprogs rsync android-sdk-libsparse-utils
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo fsck.hfsplus -fy ios16-root.img
sudo mkdir -p /mnt/iosroot
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
sha256sum ios16-root.simg
```

`mkiosroot.sh` 生成区分大小写、带 journal 的 HFS+ 卷；`sweet-root-tweaks.py`
名字是历史沿用，处理的是 iPhone X 用户态。每个步骤都必须成功，失败就停。

## 7. 永久刷入（高风险，自选）

```sh
# 再次确认只有一台 sagit、备份可恢复
fastboot flash boot out/shim-sagit-xnu.img
fastboot -S 512M flash userdata ios16-root.simg
```

- 只写 `boot` 和 `userdata`；**不要**写 `recovery`/`dtbo`/`vbmeta`/`persist`，
  不要锁 bootloader。
- `userdata` 16GB 稀疏镜像通常 7–15 分钟；不要拔线。中途失败先回 fastboot，
  用自己备份的原厂 `boot.img` 恢复。
- 永久刷 boot 后 Android 通常无法启动；恢复需原厂 boot + 原厂固件。

## 8. 失败排查

| 现象 | 含义 / 处理 |
| --- | --- |
| `fastboot boot` 报 `Failed to load/authenticate boot image` | bootloader 未解锁或机型不符；停止 |
| 黑屏但约 3 分钟后重启（探针） | shim 在跑，FB 地址不对；改 `FB_BASE` 重试 |
| 红屏文字错位/斜条 | stride 不是 4320；记录照片，检查 DTB 的 panel 与 `FB_STRIDE` |
| 蓝屏 `PANIC ...` | shim 异常；拍下 `SLOT/ESR/ELR/FAR/STAGE` |
| 卡 Apple logo | 检查 ADT 是否含 `/product`、payload 是否超限、根卷是否刷入 |
| 进锁屏但触摸无反应 | 看 `SAGIT I2C:` / `SAGIT HID:` 日志；确认触摸批次与 GPIO |

## 9. 能力边界

- 触摸是实验性 RMI4 驱动：单/双指可能可用，十指、手势、长期稳定性未验证。
- 无 GPU（CPU 合成 1080×1920，缩放进 1125×2436 逻辑画面，左右 97px 黑边）。
- 无 Wi‑Fi、蓝牙、蜂窝、音频、相机、传感器、GPS、SEP/Face ID。
- 绕过部分 Apple 安全机制，**不要存放私人数据**。
