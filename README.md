# EasePi-R2 Image Build
**EasePi-R2** 多系统镜像构建项目。

## 编译环境要求

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

## 一、安装依赖

```bash
sudo apt update
sudo apt install -y git curl wget rsync unzip xz-utils ca-certificates
sudo apt install -y build-essential gcc g++ make bc bison flex
sudo apt install -y libssl-dev libncurses-dev python3 python3-pip python3-setuptools
sudo apt install -y file cpio qemu-user-static binfmt-support debootstrap
sudo apt install -y parted gdisk dosfstools e2fsprogs util-linux u-boot-tools
sudo apt install -y zstd
```

## 二、基础装备

（一）拉取源码：

```bash
mkdir -p ~/rk3588_build
cd ~/rk3588_build

GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git clone --depth=1 https://github.com/armbian/build.git build
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git clone https://github.com/fk1124/EasePi-R2-Image-Build.git

cd EasePi-R2-Image-Build
chmod +x build-image.sh build.sh build-bsp-image.sh build-alpine-image.sh scripts/*.sh
```
拉取后的目录结构应该为：

```text
~/rk3588_build/
├── build/                         # Armbian 官方 build 源码
└── EasePi-R2-Image-Build/          # 本仓库
    ├── build-image.sh              # 统一构建入口
    ├── build.sh                    # Armbian 原生镜像入口
    ├── build-bsp-image.sh          # Debian / Ubuntu BSP 打包镜像入口
    ├── build-alpine-image.sh       # Alpine 命令预留入口
    ├── configs/                    # 项目矩阵与目标配置
    ├── rootfs/                     # 各系统 rootfs 配置
    ├── scripts/                    # BSP 构建阶段脚本
    └── userpatches/                # Armbian 板级、内核、U-Boot、overlay 适配
```

## 三、开始编译

（一）进入项目目录：

```bash
cd ~/rk3588_build/EasePi-R2-Image-Build
```
（二）输入编译命令开始编译

### 1. 主推镜像

| 镜像 | 状态 | 编译命令 |
| --- | --- | --- |
| Armbian bookworm 6.1 minimal | 已接入 | `bash build-image.sh armbian bookworm 6.1 minimal` |
| Armbian trixie 6.18 minimal | 已接入 | `bash build-image.sh armbian trixie 6.18 minimal` |
| Debian trixie 6.18 minimal | 已接入 | `bash build-image.sh debian trixie 6.18 minimal` |
| Ubuntu noble 6.18 minimal | 已接入 | `bash build-image.sh ubuntu noble 6.18 minimal` |
| Alpine stable 6.18 minimal | 命令已设计，适配未实现 | `bash build-image.sh alpine stable 6.18 minimal` |

### 2. 完整项目矩阵

