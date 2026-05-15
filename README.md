# EasePi-R2 Image Build

给 **EasePi-R2 / RK3588** 统一整理多系统镜像构建入口。

当前已经接入：

- Armbian 原生镜像：复用 Armbian build 生成 U-Boot / Kernel / DTB / rootfs / 分区镜像
- Debian BSP 打包镜像：复用 Armbian build 生成 BSP，本项目生成 rootfs 并打包成可刷写镜像

后续会按矩阵逐步接入 Ubuntu BSP、FNOS、Alpine Linux、Fedora、Arch Linux ARM、Kali ARM、OpenWrt。

## 基础环境要求

推荐使用 **原生 Linux 主机** 或 **Linux 虚拟机** 编译。

推荐系统：

```text
Debian 13
Debian 12
Ubuntu 24.04 LTS
```

推荐配置：

```text
CPU：4 核以上，推荐 8 核以上
内存：8GB 起步，推荐 16GB 以上
磁盘：100GB 起步，推荐 150GB 以上
网络：能正常访问 GitHub、Debian/Ubuntu 软件源、Armbian 源
```

不推荐使用 WSL。内核编译、loop 设备、chroot、binfmt、挂载镜像和权限处理都更适合在完整 Linux 环境下完成。

## 一、安装依赖

```bash
sudo apt update
sudo apt install -y git curl wget rsync unzip xz-utils ca-certificates
sudo apt install -y build-essential gcc g++ make bc bison flex
sudo apt install -y libssl-dev libncurses-dev python3 python3-pip python3-setuptools
sudo apt install -y file cpio qemu-user-static binfmt-support debootstrap
sudo apt install -y parted dosfstools e2fsprogs util-linux u-boot-tools
```

## 二、基础装备

推荐目录结构：

```text
~/rk3588_build/
├── build/                         # Armbian 官方 build 源码
└── EasePi-R2-Image-Build/          # 本仓库
    ├── build-image.sh              # 统一构建入口
    ├── build.sh                    # Armbian 原生镜像入口
    ├── build-bsp-image.sh          # Debian BSP 打包镜像入口
    ├── configs/                    # 项目矩阵与目标配置
    ├── rootfs/                     # 各系统 rootfs 配置
    ├── scripts/                    # BSP 构建阶段脚本
    └── userpatches/                # Armbian 板级、内核、U-Boot、overlay 适配
```

准备源码：

```bash
mkdir -p ~/rk3588_build
cd ~/rk3588_build

git clone --depth=1 https://github.com/armbian/build.git build
git clone https://github.com/fk1124/EasePi-R2-Image-Build.git

cd EasePi-R2-Image-Build
chmod +x build-image.sh build.sh build-bsp-image.sh scripts/*.sh
```

## 三、开始编译

进入项目目录：

```bash
cd ~/rk3588_build/EasePi-R2-Image-Build
```

建议优先使用统一入口：

```bash
bash build-image.sh <系统> <发行版> <内核> <镜像类型>
```

可用内核别名：

```text
6.1     -> vendor
6.18    -> current
7.0     -> stable Linux 7.0 profile
```

可用镜像类型：

```text
minimal
server
desktop
```

空白命令表示矩阵位置已经预留，但脚本还没有接入。

### 1. 主推镜像

| 镜像 | 状态 | 编译命令 |
| --- | --- | --- |
| Armbian bookworm 6.1 minimal | 已接入 | `bash build-image.sh armbian bookworm 6.1 minimal` |
| Armbian trixie 6.18 minimal | 已接入 | `bash build-image.sh armbian trixie 6.18 minimal` |
| Debian trixie 6.18 minimal | 已接入 | `bash build-image.sh debian trixie 6.18 minimal` |
| Ubuntu noble 6.18 minimal | 规划中 |  |

### 2. 完整项目矩阵

