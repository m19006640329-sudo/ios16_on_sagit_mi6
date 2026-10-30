# 从小米 6 到 iOS 桌面：完整步骤（2026-10-30 版）

> 这份教程按**当前仓库的真实状态**写：源码/打包链路已完成，XNU 内核还需要
> 在 GitHub 的 macOS runner 上编译，之后才能打包完整 boot 镜像。文中每个
> “验证点”都告诉你应该看到什么；看不到就不要往下走。
>
> **会丢数据的步骤只有两个**：`fastboot flash userdata`、`fastboot flash boot`。
> 其余 `fastboot boot` 都是临时启动，不写分区。

## 总览

```
Windows                          GitHub (macOS runner)              Kali VM                   小米 6
────────                         ─────────────────────              ───────                   ──────
创建 PAT
运行 upload-to-github.ps1  ──►   上传仓库 + 跑 xnu workflow
                                 编译 XNU（15–30 分钟）
下载 kernel.development.sweet ◄──  artifact xnu-kernel
                                  │
                                  └────────────► build-sagit-boot.sh
                                                 out/shim-sagit-xnu.img
                                                                        ──► fastboot boot 探针
                                                                        ──► fastboot boot 完整镜像
```

---

## 0. 准备清单

| 东西 | 说明 |
| --- | --- |
| 小米 6（sagit） | bootloader 已解锁（`fastboot getvar unlocked` = yes） |
| USB 数据线 | 能稳定传 1GB 以上；优先 USB 2.0 口 |
| Windows | 装 Android platform-tools（fastboot/adb） |
| Kali VM | 工作区里那台，账户/密码 `kali`；已装 aarch64 gcc、dtc、hfsprogs、img2simg |
| GitHub 账号 | 能创建仓库、能跑 Actions |
| iPhone X IPSW | iOS 16.7.16 (20H392)，约 6GB，第 7 步才用 |
| 空闲磁盘 | 根卷构建需要 ≥40GB（Kali 的 `/` 目前 59GB 可用） |

**先备份**（在 Android/TWRP 里，把分区拉到电脑，不要上传）：

```sh
adb root
mkdir -p backup
for p in boot persist modemst1 modemst2 fsg fsc; do
  adb pull /dev/block/bootdevice/by-name/$p backup/$p.img
done
```

原厂 `boot.img` 必须能在需要时刷回；`persist`/`modemst*` 丢了很难恢复。

---

## 1. 创建 GitHub PAT（5 分钟）

必须在**能打开 github.com 的浏览器**里做（手机热点/VPN 都行；这台 Windows
的 `github.com` HTTPS 被卡，但 `api.github.com` 是通的）。

1. 打开 <https://github.com>，登录。
2. 右上角头像 → **Settings**。
3. 左侧最下 **Developer settings**。
4. **Personal access tokens** → **Tokens (classic)**。
5. 右上 **Generate new token** → **Generate new token (classic)**。
6. 填写：
   - Note：`sagit-build`
   - Expiration：`7 days`
   - Scopes：勾选 **`repo`**（整组）和 **`workflow`**
7. 点 **Generate token**，复制 `ghp_...`（只显示一次）。

> 只用一次就够；构建完成后回同一页面 **Revoke**。
> 如果你只有 fine-grained token：需要 *Contents: Read and write*、
> *Workflows: Read and write*、*Actions: Read and write*、*Metadata: Read*，
> 并且仓库范围选 **All repositories**（因为脚本要新建仓库）。

---

## 2. 上传仓库并触发构建（Windows）

打开 **Windows PowerShell**（开始菜单搜 PowerShell），执行：

```powershell
powershell -ExecutionPolicy Bypass -File G:\ios16sagit\ios16_on_sagit_mi6\tools\upload-to-github.ps1
```

依次输入：

```
GitHub username: 你的用户名
Paste the PAT (input hidden): 粘贴 ghp_...（回车后不显示）
```

脚本会：

1. 创建仓库 `ios16_on_sagit_mi6`（默认 public）；
2. 通过 `api.github.com` 上传 291 个文件（不需要 git，也不需要本机能开 github.com）；
3. 在 `main` 上建一个提交；
4. 触发 `.github/workflows/xnu.yml`（`machine_config=SWEET`、`kernel_config=DEVELOPMENT`）；
5. 等构建结束，把 `kernel.development.sweet` 下载到
   `G:\ios16sagit\ios16_on_sagit_mi6\xnu\out\`。

预期输出（节选）：

```
[*] authenticated as <you>
[*] created <you>/ios16_on_sagit_mi6 (public)
[*] uploading 291 files (11.7 MB)
    20/291
    ...
