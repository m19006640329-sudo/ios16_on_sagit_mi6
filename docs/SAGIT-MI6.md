# 小米 6（sagit / MSM8998）移植工程记录

本文记录把 MIX 2S（polaris / SDM845）分支改到小米 6 时**实际改动**的每一条
硬件参数、来源和验证状态。所有“已验证”均指在本仓库/本机离线可复现的检查，
不等于真机运行；真机结果单独标注。

## 1. 目标与边界

- 目标：XNU 8796 + iPhone X（D22AP，iOS 16.7.16）用户态在小米 6 上启动到
  桌面，并能用触摸操作。
- 手段：复用上游 `SWEET` machine config、UFS/HFS+ 根卷、CPU framebuffer 和
  SweetHID 基础设施；板级差异放在 ADT、shim、启动参数和一个 XNU 补丁里。
- 不做：GPU（Adreno 540 没有驱动）、基带/Wi‑Fi/音频/相机/传感器/SEP、
  安全启动。原 A630 GPU 研究代码不进入 sagit 分支。

## 2. 硬件事实与来源

| 项 | 值 | 来源 |
| --- | --- | --- |
| SoC | MSM8998（4×A53 + 4×A73） | MiCode `sagit-o-oss`、mainline `msm8998.dtsi` |
| CPU MPIDR | CPU0–3 `0x000–0x300`，CPU4–7 `0x100–0x300` | `msm8998.dtsi` cpu@0/cpu@100 |
| GIC | GICD 0x17a00000，GICR 0x17b00000（stride 0x20000） | `msm8998.dtsi` |
| 定时器 | 19.2MHz，虚拟定时器 PPI 19 | `msm8998.dtsi` timer |
| splash | 0x9d600000，0x2400000，1080×1920，stride 4320 | `sagit`/`sdm660` DTS 与 `msm8998.dtsi`；原厂内核 `cont_splash_mem` |
| UFS | ufshc@1da4000，LUN0 `userdata` | `msm8998.dtsi` |
| 触摸 | Synaptics DSX（S3330/S3331/TD4322）@0x20，IRQ125，reset89 | `sagit-msm8998-mtp.dtsi` |
| 触摸总线 | BLSP1 QUP5 i2c@c179000，SDA GPIO87 / SCL GPIO88 | `msm8998-blsp.dtsi`、`msm8998-pinctrl` |
| TLMM tile | EAST +0x900000（GPIO87/88/89/125），NORTH +0x500000（GPIO50） | `drivers/pinctrl/qcom/pinctrl-msm8998.c` |
| 触摸供电 | `disp_vddts` GPIO50（boot-on）、VDD L6A 1.8V | sagit DTS `disp_vddts_vreg`、`pm8998_l6` |
| boot 头 | v1/4096，kernel 0x8000，ramdisk 0x1000000，tags 0x100，dtb 0x1e00000 | msm8998 平台惯例（OnePlus 5 / TWRP sagit 同源） |

**framebuffer 地址的取舍**：MiCode 的 `msm8998.dtsi`（O 与 P 分支）都把
`cont_splash_mem` 放在 `0x9d600000`，mainline 的 sagit DTS 写的是
`0x9d400000`。小米原厂内核与 LK 同源，仓库采用 **0x9d600000**；探针镜像
黑屏但能重启时，把 `shim/console.h` 的 `FB_BASE` 改成 0x9d400000 即可做
A/B 验证。

## 3. 改动的文件

| 文件 | 改动 |
| --- | --- |
| `tools/mkadt.py` | 新增 `--sagit`：MSM8998 CPU 节点（kryo280，1.9/2.45GHz）、1080×1920、splash 0x9d600000、UFS 0x1da4000、GICR 0x17b00000、`xiaomi,sagit`+`qcom,msm8998`、`--ram 4/6` |
| `shim/console.h` | 新增 `SAGIT` 平台：`sagit`、FB 0x9d600000、1920 行 |
| `shim/shim.c` | GICR 0x17b00000（SAGIT）、FB 相关常量改用 `FB_BASE`、平台名 sagit |
| `shim/ufs.c` | `SAGIT` 的 UFS_BASE=0x1da4000 |
| `shim/build.sh` | `PLATFORM=sagit`：`-DSAGIT`、gzip 内核 + DTB 尾、cmdline（a800000.dwc3 / 1da4000.ufshc）、header v1/4096、dtb 0x1e00000、payload 上限 0xE00000、产物 `shim-sagit-*.img` |
| `tools/sagit_dtb.py` | 拼接/校验 sagit DTB 尾（board-id 30/0，msm-id 292 v2/v2.1，splash 报告），支持 `--from-boot` |
| `dtb/sagit/*.dtb` | 由 MiCode `sagit-msm8998-mtp.dts`、v2、v2.1 编译（dtc），共 3 个 |
| `xnu/patches/0082-sagit-mi6-xnu-port.patch` | 合并原 0082–0090，见下节 |
| `tools/sagit_cpu_topology.py`、`test_sagit_cpu_topology.py` | CPU 前缀校验改为 sagit/MSM8998 |
| `tools/mkpayload.py` | `--check-sagit-cpus` |
| `README.md`、`docs/*`、`NOTES.md` | sagit 化 |
| 删除 | 原 0082–0093 polaris 补丁、A630 GPU 工具/研究、polaris 文档 |

