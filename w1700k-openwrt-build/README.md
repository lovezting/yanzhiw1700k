# Gemtek W1700K（OpenWrt U-Boot / UBI 布局）自定义固件编译工程

这个工程用来编译一台 **Gemtek W1700K**（CenturyLink / Lumen / Quantum Fiber 同款，Airoha AN7581 + MT7996 BE19000）的
OpenWrt 固件，并在官方固件的基础上额外打包下面这些插件：

| 需求 | 集成内容 | 来源 |
| --- | --- | --- |
| Turbo ACC | `luci-app-turboacc`（软件流量分载 + BBR，可选全锥 NAT/Shortcut-FE） | 第三方 [chenmozhijin/turboacc](https://github.com/chenmozhijin/turboacc) |
| Argon 主题 + WiFi7 管理 | `luci-theme-argon`、`luci-app-argon-config`、`luci-app-wifi7`（MT7996 / MLO 管理页） | [jerrykuku](https://github.com/jerrykuku/luci-theme-argon)、[woziwrt](https://github.com/woziwrt/luci-app-wifi7) |
| UPnP | `luci-app-upnp` + `miniupnpd-nftables` | 官方 feeds |
| SQM | `luci-app-sqm` + `sqm-scripts` + `kmod-sched-cake` | 官方 feeds |
| Airoha 管理 | `luci-app-airoha-npu`（Airoha SoC 状态：NPU / CPU / Frame Engine） | 第三方 [luanmuc/luci-app-airoha-npu](https://github.com/luanmuc/luci-app-airoha-npu)（中文增强版） |
| OpenClash | `luci-app-openclash` + `dnsmasq-full` + `kmod-tun`/`kmod-nft-tproxy` 等依赖 | 第三方 [vernesong/OpenClash](https://github.com/vernesong/OpenClash) |

另外默认还会带上：LuCI（含中文界面）、`luci-app-package-manager`、`luci-app-ttyd`、`luci-app-commands`、
`luci-app-filemanager`、`luci-app-irqbalance`，并把 Argon 设为默认主题。

---

## 0. 先说清楚的前提（重要）

1. **W1700K 的 OpenWrt 支持只存在于 `main` 分支（snapshot）**。
   官方 24.10.x / 25.12.x 的下载站里都没有 `airoha` 的目标产物，24.10 与 25.12 分支的源码树里也没有
   `gemtek_w1700k-ubi` 这个设备定义（设备是在 2026-03 合入 main 的）。
   所以本工程固定从 `openwrt/openwrt` 的 `main` 分支编译，产物就是 snapshot 固件。
2. **必须用 Linux 编译**。OpenWrt 官方不支持在 Windows/MSYS2/Cygwin 下编译。
   本工程提供两条路：
   - 推荐：用 **GitHub Actions** 免费跑（本机不需要 Linux，见第 1 节）；
   - 或者：在 **WSL2 / Ubuntu 22.04+ / Debian 12+ / 群晖 Docker** 上跑一个脚本（见第 2 节）。
3. 一次全量编译大约需要 **1.5～3 小时**（4 核）与 **25～35 GB 磁盘**。
4. 设备是 vendor 签名 bootloader + BBT/BMT 坏块表，**刷机是单程票**：
   必须先用串口 chainload U-Boot，再跑 UBI 安装器（见第 5 节）。请先备份、再动手。

---

## 1. 推荐路线：用 GitHub Actions 编译（无需本地 Linux）

1. 在 GitHub 新建一个仓库（建议 **public**，public 仓库的 runner 是 4 核，编译更快、时间额度免费）。
2. 把本目录里的**所有文件（含隐藏目录 `.github/`）**上传到仓库根目录：

   ```bash
   cd w1700k-openwrt-build
   git init -b main
   git add -A          # .github/workflows/build.yml 必须一起提交
   git commit -m "W1700K custom firmware build"
   git remote add origin git@github.com:<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

3. 打开仓库 **Actions → Build OpenWrt (Gemtek W1700K) → Run workflow**。
   所有插件开关默认全开，直接点绿色的 Run 即可；也可以按需关掉某个插件。
4. 等 1.5～3 小时，在运行页面的 **Artifacts** 里下载 `w1700k-openwrt-*`：

   - `firmware/` —— 三个刷机文件（见第 5 节）
   - `packages/` —— 本次编译出的第三方插件包（`.apk`，以后想单独装也可以用 `apk add --allow-untrusted ./xxx.apk`）
   - `BUILD-REPORT.md` —— 编译报告：哪些插件成功、哪些被自动跳过、产物 SHA256
   - `config.diff` —— 最终生效的配置（`scripts/diffconfig.sh` 输出），方便复现

> Actions 里跑了多久、有没有失败，看日志的 “Summary” 与 `BUILD-REPORT.md` 即可，
> 第三方插件编译失败不会让整个流程白跑（见第 4 节）。

---

## 2. 本机 Linux / WSL2 编译

```bash
# 1) 依赖（Ubuntu 22.04 / 24.04 / Debian 12）
sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk gettext git \
     libncurses-dev libssl-dev python3-setuptools rsync swig unzip zlib1g-dev \
     file wget ccache gcc-multilib g++-multilib

# 2) 编译（默认包含全部插件）
cd w1700k-openwrt-build
chmod +x scripts/*.sh        # 从 Windows 拷贝过来时可能丢了执行位
bash scripts/build.sh

# 3) 只要部分插件 / 追加包：
ENABLE_OPENCLASH=0 bash scripts/build.sh                      # 不要 OpenClash
ENABLE_WIFI7=0 ENABLE_AIROHA_NPU=0 bash scripts/build.sh      # 不要 WiFi7 管理页 / Airoha 面板
EXTRA_PACKAGES="luci-app-mwan3 htop" bash scripts/build.sh    # 再追加几个包

# 4) 固定到某个 commit（推荐，snapshot 每天在变）
OPENWRT_REF=1a2b3c4d5e6f bash scripts/build.sh

# 5) 编译完自检产物
bash scripts/verify-image.sh
```

把工程目录挂到 Docker 里编译同样可以（`ubuntu:24.04` 镜像装好依赖后跑 `scripts/build.sh`）。

产物在 `artifacts/firmware/`，可以直接拿去刷机。

---

## 3. 目录说明与自定义

```
w1700k-openwrt-build/
├── .github/workflows/build.yml      # GitHub Actions 一键编译
├── feeds.conf.default               # 官方 4 个 feed + 5 个第三方 feed
├── configs/
│   ├── base.seed                    # 目标平台/基础包/中文界面
│   └── features/                    # 每个插件一个片段，可自由增删
│       ├── turboacc.conf  argon.conf  upnp.conf  sqm.conf
│       ├── openclash.conf airoha-npu.conf wifi7.conf extras.conf
│   └── disabled.auto                # 自动跳过失败插件时生成（不用手改）
├── files/etc/uci-defaults/          # 首次启动执行的默认设置（Argon 主题、中文、开 UPnP）
├── scripts/
│   ├── build.sh                     # 主流程：拉源码→feeds→配置→编译→出包（带失败兜底）
│   ├── make-config.sh               # 把 base.seed + 选中的 features 拼成 .config
│   └── verify-image.sh              # 校验产物与插件是否真的进了固件
└── artifacts/                       # 编译产物（构建时生成）
```

常用改法：

* **增删插件**：改 `configs/features/*.conf`，或在 `configs/base.seed` 里加 `CONFIG_PACKAGE_xxx=y`。
* **换 WiFi 驱动包（可选）**：默认沿用设备自带的 `wpad-basic-mbedtls`（已包含 802.11be/MLO）。
  想要 WPS / WPA-Enterprise 时，把 `base.seed` 里注释掉的 `# CONFIG_PACKAGE_wpad-mbedtls=y` 一行取消注释即可
  （Kconfig 会自动把冲突的 `wpad-basic-mbedtls` 关掉）。
* **换 Airoha 面板**：`feeds.conf.default` 里把 `luci-app-airoha-npu` 的地址换成上游
  `https://github.com/rchen14b/luci-app-airoha-npu.git` 也可以（构建脚本会自动修正它里面
  `include ../../luci.mk` 的相对路径）。
* **Turbo ACC 的全锥 NAT / Shortcut-FE**：默认关闭，原因见第 6 节。

---

## 4. 编译失败兜底（本工程的核心设计）

第三方插件（尤其 OpenClash）在 `main` 快照上偶尔会跟上游不同步而编译失败。`scripts/build.sh` 会：

1. 正常 `make -j$(nproc)`；
2. 失败后从 OpenWrt 的 `logs/` 目录里找出**实际失败的包**；
3. 如果失败的是本工程的第三方插件（turboacc / openclash / argon / airoha-npu / wifi7），
   自动把它写进 `configs/disabled.auto` 并重新 `make defconfig` 再编一次（最多 4 轮）；
4. 失败的是**核心包**（内核、libc、LuCI base 等）时**直接停下并报错**，不会悄悄出一个坏固件；
5. 最后把“成功进固件的插件 / 被跳过的插件”写进 `artifacts/BUILD-REPORT.md`。

也就是说：哪怕 OpenClash 当天编译不过，你也一定能拿到一个能开机、其余功能齐全的固件，
而且日志里会明确告诉你是哪个包挂了。

---

## 5. 刷机（U-Boot 布局，来自 OpenWrt 上游设备支持提交）

产物三个文件（`artifacts/firmware/`）：

| 文件 | 作用 |
| --- | --- |
| `openwrt-airoha-an7581-gemtek_w1700k-ubi-chainload-uboot.itb` | 链式加载的 U-Boot，刷到原厂 bootloader 的 kernel 分区 |
| `openwrt-airoha-an7581-gemtek_w1700k-ubi-initramfs-recovery.itb` | 恢复用 initramfs（U-Boot 菜单/TFTP 引导） |
| `openwrt-airoha-an7581-gemtek_w1700k-ubi-squashfs-sysupgrade.itb` | 正式固件（U-Boot 里升级/U 盘恢复都用它） |

步骤概要（**完整细节以上游说明为准**，见文末引用）：

1. 拆机接串口：Torx T10 螺丝在标签二维码下面；从背部网口一侧撬开卡扣。
   UART 排针顺序 `TX - GND - VCC - N/A - RX`，开机按任意键打断原厂 bootloader。
2. 原厂 U-Boot 里设置从 kernel 分区启动并 TFTP 刷入 chainloader：

   ```
   setenv one flash read 0x600000 0x1000000 $loadaddr
   setenv two "; bootm"
   setenv bootcmd "$one$two"
   setenv one
   setenv two
   saveenv
   setenv serverip 192.168.1.10; setenv ipaddr 192.168.1.1
   tftpboot 0x89000000 openwrt-airoha-an7581-gemtek_w1700k-ubi-chainload-uboot.itb
   flash erase 0x600000 0x100000
   flash write 0x600000 0x100000 0x89000000
   reset
   ```

   （原厂网口驱动不太稳，`tftpboot` 可能要试几次。）
3. 重启后进入新的 U-Boot 链式加载器，按菜单里的 **TFTP** 方式引导
   [w1700k-ubi-installer](https://github.com/hurrian/w1700k-ubi-installer/releases)，
   安装器会自动重建 UBI 分区表（会自动问几个问题）。
4. 安装器跑完后，用 LuCI “系统 → 备份/刷写固件” 刷入本工程的 `*-squashfs-sysupgrade.itb`，
   或者在新 U-Boot 里直接引导该 itb。

> 刷错砖后需要串口恢复；原厂固件对普通用户基本没用，回退路线上游没有提供文档。
> 动手前务必先按上游说明把原厂固件备份下来。

---

## 6. 已知限制

* **全锥形 NAT（NFT FULLCONE）默认关掉**：Turbo ACC 的这个开关依赖内核模块 `kmod-nft-fullcone`，
  而 OpenWrt main 的官方软件源里没有这个包（已核对：`kmods` 索引里不存在）。要开的话得再引入第三方
  nft-fullcone 内核模块源，且要能在 6.18 内核上编译，风险自担（在 `configs/features/turboacc.conf` 里取消注释即可尝试）。
* **Shortcut-FE 系列默认关掉**：它的默认值对非高通平台会拉入 `kmod-shortcut-fe-cm`，该模块在 Airoha 平台上不存在，
  不关会导致编译失败。
* `luci-app-openclash` 依赖 `dnsmasq-full`，本工程会把默认的 `dnsmasq` 换成 `dnsmasq-full`
  （OpenClash 需要 nftset 支持），这属于预期行为。
* 产物是 **snapshot 固件**：内核 6.18.x + apk 包管理器（不是 opkg）。装第三方 ipk 时代码不兼容，
  请用 `apk add` 或本工程编出的 `.apk`。
* `luci-app-wifi7` / `luci-app-wifimgr` 是社区为 MT7996 写的 WiFi 7/MLO 管理页（作者示例机型是 BPI-R4），
  W1700K 同为 MT7996，一般可用；不想要就在 workflow 里关掉。标准 LuCI 无线页面始终可用。

---

## 7. 参考与致谢

* 设备支持与刷机步骤：OpenWrt 提交 [`99307582dea2` airoha: add support for Gemtek W1700K](https://github.com/openwrt/openwrt/commit/99307582dea2)
* UBI 安装器：[hurrian/w1700k-ubi-installer](https://github.com/hurrian/w1700k-ubi-installer)
* 插件作者：chenmozhijin（turboacc）、vernesong（OpenClash）、jerrykuku（Argon）、luanmuc / rchen14b（airoha-npu）、woziwrt（wifi7）
* OpenWrt 本体与 feeds 归属各自作者；本工程只做集成与自动化。