[*] pushed commit xxxxxxxx to main
[*] dispatching xnu workflow (machine=SWEET, config=DEVELOPMENT)
[*] run: https://github.com/<you>/ios16_on_sagit_mi6/actions/runs/...
    queued  ...
    in_progress  ...
    completed  success
[*] downloading xnu-kernel artifact
[*] kernel saved: G:\...\xnu\out\kernel.development.sweet
```

**验证点**：最后出现 `kernel saved:` 和一段 SHA256；文件大小约 12–17MB。

### 常见错误

| 输出 | 原因 / 处理 |
| --- | --- |
| `[x] token rejected` | PAT 复制不全或已过期；重新生成 |
| `tree creation failed ... workflow` | PAT 没勾 `workflow`；重新生成并勾上 |
| `commit failed (classic PAT must have BOTH 'repo' and 'workflow')` | 同上 |
| `dispatch attempt ... failed` 连续 8 次 | 仓库 Actions 被禁用：打开仓库 → Settings → Actions → General → 选 **Allow all actions and reusable workflows** → Save，再重跑脚本（脚本可重复运行，会复用仓库） |
| `timed out` 或 run 一直 queued | 大概率 `macos-14` 已下线（见下）；把 run 链接发我 |
| `build failure` | 把 run 链接和红色日志发我，优先看 patch 是否应用失败 |

> **时间窗口**：GitHub 的 `macos-14` 镜像官方计划 2026-11-02 停止支持。
> 它自带 Xcode 15.x；`macos-15` 只有 Xcode 16+，而 Xcode 16 的 `iig` 与
> xnu-8796 的 IORPC ABI 不兼容。**请在 11-01 前跑这次构建**。

### 如果 PowerShell 脚本跑不起来

最少的手动替代：让脚本只建仓库（`-NoRun`），然后在浏览器里把
`G:\ios16sagit\ios16_on_sagit_mi6` 的内容按文件夹分批拖到 GitHub 网页上传，
提交后进 **Actions → xnu → Run workflow**，参数：
`macos_version=13.5`、`kernel_config=DEVELOPMENT`、`machine_config=SWEET`、
`keep_going=true`。

---

## 3. 等构建、拿内核

脚本会自动等；你也可以打开：

```
https://github.com/<you>/ios16_on_sagit_mi6/actions
```

点最新一次 **xnu** run：

- 绿色 ✓ → 页面底部 **Artifacts** → `xnu-kernel` 下载；
- 解压后把 `kernel.development.sweet` 放到 `xnu\out\`。

**验证点**：

```powershell
Get-Item G:\ios16sagit\ios16_on_sagit_mi6\xnu\out\kernel.development.sweet |
  Select-Object Name,Length