| 系统 | 发行版 | 备注 | 首推内核 | 次推内核 | 编译脚本跳转 |
| --- | --- | --- | --- | --- | --- |
| armbian | bookworm | Debian 12 | 6.1 | 6.18 | [6.1](#cmd-armbian-bookworm-61) / [6.18](#cmd-armbian-bookworm-618) |
| armbian | trixie | Debian 13 | 6.18 | 7.0 | [6.18](#cmd-armbian-trixie-618) / [7.0](#cmd-armbian-trixie-70) |
| armbian | forky | Debian 14 / 前瞻 | 7.0 | - | [7.0](#cmd-armbian-forky-70) |
| armbian | jammy | Ubuntu 22.04 LTS | 6.1 | 6.18 | [6.1](#cmd-armbian-jammy-61) / [6.18](#cmd-armbian-jammy-618) |
| armbian | noble | Ubuntu 24.04 LTS | 6.18 | 7.0 | [6.18](#cmd-armbian-noble-618) / [7.0](#cmd-armbian-noble-70) |
| armbian | resolute | Ubuntu 26.04 LTS / 前瞻 | 7.0 | - | [7.0](#cmd-armbian-resolute-70) |
| debian | bookworm | Debian 12 BSP 打包镜像 | 6.1 | 6.18 | [6.1](#cmd-debian-bookworm-61) / [6.18](#cmd-debian-bookworm-618) |
| debian | trixie | Debian 13 BSP 打包镜像 | 6.18 | 7.0 | [6.18](#cmd-debian-trixie-618) / [7.0](#cmd-debian-trixie-70) |
| debian | forky | Debian 14 BSP 打包镜像 / 前瞻 | 7.0 | - | [7.0](#cmd-debian-forky-70) |
| ubuntu | jammy | Ubuntu 22.04 LTS BSP 打包镜像 | 6.1 | 6.18 | [6.1](#cmd-ubuntu-jammy-61) / [6.18](#cmd-ubuntu-jammy-618) |
| ubuntu | noble | Ubuntu 24.04 LTS BSP 打包镜像 | 6.18 | 7.0 | [6.18](#cmd-ubuntu-noble-618) / [7.0](#cmd-ubuntu-noble-70) |
| ubuntu | resolute | Ubuntu 26.04 LTS BSP 打包镜像 / 前瞻 | 7.0 | - | [7.0](#cmd-ubuntu-resolute-70) |
| FNOS | stable | 飞牛OS | FN专用内核 | - |  |
| alpine | stable | Alpine Linux / apk 轻量 rootfs / 命令已设计 | 6.18 | - | [6.18](#cmd-alpine-stable-618) |
| Fedora | latest | Fedora 44 | 6.18 | - |  |
| Arch Linux ARM | rolling | pacman / 滚动发行 / 不追发行版内核 | 6.18 | - |  |
| Kali ARM | rolling | 安全测试 / Debian 系 / 不追滚动内核 | 6.18 | - |  |
| OpenWrt | 24 | OpenWrt 24 | 6.6 | - |  |
| OpenWrt | 25 | OpenWrt 25 | 6.12 | - |  |

### 3. 完整编译命令列表

#### Armbian 原生镜像

<a id="cmd-armbian-bookworm-61"></a>

##### armbian bookworm 6.1

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian bookworm 6.1 minimal` | ⭐⭐⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian bookworm 6.1 server` | ⭐⭐⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian bookworm 6.1 desktop` | ⭐⭐⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-bookworm-618"></a>

##### armbian bookworm 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian bookworm 6.18 minimal` | ⭐⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian bookworm 6.18 server` | ⭐⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian bookworm 6.18 desktop` | ⭐⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-trixie-618"></a>

##### armbian trixie 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian trixie 6.18 minimal` | ⭐⭐⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian trixie 6.18 server` | ⭐⭐⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian trixie 6.18 desktop` | ⭐⭐⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-trixie-70"></a>

##### armbian trixie 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian trixie 7.0 minimal` | ⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian trixie 7.0 server` | ⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian trixie 7.0 desktop` | ⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-forky-70"></a>

##### armbian forky 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian forky 7.0 minimal` | ⭐⭐ |  | 最小化前瞻镜像，适合内核/发行版适配验证 |
| server | `bash build-image.sh armbian forky 7.0 server` | ⭐ |  | 前瞻服务器镜像，适合服务组件兼容性验证 |
| desktop | `bash build-image.sh armbian forky 7.0 desktop` | ⭐ |  | 前瞻 XFCE 桌面，适合图形栈兼容性验证 |

<a id="cmd-armbian-jammy-61"></a>

##### armbian jammy 6.1

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian jammy 6.1 minimal` | ⭐⭐⭐ |  | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian jammy 6.1 server` | ⭐⭐ |  | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian jammy 6.1 desktop` | ⭐ |  | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-jammy-618"></a>

##### armbian jammy 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian jammy 6.18 minimal` | ⭐⭐⭐ |  | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian jammy 6.18 server` | ⭐⭐ |  | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian jammy 6.18 desktop` | ⭐ |  | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-noble-618"></a>

##### armbian noble 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian noble 6.18 minimal` | ⭐⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian noble 6.18 server` | ⭐⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian noble 6.18 desktop` | ⭐⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-noble-70"></a>

##### armbian noble 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian noble 7.0 minimal` | ⭐⭐⭐ |  | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh armbian noble 7.0 server` | ⭐⭐ |  | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh armbian noble 7.0 desktop` | ⭐ |  | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-armbian-resolute-70"></a>

##### armbian resolute 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh armbian resolute 7.0 minimal` | ⭐⭐ |  | 最小化前瞻镜像，适合内核/发行版适配验证 |
| server | `bash build-image.sh armbian resolute 7.0 server` | ⭐ |  | 前瞻服务器镜像，适合服务组件兼容性验证 |
| desktop | `bash build-image.sh armbian resolute 7.0 desktop` | ⭐ |  | 前瞻 XFCE 桌面，适合图形栈兼容性验证 |

#### Debian BSP 打包镜像

<a id="cmd-debian-bookworm-61"></a>

##### debian bookworm 6.1

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh debian bookworm 6.1 minimal` | ⭐⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh debian bookworm 6.1 server` | ⭐⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh debian bookworm 6.1 desktop` | ⭐⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-debian-bookworm-618"></a>

##### debian bookworm 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh debian bookworm 6.18 minimal` | ⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh debian bookworm 6.18 server` | ⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh debian bookworm 6.18 desktop` | ⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-debian-trixie-618"></a>

##### debian trixie 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh debian trixie 6.18 minimal` | ⭐⭐⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh debian trixie 6.18 server` | ⭐⭐⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh debian trixie 6.18 desktop` | ⭐⭐⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-debian-trixie-70"></a>

##### debian trixie 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh debian trixie 7.0 minimal` | ⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh debian trixie 7.0 server` | ⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh debian trixie 7.0 desktop` | ⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-debian-forky-70"></a>

##### debian forky 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh debian forky 7.0 minimal` | ⭐⭐ |  | 最小化前瞻镜像，适合内核/发行版适配验证 |
| server | `bash build-image.sh debian forky 7.0 server` | ⭐ |  | 前瞻服务器镜像，适合服务组件兼容性验证 |
| desktop | `bash build-image.sh debian forky 7.0 desktop` | ⭐ |  | 前瞻 XFCE 桌面，适合图形栈兼容性验证 |

#### Ubuntu BSP 打包镜像

<a id="cmd-ubuntu-jammy-61"></a>

##### ubuntu jammy 6.1

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh ubuntu jammy 6.1 minimal` | ⭐⭐⭐ |  | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh ubuntu jammy 6.1 server` | ⭐⭐ |  | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh ubuntu jammy 6.1 desktop` | ⭐ |  | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-ubuntu-jammy-618"></a>

##### ubuntu jammy 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh ubuntu jammy 6.18 minimal` | ⭐⭐⭐ |  | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh ubuntu jammy 6.18 server` | ⭐⭐ |  | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh ubuntu jammy 6.18 desktop` | ⭐ |  | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-ubuntu-noble-618"></a>

##### ubuntu noble 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh ubuntu noble 6.18 minimal` | ⭐⭐⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh ubuntu noble 6.18 server` | ⭐⭐⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh ubuntu noble 6.18 desktop` | ⭐⭐⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-ubuntu-noble-70"></a>

##### ubuntu noble 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh ubuntu noble 7.0 minimal` | ⭐⭐⭐ | ✅ | 最小化镜像，适合首轮启动与二次定制 |
| server | `bash build-image.sh ubuntu noble 7.0 server` | ⭐⭐ | ✅ | 增加容器/路由/运维组件，适合长期运行 |
| desktop | `bash build-image.sh ubuntu noble 7.0 desktop` | ⭐ | ✅ | XFCE 桌面，适合 HDMI/GPU/图形栈验证 |

<a id="cmd-ubuntu-resolute-70"></a>

##### ubuntu resolute 7.0

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh ubuntu resolute 7.0 minimal` | ⭐⭐ |  | 最小化前瞻镜像，适合内核/发行版适配验证 |
| server | `bash build-image.sh ubuntu resolute 7.0 server` | ⭐ |  | 前瞻服务器镜像，适合服务组件兼容性验证 |
| desktop | `bash build-image.sh ubuntu resolute 7.0 desktop` | ⭐ |  | 前瞻 XFCE 桌面，适合图形栈兼容性验证 |

#### Alpine Linux 轻量镜像命令设计

<a id="cmd-alpine-stable-618"></a>

##### alpine stable 6.18

| 类型 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- |
| minimal | `bash build-image.sh alpine stable 6.18 minimal` | ⭐⭐ | 命令已设计，适配未实现 | Alpine stable apk 基础 rootfs，优先用于轻量启动验证 |
| server | `bash build-image.sh alpine stable 6.18 server` | ⭐ | 命令已设计，适配未实现 | 在 minimal 基础上追加路由/运维组件，后续随 apk/OpenRC 适配接入 |

当前 Alpine 命令已经通过 `build-image.sh` 统一入口预留，但 `build-alpine-image.sh` 仍会以 TODO 状态退出，不会生成镜像。后续实现时会优先走 `apk` rootfs bootstrap，并单独编写 OpenRC 网络/服务策略，不直接复用 Debian / Ubuntu 的 systemd overlay。

#### 其他系统预留

| 系统 | 发行版 | 内核 | 编译命令 | 推荐指数 | 验证 | 所选镜像说明 |
| --- | --- | --- | --- | --- | --- | --- |
| FNOS | stable | FN专用内核 |  |  | 未接入 | FNOS 路线预留 |
| Fedora | latest | 6.18 |  |  | 未接入 | Fedora rootfs 路线预留 |
| Arch Linux ARM | rolling | 6.18 |  |  | 未接入 | 滚动发行 rootfs 路线预留 |
| Kali ARM | rolling | 6.18 |  |  | 未接入 | 安全测试 rootfs 路线预留 |
| OpenWrt | 24 | 6.6 |  |  | 未接入 | OpenWrt 24 路线预留 |
| OpenWrt | 25 | 6.12 |  |  | 未接入 | OpenWrt 25 路线预留 |

## 四、编译产物位置

Armbian 原生镜像产物：

```bash
~/rk3588_build/build/output/images/
```

Debian / Ubuntu BSP 打包镜像产物：

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

Debian / Ubuntu BSP 打包镜像默认不创建公开固定账号。构建时需要设置 root 密码，脚本会在交互终端中提示输入两次。

也可以通过环境变量提前传入 root 密码：

```bash
ROOT_PASSWORD='你的root密码' bash build-image.sh debian trixie 6.18 minimal
```

桌面专用预设脚本：

```bash
bash debian-6.1-xfce.sh
bash debian-6.18-xfce.sh
bash ubuntu-noble-kde.sh
```

这 3 个脚本会在编译开始时交互要求：

```text
1. 桌面 sudo 用户名
2. 桌面 sudo 用户密码
3. root 密码
```

这些桌面预设镜像默认仍然开机进入 tty，不会直接进桌面。登录 tty 后：

```bash
desktop
```

会以预设桌面用户执行 `startx` 进入本地 HDMI 桌面；注销桌面后会直接回到 tty。如果你想确认系统保持 tty 默认启动，可执行：

```bash
desktop-disable
```

桌面预设默认包含：

```text
简体中文 locale / 中文字体 / fcitx5 中文输入法 / 中文桌面语言包
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
build-bsp-image.sh             Debian / Ubuntu BSP 打包镜像适配层
build-alpine-image.sh          Alpine Linux 命令预留适配层
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
output/bsp/debian-bookworm-vendor/
output/bsp/debian-bookworm-current/
output/bsp/debian-trixie-current/
output/bsp/debian-trixie-linux7/
output/bsp/debian-forky-linux7/
output/bsp/ubuntu-jammy-vendor/
output/bsp/ubuntu-jammy-current/
output/bsp/ubuntu-noble-current/
output/bsp/ubuntu-noble-linux7/
output/bsp/ubuntu-resolute-linux7/
```

如果已经有对应 BSP，脚本会优先复用，避免每次都重新编译内核。BSP 缓存按 `系统-发行版-内核` 隔离，避免不同发行版复用或覆盖同一组 BSP deb。

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
| `UBOOT_MIRROR` | 指定 U-Boot 源 | `github` |
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