| 系统 | 发行版 | 备注 | 首推内核 | 次推内核 | 编译脚本跳转 |
| --- | --- | --- | --- | --- | --- |
| armbian | bookworm | Debian 12 | 6.1 | 6.18 | [6.1](#cmd-armbian-bookworm-61) / [6.18](#cmd-armbian-bookworm-618) |
| armbian | trixie | Debian 13 | 6.18 | 7.0 | [6.18](#cmd-armbian-trixie-618) / [7.0](#cmd-armbian-trixie-70) |
| armbian | forky | Debian 14 / 前瞻 | 7.0 | - |  |
| armbian | jammy | Ubuntu 22.04 LTS | 6.1 | 6.18 |  |
| armbian | noble | Ubuntu 24.04 LTS | 6.18 | 7.0 |  |
| armbian | resolute | Ubuntu 26.04 LTS / 前瞻 | 7.0 | - |  |
| debian | bookworm | Debian 12 BSP 打包镜像 | 6.1 | 6.18 | [6.1](#cmd-debian-bookworm-61) / [6.18](#cmd-debian-bookworm-618) |
| debian | trixie | Debian 13 BSP 打包镜像 | 6.18 | 7.0 | [6.18](#cmd-debian-trixie-618) / [7.0](#cmd-debian-trixie-70) |
| debian | forky | Debian 14 BSP 打包镜像 / 前瞻 | 7.0 | - |  |
| ubuntu | jammy | Ubuntu 22.04 LTS BSP 打包镜像 | 6.1 | 6.18 |  |
| ubuntu | noble | Ubuntu 24.04 LTS BSP 打包镜像 | 6.18 | 7.0 |  |
| ubuntu | resolute | Ubuntu 26.04 LTS BSP 打包镜像 / 前瞻 | 7.0 | - |  |
| FNOS | stable | 飞牛OS | FN专用内核 | - |  |
| Alpine Linux | stable | apk / 轻量 rootfs | 6.18 | - |  |
| Fedora | latest | Fedora 44 | 6.18 | - |  |
| Arch Linux ARM | rolling | pacman / 滚动发行 / 不追发行版内核 | 6.18 | - |  |
| Kali ARM | rolling | 安全测试 / Debian 系 / 不追滚动内核 | 6.18 | - |  |
| OpenWrt | 24 | OpenWrt 24 | 6.6 | - |  |
| OpenWrt | 25 | OpenWrt 25 | 6.12 | - |  |

### 3. 完整编译命令列表

#### Armbian 原生镜像

<a id="cmd-armbian-bookworm-61"></a>

##### armbian bookworm 6.1

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh armbian bookworm 6.1 minimal` |
| server | `bash build-image.sh armbian bookworm 6.1 server` |
| desktop | `bash build-image.sh armbian bookworm 6.1 desktop` |

<a id="cmd-armbian-bookworm-618"></a>

##### armbian bookworm 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh armbian bookworm 6.18 minimal` |
| server | `bash build-image.sh armbian bookworm 6.18 server` |
| desktop | `bash build-image.sh armbian bookworm 6.18 desktop` |

<a id="cmd-armbian-trixie-618"></a>

##### armbian trixie 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh armbian trixie 6.18 minimal` |
| server | `bash build-image.sh armbian trixie 6.18 server` |
| desktop | `bash build-image.sh armbian trixie 6.18 desktop` |

<a id="cmd-armbian-trixie-70"></a>

##### armbian trixie 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh armbian trixie 7.0 minimal` |
| server | `bash build-image.sh armbian trixie 7.0 server` |
| desktop | `bash build-image.sh armbian trixie 7.0 desktop` |

##### armbian forky 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### armbian jammy 6.1

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### armbian jammy 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### armbian noble 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### armbian noble 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### armbian resolute 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

#### Debian BSP 打包镜像

<a id="cmd-debian-bookworm-61"></a>

##### debian bookworm 6.1

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh debian bookworm 6.1 minimal` |
| server | `bash build-image.sh debian bookworm 6.1 server` |
| desktop |  |

<a id="cmd-debian-bookworm-618"></a>

##### debian bookworm 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh debian bookworm 6.18 minimal` |
| server | `bash build-image.sh debian bookworm 6.18 server` |
| desktop |  |

<a id="cmd-debian-trixie-618"></a>

##### debian trixie 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh debian trixie 6.18 minimal` |
| server | `bash build-image.sh debian trixie 6.18 server` |
| desktop |  |

<a id="cmd-debian-trixie-70"></a>

##### debian trixie 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal | `bash build-image.sh debian trixie 7.0 minimal` |
| server | `bash build-image.sh debian trixie 7.0 server` |
| desktop |  |

##### debian forky 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

#### Ubuntu BSP 打包镜像

##### ubuntu jammy 6.1

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### ubuntu jammy 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### ubuntu noble 6.18

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### ubuntu noble 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

##### ubuntu resolute 7.0

| 类型 | 编译命令 |
| --- | --- |
| minimal |  |
| server |  |
| desktop |  |

#### 其他系统预留

| 系统 | 发行版 | 内核 | 编译命令 |
| --- | --- | --- | --- |
| FNOS | stable | FN专用内核 |  |
| Alpine Linux | stable | 6.18 |  |
| Fedora | latest | 6.18 |  |
| Arch Linux ARM | rolling | 6.18 |  |
| Kali ARM | rolling | 6.18 |  |
| OpenWrt | 24 | 6.6 |  |
| OpenWrt | 25 | 6.12 |  |

## 四、编译产物位置

Armbian 原生镜像产物：

```bash
~/rk3588_build/build/output/images/
```

Debian BSP 打包镜像产物：

```bash
~/rk3588_build/EasePi-R2-Image-Build/output/images/
```

常见产物：

```text
EasePi-R2-debian-trixie-current-minimal.img
EasePi-R2-debian-trixie-current-minimal.img.xz
EasePi-R2-debian-trixie-current-minimal.img.xz.sha256
```

## 五、登录账户说明

Debian BSP 打包镜像默认不创建公开固定账号。构建时需要设置 root 密码，脚本会在交互终端中提示输入两次。

也可以通过环境变量提前传入 root 密码：

```bash
ROOT_PASSWORD='你的root密码' bash build-image.sh debian trixie 6.18 minimal
```

如果要创建普通 sudo 用户：

```bash
CREATE_USER=yes IMAGE_USER=fk IMAGE_PASSWORD='你的用户密码' ROOT_PASSWORD='你的root密码' \
  bash build-image.sh debian trixie 6.18 minimal
```

Armbian 原生镜像按 Armbian 自身流程处理首次登录账户。

## 六、硬件检测脚本

镜像启动后，可以运行硬件检测脚本：

```bash
sudo bash easepi-r2-hardware-test.sh
```

也可以在线执行：

```bash
bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/fk1124/EasePi-R2-Image-Build/refs/heads/main/easepi-r2-hardware-test.sh')"
```

重点看：

```text
有线网卡 / Wi-Fi / 蓝牙
默认路由 / 网络管理器
HDMI / 音频 / 红外
/dev/dri / GPU 内核模块 / Mesa / Vulkan
VPU / NPU 节点
eMMC / TF / USB / PCIe
```

## 七、项目结构与扩展约定

核心结构：

```text
build-image.sh                 统一入口，负责系统/发行版/内核/镜像类型路由
build.sh                       Armbian 原生镜像适配层
build-bsp-image.sh             Debian BSP 打包镜像适配层
configs/build-matrix.yaml      项目目标矩阵
rootfs/<system>/               各系统 rootfs、软件源、包列表、镜像类型策略
scripts/                       BSP 构建阶段脚本
userpatches/                   Armbian 板级、内核、U-Boot、overlay 适配
```

扩展新目标时按这个顺序走：

```text
1. 先把目标写入 configs/build-matrix.yaml
2. 再补 rootfs/<system>/ 下的软件源、包列表、rootfs 策略
3. 再补 adapter 或扩展已有 adapter
4. 最后把命令填回 README
```

这样后续扩 Ubuntu、Alpine、OpenWrt 时，命令入口、rootfs 逻辑、BSP 打包和板级补丁不会混在一起。

## 八、缓存和清理

BSP deb 包会缓存到：

```text
output/bsp/current/
output/bsp/edge/
output/bsp/vendor/
```

如果已经有对应 BSP，脚本会优先复用，避免每次都重新编译内核。

强制重新编译 BSP：

```bash
FORCE_BSP_REBUILD=yes bash build-image.sh debian trixie 6.18 minimal
```

清理 BSP rootfs 和镜像输出：

```bash
sudo rm -rf output/rootfs output/images
```

清理全部本项目缓存：

```bash
sudo rm -rf output work
```

## 九、常用环境变量

| 变量 | 说明 | 示例 |
| --- | --- | --- |
| `ARMBIAN_BUILD_DIR` | 指定 Armbian Build 目录 | `/root/rk3588_build/build` |
| `CPUTHREADS` | 指定编译线程数 | `8` |
| `REGIONAL_MIRROR` | 指定区域镜像策略 | `china` |
| `MAINLINE_MIRROR` | 指定主线内核镜像 | `google` / `tuna` / `bfsu` |
| `UBOOT_MIRROR` | 指定 U-Boot 源 | `github` / `gitee` |
| `IMAGE_SIZE_MB` | 指定最终镜像大小 | `8192` |
| `BOOT_SIZE_MB` | 指定 boot 分区大小 | `512` |
| `ROOT_PASSWORD` | BSP 镜像 root 密码 | 自定义 |
| `CREATE_USER` | 是否创建普通用户 | `yes` / `no` |
| `IMAGE_USER` | 普通用户名 | `fk` |
| `IMAGE_PASSWORD` | 普通用户密码 | 自定义 |

示例：

```bash
CPUTHREADS=8 bash build-image.sh armbian trixie 6.18 minimal
```

```bash
ROOT_PASSWORD='123456' IMAGE_SIZE_MB=8192 \
  bash build-image.sh debian trixie 6.18 minimal
```

## 十、刷写镜像

以 `.img.xz` 为例：

```bash
xz -dk output/images/EasePi-R2-debian-trixie-current-minimal.img.xz
sudo dd if=output/images/EasePi-R2-debian-trixie-current-minimal.img of=/dev/sdX bs=4M status=progress conv=fsync
```

其中 `/dev/sdX` 要替换成 TF 卡、U 盘或 eMMC 对应设备。

写入前务必确认设备名，避免误写系统盘。