Get-FileHash G:\ios16sagit\ios16_on_sagit_mi6\xnu\out\kernel.development.sweet -Algorithm SHA256
```

文件应是 Mach-O（不是 boot.img，不能直接刷）。

---

## 4. 在 Kali 里打包完整 boot 镜像

Kali 里仓库路径：`/mnt/hgfs/ios16/ios16_on_sagit_mi6`（VMware 共享目录）。

```sh
cd /mnt/hgfs/ios16/ios16_on_sagit_mi6
tools/build-sagit-boot.sh xnu/out/kernel.development.sweet 6
```

脚本做的事：

1. `mkadt.py --sagit --ram 6` → `out/sagit.adt`
2. `mkpayload.py ... --check-sagit-cpus --max-payload-size 0xE00000`
   → `out/sagit-payload.bin`（内核 + ADT + 启动参数）
3. `PLATFORM=sagit shim/build.sh out/sagit-payload.bin`
   → `out/shim-sagit-xnu.img`
4. 解包到 `out/check-sagit`，`cmp` ramdisk 与 payload，打印 SHA256

**验证点**：

```
out/shim-sagit-xnu.img: ... bytes  kernel=... ramdisk=...
sha256 ...
```

- payload 必须 < `0xE00000`（14,680,064 字节），否则脚本会拒绝；
- `cmp` 必须无输出（ramdisk 与 payload 逐字节一致）；
- 解包头应是 `header_version: 1`、`page_size: 4096`、`kernel_addr: 0x8000`、
  `ramdisk_addr: 0x1000000`。

> 想改启动参数（例如先关触摸）时，用环境变量覆盖：
> `CMDLINE='...' tools/build-sagit-boot.sh ...`，或直接编辑脚本里的 `CMDLINE`。
> 常用调试组合：
> - 只读触摸状态：`sagittouchdiag=1 sagittouch=0 sagittouchhid=0`
> - 触摸原始帧：`sagittouchdiag=1 sagittouch=1 sagittouchhid=0`
> - 单指 HID：`sagittouch=1 sagittouchhid=1`

---

## 5. 手机上先跑探针镜像（不写分区）

1. 手机关机，按住 **电源 + 音量下** 进 fastboot，插 USB。
2. Windows 上（platform-tools 目录）：

```powershell
fastboot devices
fastboot getvar product
fastboot boot G:\ios16sagit\ios16_on_sagit_mi6\artifacts\sagit\shim-sagit-boot.img
```

**验证点**：屏幕出现红底诊断页：

```
SHIM    sagit milestone 4: xnu loader
BOARD   Qualcomm Technologies, Inc. MSM 8998 v2 ...
RAM     hi=00000001 lo=00000000
RAM     MiB=... idx=0
...
UFS PART userdata lba=... MiB=...
UFS     probe done, reset in ~3 min
```

约 3 分钟后自动重启。

| 现象 | 处理 |
| --- | --- |
| 黑屏，但 3 分钟后自动重启 | shim 在跑，只是 framebuffer 地址不对：把 `shim/console.h` 的 `FB_BASE` 改成 `0x9d400000`，回 Kali 重新 `PLATFORM=sagit shim/build.sh`，再 `fastboot boot` |
| 屏幕有字但错位/斜条 | 记录照片，stride/panel 需要按你的固件核对 |
| `fastboot boot` 报 unknown command / 拒绝 | bootloader 没解锁，或该 MIUI 版本禁用了 `fastboot boot`；停止，不要改刷 `flash boot` |
| `BOARD` 不是 MSM8998 | DTB 不匹配：用你手机原厂 `boot.img` 重新生成 `tools/sagit_dtb.py --from-boot` |

---

## 6. 先验证 UFS/HFS（可选，但推荐）

在刷 16GB iOS 根卷之前，用一个 8MB 空 HFS+ 卷验证内核能挂载根分区。
**这一步会清空 userdata**，确认已备份再继续：

```sh
# Kali
dd if=/dev/zero of=test-hfs.img bs=1M count=8
mkfs.hfsplus -v SagitRoot test-hfs.img
```

```powershell
# Windows fastboot
fastboot flash userdata G:\path\to\test-hfs.img
fastboot boot G:\ios16sagit\ios16_on_sagit_mi6\out\shim-sagit-xnu.img
```

预期：内核打印 `hfs: mounted ...`，然后因为找不到 `/sbin/launchd` 而 panic。
看到 mount 就说明 UFS + HFS 路径通了；panic 是预期的。

> 没有 iOS 根卷时，完整镜像停在挂载/launchd 阶段是正常的，不代表 boot.img 错。

---

## 7. 构建 iOS 16 根卷（Linux，≥40GB 空闲）

> Kali 仓库**没有** `apfs-fuse` 包。建议用 Ubuntu 22.04/24.04（物理机/云主机/
> 另一台 VM），或从源码编译 apfs-fuse。iOS 的 DMG 是 APFS，没有它无法解包。

1. 从 ipsw.me 下载 **iPhone10,3 / iOS 16.7.16 (20H392)** 的 IPSW（约 6GB）。
2. 按 `BuildManifest.plist` 找出 OS / SystemOS / AppOS 三个 DMG（名字可能带
   后缀，别照抄示例）：

```sh
unzip -l iPhone10,3_16.7.16_20H392_Restore.ipsw | grep -Ei '\.dmg$'
mkdir -p ipsw
unzip -o iPhone10,3_16.7.16_20H392_Restore.ipsw 'OS.dmg' 'SystemOS.dmg' 'AppOS.dmg' -d ipsw
```

3. 安装依赖并生成 16GB 根卷：

```sh
sudo apt update
sudo apt install -y apfs-fuse hfsprogs rsync python3 android-sdk-libsparse-utils
tools/mkiosroot.sh ipsw/OS.dmg ipsw/SystemOS.dmg ipsw/AppOS.dmg ios16-root.img 16G
sudo fsck.hfsplus -fy ios16-root.img
sudo mkdir -p /mnt/iosroot
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg
sha256sum ios16-root.simg
```

**验证点**：每步都成功；`fsck` 无错误；`ios16-root.simg` 逻辑大小 16GB。

---

## 8. 刷 userdata、启动完整系统

**再次确认**：备份可恢复、只有一台 `sagit`、接受清空 Android 数据。

```powershell
fastboot devices
fastboot getvar product
fastboot -S 512M flash userdata G:\path\to\ios16-root.simg
```

- 16GB 稀疏镜像通常 7–15 分钟；每个分块都要 OKAY，不要拔线。
- 刷完先 **临时启动**（不写 boot）：

```powershell
fastboot boot G:\ios16sagit\ios16_on_sagit_mi6\out\shim-sagit-xnu.img
```

**预期**：Apple logo 阶段可能 5–10 分钟；然后进入 iOS 锁屏/桌面。
显示是 1080×1920 面板，中间 886×1920 是 iOS 画面，左右各 97px 黑边。

想永久刷 boot（风险更高，自选，确保能恢复）：

```powershell
fastboot flash boot G:\ios16sagit\ios16_on_sagit_mi6\out\shim-sagit-xnu.img
```

**只写 boot 和 userdata**；不要写 recovery/dtbo/vbmeta/persist，不要锁 bootloader。

---

## 9. 触摸调试（如果锁屏没反应）

日志没有串口，内核 console 写在 userdata 尾部 4MiB ring。取日志：

1. `fastboot boot` 一个 sagit 的 TWRP/OrangeFox recovery；
2. `adb devices`、`adb root`；
3. 在仓库里跑 `tools/sweet-log-pull.sh logs/boot.txt`（Windows Git Bash 或 Linux）。

在日志里找：

```
SAGIT I2C: RESET89 ...
SAGIT I2C: F01 PDT ...
SAGIT I2C: F12 PDT ...
SAGIT HID: ...
```

调试顺序（每次改 `CMDLINE` 后重跑第 4 步打包，再 `fastboot boot`）：

1. `sagittouchdiag=1`：只读 GPIO87/88/89/125/50 的 CFG/IO。确认 reset 是否已释放、
   bus 是否被拉低。
2. `sagittouch=1 sagittouchhid=0`：读 F01/F12 PDT 和原始帧，确认 I²C ACK、
   `F12 PDT` 首字节 0x49、data base ≥ 4。
3. `sagittouchhid=1`：单指 HID。小米 6 有 S3330/S3331/TD4322 三种触摸批次，
   F12 固件布局可能不同；驱动会打印 `first invalid frame` 的原始 8 字节。

---

## 10. 回滚 Android

- 只做过探针/临时启动：直接重启。
- 刷过 userdata：用小米官方 fastboot 包 + MiFlash（**clean all**，不要 lock）。
- 刷过 boot：`fastboot flash boot backup/boot.img`（你备份的原厂镜像）。

---

## 11. FAQ

**Q：`fastboot boot` 后黑屏但会重启，是变砖了吗？**
不是。探针镜像不写分区，最多是显示地址不对；长按电源 12 秒重启即可。

**Q：脚本里 `macos-14` 报 “image not found”/一直 queued？**
镜像已下线。把 run 链接发我；备选是本地 macOS 14.8 + Xcode 15.4 的
self-hosted runner，或等我们改用其他构建机。

**Q：能不能不刷 userdata 先进桌面？**
不能。iOS 根文件系统在 userdata 里；没有它内核在挂载根分区时就 panic。

**Q：`cpus=8` 什么时候试？**
先 `cpus=4` 稳定进桌面，再改 8 试 A73。失败就回 4，不要把坏核交给调度器。

**Q：为什么没有 GPU/Wi‑Fi/声音？**
没有驱动。显示是 CPU 逐帧拷贝 + 缩放，所以只能算“能看能用”，不是日常系统。

---

## 12. 风险边界（务必读）

- 这是实验性移植：**没有在你这台小米 6 上验证过**，永久刷 boot 可能让 Android
  无法启动；保留原厂 boot 和 fastboot 包。
- 绕过部分 Apple 安全机制（AMFI/沙箱/AppleKeyStore 桩），**不要登录 Apple ID、
  不要放照片/聊天记录等个人数据**。
- 仓库不提供 Apple IPSW/用户态、Qualcomm 固件、原厂 DTB；这些要你自己合法取得。
- 不要在公开仓库上传含序列号的分区备份、`persist`/`modemst`、设备日志。