## 4. XNU 补丁 `0082-sagit-mi6-xnu-port.patch`

在原 0001–0081（sweet 基础）之上，一个补丁完成：

1. **板型门控**：`bsd/dev/sagit_touch_diag.c` 用 ADT `xiaomi,sagit` +
   `qcom,msm8998` 双身份；sweet 的 SE7/PMIC 驱动只在 `qcom,sm7150` 下运行。
2. **诊断**：`sagittouchdiag=1` 时只读打印 TLMM GPIO87/88/89/125/50 的
   CFG/IO，不做任何写操作。MSM8998 的触摸总线是 BLSP，不是 QUPv3 SE14，
   因此没有 GCC/SE14 时钟探针。
3. **触摸**：`bsd/dev/sagit_touch_i2c.c` 在 GPIO87/88 上 bit-bang RMI4：
   - 读 F01 PDT(0x00e3)、F12 PDT(0x00dd)、F01 status/control、F12 query；
   - Query8 只校验长度 1..8（Mi 6 三种触摸批次固件不同），打印原始 16 字节；
   - `sagittouchhid=1` 时按 F12 data base 连续读 `num_fingers*8` 字节，
     解析 type/x/y，两点确认后才发 DOWN，20ms 轮询，异常释放；
   - `sagittouchreset=1` 时，仅当 GPIO89 仍是“输出低”才释放为高并等 200ms；
     若 ABL 已释放（Mi 6 常见），记录后继续，不中止。
4. **显示**：`SweetFramebuffer.cpp` / `SweetHID.cpp` 的 polaris 缩放分支改名
   `sweetfb_sagit`；面板 1080×1920，内容 886×1920 居中（左右 97px），触摸
   坐标按同一变换反算。
5. **RELEASE 放行**：`kern_exec.c` 的 `unentitled_ios_sim_launch` 例外
   要求 `sagit_touch_board()`（ADT 双身份），默认仍拒绝。
6. **early framebuffer**：沿用 0083 的逻辑（boot_args 的 `Video` 决定基址/
   几何），注释改为 sagit。

补丁不包含任何 GPU、PAS、SMMU 或 PMIC 写入。

## 5. 启动参数

```
debug=0xc serial=3 cpus=4 keepsyms=1 -enable_kprintf_spam -noprogress
rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1
wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1
sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_sagit=1
sweettouch=0 sweetkeys=0
sagittouchdiag=1 sagittouch=1 sagittouchhid=1 sagittouchreset=1
```

- `cpus=4`：先 A53 簇；进系统后试 `cpus=8`。
- `sweetfb_sagit=1`：把 1125×2436 逻辑画面按高度缩放进 1920，左右黑边。
- `sweettouch=0 sweetkeys=0`：禁用 sweet 的 SM7150 驱动（必须）。
- 触摸三项可按需关闭：只留 `sagittouchdiag=1` 看只读状态，或
  `sagittouch=1` 不启用 HID（只打印原始帧）。

## 6. 已验证 / 未验证

**已验证（离线）**

- 0001–0082 补丁对 `xnu-8796.141.3` 顺序 `git apply` 全部成功，C 源码无
  polaris/SDM845 残留。
- `mkadt.py --sagit` 生成 10,048 B ADT（fbcon/ufs/cpus/gic 值经 dump 核对）。
- 3 个 MiCode DTB 编译成功，`sagit_dtb.py` 校验 board-id 30/0、msm-id
  0x124/0x20000 与 0x20001、splash 0x9d600000。
- `shim/build.sh PLATFORM=sagit` 用 `aarch64-linux-gnu-gcc` 编译并打包出
  1,253,376 B 的 `out/shim-sagit-boot.img`（header v1/4096，解包字段核对）。
- Python 工具语法与 CPU 拓扑单测（见 README §8）。

**未验证**

- XNU 未编译（本环境无 macOS SDK/clang），`0082` 补丁只做了 apply 检查，
  没有编译/链接证据。
- 没有连接小米 6：探针镜像、完整 boot 镜像、触摸、进入桌面均未真机执行。
- 触摸 F12 布局、GPIO 复位/供电时序、三种触摸批次兼容性均未实测。

## 7. 下一步（真机顺序）

1. `fastboot boot out/shim-sagit-boot.img`：记录 BOARD/RAM/UFS/是否自动重启；
   黑屏则切 0x9d400000 再测。
2. CI 编译 DEVELOPMENT 内核 → 打包 payload/boot.img（≤0xE00000）→ 临时启动，
   确认能过 launchd；没有根卷时在挂载处 panic 属预期。
3. 刷 16GB iOS 根卷到 userdata，启动到锁屏；串口不可用，日志走 userdata 尾部 ring。
4. 触摸：先 `sagittouchdiag=1` 看 GPIO 状态，再开 `sagittouch=1` 看 PDT/raw，
   最后 `sagittouchhid=1` 试单指；记录 `SAGIT I2C:`/`SAGIT HID:` 行。
5. 稳定后再试 `cpus=8`。

不要在没有备份和用户确认的情况下永久写 boot/userdata。
