#!/usr/bin/env bash
# EasePi-R2 hardware test helper
# Install:
#   bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/fk1124/EasePi-R2-Image-Build/refs/heads/main/easepi-r2-hardware-test.sh')"
# Run:
#   hwt

set -euo pipefail

HWT_VERSION="2026.05.08"
HWT_NAME="EasePi-R2 Hardware Test"
HWT_RAW_URL="${HWT_RAW_URL:-https://raw.githubusercontent.com/fk1124/EasePi-R2-Image-Build/refs/heads/main/easepi-r2-hardware-test.sh}"
HWT_BIN="${HWT_BIN:-/usr/local/sbin/hwt}"
HWT_STATE_DIR="${HWT_STATE_DIR:-/var/lib/easepi-r2-hwt}"
HWT_LOG_DIR="${HWT_LOG_DIR:-/var/log/easepi-r2-hwt}"
HWT_INSTALLED_LIST="${HWT_STATE_DIR}/installed-packages.list"

if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

is_installed_invocation() {
    [ -f "${HWT_BIN}" ] && [ "$(readlink -f "${SCRIPT_PATH}" 2>/dev/null || true)" = "$(readlink -f "${HWT_BIN}" 2>/dev/null || true)" ]
}

install_self() {
    echo
    echo "Installing ${HWT_NAME} ${HWT_VERSION} ..."
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl not found. Please install curl first."
        exit 1
    fi

    ${SUDO} mkdir -p "$(dirname "${HWT_BIN}")" "${HWT_STATE_DIR}" "${HWT_LOG_DIR}"
    tmp="$(mktemp)"
    if ! curl -fsSL "${HWT_RAW_URL}" -o "${tmp}"; then
        rm -f "${tmp}"
        echo "ERROR: failed to download script:"
        echo "  ${HWT_RAW_URL}"
        exit 1
    fi

    ${SUDO} install -m 0755 "${tmp}" "${HWT_BIN}"
    rm -f "${tmp}"

    echo
    echo "Installed:"
    echo "  ${HWT_BIN}"
    echo
    echo "Run:"
    echo "  hwt"
    echo
}

uninstall_self() {
    echo
    echo "This will remove:"
    echo "  ${HWT_BIN}"
    echo "  ${HWT_STATE_DIR}"
    echo
    read -r -p "Confirm uninstall hwt? [y/N]: " ans
    case "${ans}" in
        y|Y|yes|YES)
            ${SUDO} rm -f "${HWT_BIN}"
            ${SUDO} rm -rf "${HWT_STATE_DIR}"
            echo "Uninstalled hwt."
            ;;
        *)
            echo "Cancelled."
            ;;
    esac
}

# When executed by:
#   bash -c "$(curl -fsSL URL)"
# there is no local script path to reuse. Install from RAW URL and exit.
if ! is_installed_invocation; then
    case "${1:-}" in
        --run-without-install)
            ;;
        --version)
            echo "${HWT_VERSION}"
            exit 0
            ;;
        *)
            install_self
            exit 0
            ;;
    esac
fi

pause() {
    echo
    read -r -p "按回车返回菜单..." _
}

line() {
    printf '%*s\n' "${COLUMNS:-88}" '' | tr ' ' '-'
}

title() {
    echo
    echo -e "${C_BOLD}${C_BLUE}$*${C_RESET}"
    line
}

sub_title() {
    echo
    echo -e "${C_BOLD}${C_CYAN}$*${C_RESET}"
}

ok() {
    printf "${C_GREEN}[OK]${C_RESET} %s\n" "$*"
}

warn() {
    printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"
}

fail() {
    printf "${C_RED}[FAIL]${C_RESET} %s\n" "$*"
}

info() {
    printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$*"
}

skip() {
    printf "${C_YELLOW}[SKIP]${C_RESET} %s\n" "$*"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_root_note() {
    if [ "$(id -u)" -ne 0 ]; then
        warn "当前不是 root，部分硬件/内核检测可能不完整。建议 sudo hwt 或 root 执行。"
    fi
}

os_id() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        printf '%s' "${ID:-unknown}"
    else
        printf 'unknown'
    fi
}

os_pretty() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        printf '%s' "${PRETTY_NAME:-unknown}"
    else
        printf 'unknown'
    fi
}

kconfig_file() {
    if [ -r /proc/config.gz ]; then
        echo "/proc/config.gz"
    elif [ -r "/boot/config-$(uname -r)" ]; then
        echo "/boot/config-$(uname -r)"
    else
        echo ""
    fi
}

kconfig_get() {
    local key="$1"
    local cfg
    cfg="$(kconfig_file)"

    if [ -z "${cfg}" ]; then
        return 2
    fi

    if [ "${cfg}" = "/proc/config.gz" ]; then
        zgrep -E "^${key}=|^# ${key} is not set" "${cfg}" 2>/dev/null | head -n 1 || true
    else
        grep -E "^${key}=|^# ${key} is not set" "${cfg}" 2>/dev/null | head -n 1 || true
    fi
}

kconfig_enabled() {
    local key="$1"
    local val
    val="$(kconfig_get "${key}")"
    echo "${val}" | grep -qE "^${key}=y|^${key}=m"
}

check_feature() {
    local name="$1"
    local key="$2"
    if kconfig_enabled "${key}"; then
        ok "${name}: ${key} 已开启"
    else
        local val
        val="$(kconfig_get "${key}")"
        if [ -n "${val}" ]; then
            warn "${name}: ${val}"
        else
            warn "${name}: ${key} 未在当前可读内核配置中找到"
        fi
    fi
}

print_file_if_exists() {
    local file="$1"
    local label="$2"
    if [ -r "${file}" ]; then
        echo
        echo "${label}:"
        sed 's/^/  /' "${file}" 2>/dev/null || true
    fi
}


print_ethtool_summary() {
    local iface="$1"
    if ! has_cmd ethtool; then
        cat "/sys/class/net/${iface}/operstate" 2>/dev/null | sed 's/^/  state: /' || true
        return 0
    fi

    ethtool -i "${iface}" 2>/dev/null | sed 's/^/  /' || true

    local speed duplex autoneg link
    speed="$(ethtool "${iface}" 2>/dev/null | awk -F: '/^[[:space:]]*Speed:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    duplex="$(ethtool "${iface}" 2>/dev/null | awk -F: '/^[[:space:]]*Duplex:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    autoneg="$(ethtool "${iface}" 2>/dev/null | awk -F: '/^[[:space:]]*Auto-negotiation:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    link="$(ethtool "${iface}" 2>/dev/null | awk -F: '/^[[:space:]]*Link detected:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"

    printf '  Speed             : %s\n' "${speed:-Unknown}"
    printf '  Duplex            : %s\n' "${duplex:-Unknown}"
    printf '  Auto-negotiation  : %s\n' "${autoneg:-Unknown}"
    printf '  Link detected     : %s\n' "${link:-Unknown}"

    echo "  Supported speeds  :"
    ethtool "${iface}" 2>/dev/null | awk '
        /^[[:space:]]*Supported link modes:/ {flag=1; sub(/^[[:space:]]*Supported link modes:[[:space:]]*/, ""); if ($0) print "    " $0; next}
        flag && /^[[:space:]]+/ {print "    " $0; next}
        flag {flag=0}
    ' | sed '/^[[:space:]]*$/d' || true
}

find_wireless_ifaces() {
    local found=0
    for dev in /sys/class/net/*; do
        [ -d "${dev}" ] || continue
        if [ -d "${dev}/wireless" ]; then
            basename "${dev}"
            found=1
        fi
    done
    return 0
}

print_dmesg_gpu_hint() {
    if ! has_cmd dmesg; then
        skip "dmesg 不可用"
        return 0
    fi
    local lines
    lines="$(dmesg 2>/dev/null | grep -Ei 'panthor|panfrost|mali|gpu|rknpu|drm|firmware|opp' | tail -n 80 || true)"
    if [ -n "${lines}" ]; then
        echo "${lines}" | sed 's/^/  /'
    else
        skip "dmesg 中未匹配到 GPU/Mali/Panthor/Panfrost 相关信息，或当前用户无权限读取 dmesg"
    fi
}

print_kernel_gpu_config() {
    local keys=(CONFIG_DRM_PANTHOR CONFIG_DRM_PANFROST CONFIG_MALI_BIFROST CONFIG_MALI_MIDGARD CONFIG_DRM_ROCKCHIP CONFIG_DRM_SCHED CONFIG_PM_DEVFREQ CONFIG_DEVFREQ_THERMAL)
    for k in "${keys[@]}"; do
        local v
        v="$(kconfig_get "${k}" || true)"
        if [ -n "${v}" ]; then
            echo "  ${v}"
        else
            echo "  ${k}: 未找到"
        fi
    done
}

try_modprobe_dryrun() {
    local mod="$1"
    if has_cmd modinfo && modinfo "${mod}" >/dev/null 2>&1; then
        ok "内核模块存在：${mod}"
        if has_cmd modprobe; then
            local out
            out="$(modprobe -n -v "${mod}" 2>&1 || true)"
            [ -n "${out}" ] && echo "  modprobe dry-run: ${out}"
        fi
    else
        warn "内核模块不存在或不可查询：${mod}"
    fi
}

apt_update_ok() {
    local log
    log="$(mktemp)"
    if apt-get update 2>&1 | tee "${log}"; then
        if grep -qiE 'Failed to fetch|Unable to connect|Could not connect|Temporary failure|Some index files failed' "${log}"; then
            rm -f "${log}"
            return 1
        fi
        rm -f "${log}"
        return 0
    fi
    rm -f "${log}"
    return 1
}

detect_basic_info() {
    title "一、基本信息"

    need_root_note

    echo "脚本版本      : ${HWT_VERSION}"
    echo "系统版本      : $(os_pretty)"
    echo "内核版本      : $(uname -r)"
    echo "系统架构      : $(uname -m)"
    echo "运行时间      : $(uptime -p 2>/dev/null || true)"

    if [ -r /proc/device-tree/model ]; then
        echo "板卡型号      : $(tr -d '\0' < /proc/device-tree/model)"
    else
        echo "板卡型号      : 未读取到 /proc/device-tree/model"
    fi

    if has_cmd lscpu; then
        echo
        lscpu | awk -F: '
            /Architecture|Model name|CPU\(s\)|Thread|Core|Socket|Vendor ID|CPU max MHz|CPU min MHz|BogoMIPS/ {
                gsub(/^[ \t]+/, "", $2);
                printf "CPU %-16s: %s\n", $1, $2
            }'
    else
        echo
        grep -m1 -E 'Hardware|model name|Processor' /proc/cpuinfo 2>/dev/null || true
        echo "核心数        : $(nproc 2>/dev/null || echo unknown)"
    fi

    echo
    echo "CPU 频率："
    if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq >/dev/null 2>&1; then
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            cpu="$(echo "${f}" | sed -E 's#.*/(cpu[0-9]+)/.*#\1#')"
            cur="$(cat "${f}" 2>/dev/null || echo 0)"
            max="$(cat "$(dirname "${f}")/cpuinfo_max_freq" 2>/dev/null || echo 0)"
            printf "  %-5s 当前 %7s MHz / 最大 %7s MHz\n" "${cpu}" "$((cur/1000))" "$((max/1000))"
        done
    else
        skip "未发现 cpufreq 信息"
    fi

    echo
    free -h 2>/dev/null || true

    echo
    echo "存储与挂载："
    if has_cmd lsblk; then
        lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null || lsblk
    else
        df -hT
    fi

    print_file_if_exists /proc/cmdline "内核启动参数"
}

detect_gpio_bus_storage() {
    title "二、硬件识别：GPIO / 总线 / 存储 / 接口"

    sub_title "PCIe / USB / I2C / SPI / GPIO"
    if has_cmd lspci; then
        echo
        echo "PCIe 设备："
        lspci -nn || true
    else
        skip "lspci 未安装，无法完整查看 PCIe 设备"
    fi

    if has_cmd lsusb; then
        echo
        echo "USB 拓扑："
        lsusb -t || true
        echo
        echo "USB 设备："
        lsusb || true
    else
        skip "lsusb 未安装，无法完整查看 USB 设备"
    fi

    echo
    echo "I2C："
    ls -l /dev/i2c-* 2>/dev/null || skip "未发现 /dev/i2c-*"

    echo
    echo "SPI："
    ls -l /dev/spidev* 2>/dev/null || skip "未发现 /dev/spidev*"

    echo
    echo "GPIO："
    if has_cmd gpioinfo; then
        gpioinfo 2>/dev/null | head -n 80 || true
    else
        ls -l /dev/gpiochip* 2>/dev/null || skip "未发现 /dev/gpiochip*；gpioinfo 未安装"
    fi

    sub_title "LED / 温度 / 传感器 / 看门狗"
    echo
    echo "LED："
    if [ -d /sys/class/leds ]; then
        find /sys/class/leds -maxdepth 1 -mindepth 1 -printf "  %f\n" 2>/dev/null || true
    else
        skip "未发现 /sys/class/leds"
    fi

    echo
    echo "Thermal zones："
    if [ -d /sys/class/thermal ]; then
        for z in /sys/class/thermal/thermal_zone*; do
            [ -d "${z}" ] || continue
            type="$(cat "${z}/type" 2>/dev/null || echo unknown)"
            temp="$(cat "${z}/temp" 2>/dev/null || echo "")"
            if [ -n "${temp}" ]; then
                printf "  %-30s %s°C\n" "${type}" "$(awk "BEGIN{printf \"%.1f\", ${temp}/1000}")"
            else
                printf "  %s\n" "${type}"
            fi
        done
    else
        skip "未发现 thermal 信息"
    fi

    echo
    echo "hwmon："
    if [ -d /sys/class/hwmon ]; then
        for h in /sys/class/hwmon/hwmon*; do
            [ -d "${h}" ] || continue
            name="$(cat "${h}/name" 2>/dev/null || basename "${h}")"
            echo "  ${name}"
        done
    else
        skip "未发现 hwmon"
    fi

    echo
    echo "watchdog："
    ls -l /dev/watchdog* 2>/dev/null || skip "未发现 /dev/watchdog*"

    sub_title "存储接口：eMMC / TF / NVMe / SATA"
    echo
    if has_cmd lsblk; then
        lsblk -o NAME,MODEL,SIZE,TYPE,TRAN,ROTA,FSTYPE,MOUNTPOINTS 2>/dev/null || lsblk
    fi

    echo
    echo "MMC/TF/eMMC："
    ls -l /dev/mmcblk* 2>/dev/null || skip "未发现 /dev/mmcblk*"
    if [ -d /sys/bus/mmc/devices ]; then
        find /sys/bus/mmc/devices -maxdepth 1 -mindepth 1 -printf "  %f\n" 2>/dev/null || true
    fi

    echo
    echo "NVMe / M.2："
    ls -l /dev/nvme* 2>/dev/null || skip "未发现 /dev/nvme*"
    if has_cmd nvme; then
        nvme list 2>/dev/null || true
    fi

    echo
    echo "SATA / AHCI："
    if has_cmd lspci; then
        lspci -nn | grep -Ei 'sata|ahci' || skip "PCIe 中未发现 SATA/AHCI 控制器"
    fi
    lsblk -S 2>/dev/null || true

    sub_title "Type-C OTG / USB 控制器"
    echo
    echo "UDC 设备模式控制器："
    ls -l /sys/class/udc 2>/dev/null || skip "未发现 /sys/class/udc"

    echo
    echo "Type-C class："
    ls -l /sys/class/typec 2>/dev/null || skip "未发现 /sys/class/typec"

    echo
    echo "USB role："
    find /sys -path '*usb_role*' -maxdepth 6 -type d 2>/dev/null | sed 's/^/  /' || true
}

detect_network() {
    title "二、硬件识别：网卡 / 4G / Wi-Fi / 蓝牙"

    sub_title "有线网卡"
    if has_cmd ip; then
        ip -br link || true
    fi

    echo
    echo "Realtek 2.5G 网卡识别："
    local rtl_count=0
    if has_cmd lspci; then
        lspci -nn | grep -Ei 'Realtek|RTL8125|8125|2.5G' || true
        rtl_count="$(lspci -nn | grep -Eic 'RTL8125|8125|Realtek.*2\.5|Realtek.*Ethernet' || true)"
        if [ "${rtl_count}" -ge 4 ]; then
            ok "已识别 ${rtl_count} 个 Realtek/RTL8125 PCIe 网卡，符合 EasePi-R2 四个 2.5G 网口预期"
        elif [ "${rtl_count}" -gt 0 ]; then
            warn "仅识别到 ${rtl_count} 个 Realtek/RTL8125 相关设备，期望 4 个 2.5G 网口"
        else
            warn "未从 lspci 识别到 RTL8125/Realtek 2.5G 网卡"
        fi
    else
        skip "lspci 未安装，无法统计 RTL8125BG"
    fi

    echo
    echo "网卡驱动 / 链路 / 速率："
    for dev in /sys/class/net/*; do
        iface="$(basename "${dev}")"
        case "${iface}" in
            lo|docker*|br-*|veth*|virbr*|tailscale*|wg*|tun*|tap*) continue ;;
        esac
        echo
        echo "Interface: ${iface}"
        print_ethtool_summary "${iface}"
    done

    sub_title "4G / LTE 模块"
    local modem_found=0
    echo
    echo "蜂窝相关 USB 设备："
    if has_cmd lsusb; then
        if lsusb | grep -Ei 'quectel|fibocom|simcom|meig|huawei|zte|sierra|mobile|lte|wwan|modem|cdc|qmi|mbim|asr|ml307|2ecc' ; then
            modem_found=1
        else
            skip "lsusb 未匹配到常见 4G/LTE/5G 模块关键词"
        fi
    else
        skip "lsusb 未安装"
    fi

    echo
    echo "蜂窝相关设备节点："
    if ls -l /dev/ttyUSB* /dev/cdc-wdm* /dev/wwan* 2>/dev/null; then
        modem_found=1
    else
        skip "未发现 ttyUSB/cdc-wdm/wwan 设备节点"
    fi

    echo
    echo "RNDIS/USB 网卡模式："
    local rndis_found=0
    for dev in /sys/class/net/*; do
        [ -d "${dev}" ] || continue
        iface="$(basename "${dev}")"
        driver="$(basename "$(readlink -f "${dev}/device/driver" 2>/dev/null || echo unknown)" 2>/dev/null || echo unknown)"
        if [ "${driver}" = "rndis_host" ] || [ "${driver}" = "cdc_ether" ] || [ "${driver}" = "cdc_ncm" ]; then
            ok "检测到蜂窝模块网卡模式：${iface}，driver=${driver}"
            rndis_found=1
            modem_found=1
        fi
    done
    [ "${rndis_found}" -eq 0 ] && skip "未发现 rndis_host/cdc_ether/cdc_ncm 网卡"

    if has_cmd mmcli; then
        echo
        mmcli -L 2>/dev/null || true
    else
        skip "mmcli 未安装"
    fi

    if [ "${modem_found}" -eq 1 ]; then
        ok "4G/LTE 模块已有识别迹象；如果只有 RNDIS 网卡而无 ttyUSB/cdc-wdm，表示当前模块工作在网卡模式"
    else
        warn "未检测到明确 4G/LTE 模块"
    fi

    sub_title "Wi-Fi"
    local wifi_found=0
    if has_cmd iw; then
        if iw dev 2>/dev/null; then
            wifi_found=1
        else
            warn "iw 未发现 Wi-Fi 接口"
        fi
    else
        skip "iw 未安装，使用 /sys/class/net/*/wireless 兜底检测"
    fi

    local wifi_ifaces
    wifi_ifaces="$(find_wireless_ifaces || true)"
    if [ -n "${wifi_ifaces}" ]; then
        ok "发现 Wi-Fi 接口：$(echo "${wifi_ifaces}" | tr '
' ' ')"
        wifi_found=1
    fi

    if has_cmd rfkill; then
        rfkill list 2>/dev/null || true
    fi
    lsmod | grep -Ei 'cfg80211|mac80211|brcm|rtl|rtw|mt76|ath' || true
    if [ "${wifi_found}" -eq 0 ]; then
        warn "未确认 Wi-Fi 接口；如果已加载 brcmfmac/cfg80211，建议安装 iw 后复测"
    fi

    sub_title "蓝牙"
    ls -l /sys/class/bluetooth 2>/dev/null || true
    if has_cmd bluetoothctl; then
        bluetoothctl list 2>/dev/null || warn "bluetoothctl 未发现控制器，或 bluetooth 服务未运行"
    else
        skip "bluetoothctl 未安装"
    fi
    if has_cmd hciconfig; then
        hciconfig -a 2>/dev/null || true
        if hciconfig -a 2>/dev/null | grep -q 'AA:AA:AA:AA:AA:AA'; then
            warn "蓝牙地址为 AA:AA:AA:AA:AA:AA，可能是默认占位地址；如需实际配对，建议检查 Broadcom BT 固件/NVRAM"
        fi
    fi
}


detect_gpu_vpu_npu_hdmi() {
    title "三、驱动支持：GPU / VPU / NPU / HDMI"

    sub_title "GPU：Mali-G610 MP4 / 显示输出分层检测"

    echo
    echo "1) DRM / 显示节点："
    if [ -d /dev/dri ]; then
        ls -l /dev/dri 2>/dev/null || true
    else
        warn "未发现 /dev/dri，DRM 显示框架可能未启用"
    fi

    local has_card=0 has_render=0 has_mali_node=0 gpu_driver="none"
    ls /dev/dri/card* >/dev/null 2>&1 && has_card=1
    ls /dev/dri/renderD* >/dev/null 2>&1 && has_render=1
    ls /dev/mali* >/dev/null 2>&1 && has_mali_node=1

    echo
    echo "2) GPU / DRM 内核模块："
    lsmod | grep -Ei 'panthor|panfrost|mali|kbase|rockchipdrm|drm|gpu' || true

    if lsmod | grep -q '^panthor'; then
        gpu_driver="panthor"
    elif lsmod | grep -q '^panfrost'; then
        gpu_driver="panfrost"
    elif lsmod | grep -Eiq 'mali|kbase'; then
        gpu_driver="mali/vendor"
    fi

    echo
    echo "3) GPU 内核配置："
    print_kernel_gpu_config

    echo
    echo "4) GPU 模块可用性 dry-run："
    try_modprobe_dryrun panthor
    try_modprobe_dryrun panfrost

    echo
    echo "5) GPU 设备树 / sysfs 线索："
    find /sys/bus/platform/devices -maxdepth 1 \( -iname '*gpu*' -o -iname '*mali*' \) -printf '  %f
' 2>/dev/null || true
    find /proc/device-tree -maxdepth 5 \( -iname '*gpu*' -o -iname '*mali*' \) -print 2>/dev/null | head -n 30 | sed 's/^/  /' || true

    echo
    echo "6) GPU dmesg 线索："
    print_dmesg_gpu_hint

    echo
    echo "7) GPU 用户态："
    if has_cmd glxinfo; then
        glxinfo -B 2>/dev/null | sed 's/^/  /' || true
    else
        skip "glxinfo 未安装，无法判断 Mesa OpenGL/EGL 用户态"
    fi
    if has_cmd vulkaninfo; then
        vulkaninfo --summary 2>/dev/null | sed 's/^/  /' || true
    else
        skip "vulkaninfo 未安装，无法判断 Vulkan 用户态"
    fi

    echo
    echo "GPU 结论："
    if [ "${has_card}" -eq 1 ]; then
        ok "DRM 显示节点存在：/dev/dri/card*，说明显示框架/HDMI 输出基础存在"
    else
        warn "未发现 /dev/dri/card*，显示 DRM 节点不存在"
    fi

    if [ "${has_render}" -eq 1 ]; then
        ok "DRM render 节点存在：/dev/dri/renderD*，3D/计算用户态具备基础入口"
    else
        warn "未发现 /dev/dri/renderD*，当前不能确认 Mali-G610 3D GPU 加速可用"
    fi

    case "${gpu_driver}" in
        panthor)
            ok "检测到 panthor：这是主线内核面向较新 Mali GPU 的 DRM 驱动方向，适合 Mali-G610 检测"
            ;;
        panfrost)
            ok "检测到 panfrost：Mali DRM 驱动已加载"
            ;;
        mali/vendor)
            ok "检测到 Mali/vendor 相关驱动，可能是 vendor 驱动栈"
            ;;
        *)
            warn "未检测到 panthor/panfrost/mali_kbase 等明确 GPU 驱动模块"
            ;;
    esac

    if [ "${has_mali_node}" -eq 1 ]; then
        ok "发现 /dev/mali*，vendor Mali 用户态可能可用"
    fi

    if [ "${has_card}" -eq 1 ] && [ "${has_render}" -eq 0 ]; then
        info "当前更像是：HDMI/显示 DRM 可用，但 Mali-G610 3D GPU 加速尚未启用或驱动未绑定"
    fi

    sub_title "VPU / RGA / 视频编解码"
    echo
    echo "Video 节点："
    ls -l /dev/video* /dev/media* 2>/dev/null || warn "未发现 /dev/video* 或 /dev/media*"
    echo
    echo "VPU/RGA 模块："
    lsmod | grep -Ei 'rkvdec|hantro|vpu|rga|mpp|vdec|venc|vepu|rockchip.*v' || true
    if has_cmd v4l2-ctl; then
        echo
        v4l2-ctl --list-devices 2>/dev/null || true
    else
        skip "v4l2-ctl 未安装"
    fi
    if has_cmd ffmpeg; then
        echo
        ffmpeg -hide_banner -hwaccels 2>/dev/null || true
    fi

    sub_title "NPU"
    echo
    ls -l /dev/rknpu* 2>/dev/null || warn "未发现 /dev/rknpu*"
    echo
    lsmod | grep -Ei 'rknpu|npu' || true
    echo
    echo "NPU 内核配置："
    for k in CONFIG_ROCKCHIP_RKNPU CONFIG_RKNPU CONFIG_DRM_ACCEL; do
        v="$(kconfig_get "${k}" || true)"
        [ -n "${v}" ] && echo "  ${v}" || echo "  ${k}: 未找到"
    done
    if [ -e /dev/rknpu ] || ls /dev/rknpu* >/dev/null 2>&1; then
        ok "检测到 NPU 设备节点"
    else
        warn "未检测到 NPU 设备节点；主线 current 内核下 RK3588 NPU 通常还需要额外驱动/用户态配合"
    fi

    for bin in rknn_server rknn_benchmark rknn_toolkit_lite_test; do
        if has_cmd "${bin}"; then
            ok "发现 NPU 用户态工具：${bin}"
        fi
    done

    sub_title "HDMI OUT / HDMI IN"
    echo
    echo "DRM connectors："
    if [ -d /sys/class/drm ]; then
        for s in /sys/class/drm/card*-*/status; do
            [ -f "${s}" ] || continue
            conn="$(basename "$(dirname "${s}")")"
            status="$(cat "${s}" 2>/dev/null || echo unknown)"
            printf "  %-24s %s
" "${conn}" "${status}"
            if [ -f "$(dirname "${s}")/modes" ]; then
                sed 's/^/    mode: /' "$(dirname "${s}")/modes" 2>/dev/null | head -n 8
            fi
        done
    else
        warn "未发现 /sys/class/drm"
    fi

    echo
    echo "HDMI IN / Capture 相关："
    if has_cmd v4l2-ctl; then
        v4l2-ctl --list-devices 2>/dev/null | grep -Ei -A5 'hdmi|capture|rkisp|csi|video' || true
    else
        ls -l /dev/video* 2>/dev/null || true
    fi
}


device_detect() {
    clear || true
    title "${HWT_NAME} - 设备检测"
    detect_basic_info
    detect_gpio_bus_storage
    detect_network
    detect_gpu_vpu_npu_hdmi
    echo
    ok "设备检测完成"
}

apt_available_packages() {
    local pkgs=("$@")
    local out=()
    for p in "${pkgs[@]}"; do
        if apt-cache show "${p}" >/dev/null 2>&1; then
            out+=("${p}")
        fi
    done
    printf '%s\n' "${out[@]}"
}

install_test_deps() {
    title "检测依赖安装"

    if [ "$(id -u)" -ne 0 ]; then
        fail "请用 root 或 sudo 执行 hwt 后再安装依赖"
        return 1
    fi

    if ! has_cmd apt-get; then
        fail "当前系统没有 apt-get，暂不支持自动安装"
        return 1
    fi

    local candidates=(
        pciutils usbutils ethtool iproute2 kmod procps util-linux
        lshw dmidecode v4l-utils i2c-tools gpiod rfkill wireless-tools iw
        bluez bluez-tools alsa-utils mesa-utils vulkan-tools
        fio hdparm smartmontools nvme-cli mmc-utils iperf3 jq curl wget
        openssl
    )

    echo "准备安装可用检测工具..."
    if ! apt_update_ok; then
        fail "apt update 失败，已停止依赖安装。"
        echo
        echo "常见原因：DNS、代理 fake-ip、默认 Debian 源无法访问、系统时间错误。"
        echo "你可以先修复网络/软件源后再进 hwt -> 性能测试 -> 检测依赖安装。"
        echo
        echo "临时 DNS 示例："
        echo "  cat >/etc/resolv.conf <<'EOF'"
        echo "  nameserver 223.5.5.5"
        echo "  nameserver 114.114.114.114"
        echo "  EOF"
        return 1
    fi

    mapfile -t available < <(apt_available_packages "${candidates[@]}")
    local to_install=()
    mkdir -p "${HWT_STATE_DIR}"
    touch "${HWT_INSTALLED_LIST}"

    for p in "${available[@]}"; do
        if dpkg -s "${p}" >/dev/null 2>&1; then
            info "已安装：${p}"
        else
            to_install+=("${p}")
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        ok "没有需要新增安装的依赖"
        return 0
    fi

    printf '%s
' "${to_install[@]}" | sed 's/^/  + /'
    echo
    read -r -p "确认安装以上依赖？[y/N]: " ans
    case "${ans}" in
        y|Y|yes|YES)
            if apt-get install -y "${to_install[@]}"; then
                printf '%s
' "${to_install[@]}" >> "${HWT_INSTALLED_LIST}"
                sort -u -o "${HWT_INSTALLED_LIST}" "${HWT_INSTALLED_LIST}"
                ok "依赖安装完成"
            else
                fail "依赖安装失败。请检查 apt 源和网络后重试。"
                return 1
            fi
            ;;
        *)
            warn "已取消安装"
            ;;
    esac
}


uninstall_test_deps() {
    title "检测依赖卸载"

    if [ "$(id -u)" -ne 0 ]; then
        fail "请用 root 或 sudo 执行 hwt 后再卸载依赖"
        return 1
    fi

    if [ ! -s "${HWT_INSTALLED_LIST}" ]; then
        warn "没有记录由 hwt 安装的依赖，不执行卸载"
        return 0
    fi

    echo "以下软件包记录为 hwt 安装："
    sed 's/^/  - /' "${HWT_INSTALLED_LIST}"
    echo
    warn "仅卸载 hwt 记录的新增包；系统原来已安装的包不会在记录中。"
    read -r -p "确认卸载？[y/N]: " ans
    case "${ans}" in
        y|Y|yes|YES)
            mapfile -t pkgs < "${HWT_INSTALLED_LIST}"
            apt-get purge -y "${pkgs[@]}" || true
            apt-get autoremove -y || true
            rm -f "${HWT_INSTALLED_LIST}"
            ok "依赖卸载完成"
            ;;
        *)
            warn "已取消卸载"
            ;;
    esac
}

perf_basic() {
    title "性能测试：基本检测 / CPU / VPN 加密 / 磁盘"

    echo "CPU："
    if has_cmd lscpu; then
        lscpu | sed 's/^/  /'
    fi

    echo
    echo "OpenSSL VPN 常用算法性能："
    if has_cmd openssl; then
        openssl speed -seconds 3 -evp aes-256-gcm 2>/dev/null || true
        echo
        openssl speed -seconds 3 -evp chacha20-poly1305 2>/dev/null || true
    else
        skip "openssl 未安装"
    fi

    echo
    echo "磁盘信息："
    if has_cmd lsblk; then
        lsblk -o NAME,MODEL,SIZE,TYPE,TRAN,FSTYPE,MOUNTPOINTS
    fi

    echo
    echo "网卡支持速率："
    for dev in /sys/class/net/*; do
        iface="$(basename "${dev}")"
        case "${iface}" in lo|docker*|br-*|veth*|virbr*) continue ;; esac
        echo
        echo "Interface: ${iface}"
        print_ethtool_summary "${iface}"
    done
}


perf_gpu() {
    title "性能测试：GPU"

    detect_gpu_vpu_npu_hdmi

    echo
    echo "GPU 简单测试建议："
    if has_cmd glmark2-es2-drm; then
        echo "检测到 glmark2-es2-drm，可手动运行："
        echo "  glmark2-es2-drm"
    else
        skip "glmark2-es2-drm 未安装或仓库不可用"
    fi

    if has_cmd kmscube; then
        echo "检测到 kmscube，可在本地显示环境手动运行："
        echo "  kmscube"
    else
        skip "kmscube 未安装"
    fi

    echo
    echo "GPU 判读提示："
    echo "  - HDMI 输出可用通常只需要 /dev/dri/card* + rockchipdrm。"
    echo "  - Mali-G610 3D 加速一般需要 panthor/panfrost/vendor mali 驱动 + /dev/dri/renderD* 或 /dev/mali0。"
    echo "  - 当前若只有 card0、没有 renderD，则表示显示可用，但 3D GPU 加速还不能算可用。"
}


perf_vpu() {
    title "性能测试：VPU / 视频编解码"

    if has_cmd v4l2-ctl; then
        v4l2-ctl --list-devices 2>/dev/null || true
        echo
        for dev in /dev/video*; do
            [ -e "${dev}" ] || continue
            echo
            echo "Formats for ${dev}:"
            v4l2-ctl -d "${dev}" --list-formats-ext 2>/dev/null | head -n 120 || true
        done
    else
        skip "v4l2-ctl 未安装"
    fi

    if has_cmd ffmpeg; then
        echo
        ffmpeg -hide_banner -hwaccels 2>/dev/null || true
    else
        skip "ffmpeg 未安装"
    fi
}

perf_npu() {
    title "性能测试：NPU"

    ls -l /dev/rknpu* 2>/dev/null || warn "未发现 /dev/rknpu*"
    lsmod | grep -Ei 'rknpu|npu' || true

    echo
    for bin in rknn_server rknn_benchmark rknn_toolkit_lite_test; do
        if has_cmd "${bin}"; then
            ok "发现：${bin}"
        else
            skip "未发现：${bin}"
        fi
    done

    echo
    info "NPU 实测需要 RKNN 用户态库和 .rknn 模型文件。当前脚本默认只做节点和工具检测。"
}

scenario_detect() {
    clear || true
    title "${HWT_NAME} - 场景能力检测"

    sub_title "内核配置来源"
    cfg="$(kconfig_file)"
    if [ -n "${cfg}" ]; then
        ok "可读取内核配置：${cfg}"
    else
        warn "未找到 /proc/config.gz 或 /boot/config-$(uname -r)，只能做部分检测"
    fi

    sub_title "LXC / Docker 基础能力"
    check_feature "Namespaces" CONFIG_NAMESPACES
    check_feature "UTS namespace" CONFIG_UTS_NS
    check_feature "IPC namespace" CONFIG_IPC_NS
    check_feature "PID namespace" CONFIG_PID_NS
    check_feature "NET namespace" CONFIG_NET_NS
    check_feature "USER namespace" CONFIG_USER_NS
    check_feature "Cgroups" CONFIG_CGROUPS
    check_feature "Memory cgroup" CONFIG_MEMCG
    check_feature "CPU cgroup" CONFIG_CGROUP_SCHED
    check_feature "Cpuset" CONFIG_CPUSETS
    check_feature "Seccomp" CONFIG_SECCOMP
    check_feature "OverlayFS" CONFIG_OVERLAY_FS
    check_feature "Veth" CONFIG_VETH
    check_feature "TUN" CONFIG_TUN
    check_feature "Bridge" CONFIG_BRIDGE
    check_feature "br_netfilter" CONFIG_BRIDGE_NETFILTER

    echo
    echo "运行时节点："
    [ -d /sys/fs/cgroup ] && ok "/sys/fs/cgroup 存在" || warn "/sys/fs/cgroup 不存在"
    [ -e /dev/net/tun ] && ok "/dev/net/tun 存在" || warn "/dev/net/tun 不存在"
    lsmod | grep -E 'overlay|bridge|br_netfilter|veth|tun|nf_conntrack' || true

    sub_title "路由 / OpenWrt LXC / PassWall / mihomo 场景"
    check_feature "nftables" CONFIG_NF_TABLES
    check_feature "conntrack" CONFIG_NF_CONNTRACK
    check_feature "tproxy target" CONFIG_NETFILTER_XT_TARGET_TPROXY
    check_feature "nft tproxy" CONFIG_NFT_TPROXY
    check_feature "ipset" CONFIG_IP_SET
    check_feature "policy routing" CONFIG_IP_MULTIPLE_TABLES
    check_feature "VLAN 8021Q" CONFIG_VLAN_8021Q
    check_feature "WireGuard" CONFIG_WIREGUARD
    check_feature "PPP" CONFIG_PPP
    check_feature "PPPoE" CONFIG_PPPOE

    echo
    if [ -r /proc/sys/net/ipv4/ip_forward ]; then
        echo "IPv4 forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
    fi

    sub_title "Docker / Podman / LXC 命令"
    for bin in docker podman lxc-start lxc-info lxc-checkconfig; do
        if has_cmd "${bin}"; then
            ok "已安装：${bin}"
        else
            skip "未安装：${bin}"
        fi
    done

    if has_cmd lxc-checkconfig; then
        echo
        lxc-checkconfig 2>/dev/null || true
    fi

    sub_title "redroid / Android 容器能力"
    local binder_cfg=0 binder_runtime=0 gpu_runtime=0
    if kconfig_enabled CONFIG_ANDROID_BINDER_IPC && kconfig_enabled CONFIG_ANDROID_BINDERFS; then
        binder_cfg=1
    fi
    check_feature "Android binder IPC" CONFIG_ANDROID_BINDER_IPC
    check_feature "Android binderfs" CONFIG_ANDROID_BINDERFS
    check_feature "DMA-BUF" CONFIG_DMA_SHARED_BUFFER
    check_feature "DMA heap" CONFIG_DMABUF_HEAPS
    check_feature "UHID" CONFIG_UHID
    check_feature "Input uinput" CONFIG_UINPUT

    echo
    echo "redroid 常用设备节点："
    for p in /dev/binderfs /dev/binder /dev/hwbinder /dev/vndbinder /dev/dri /dev/mali0 /dev/dma_heap /dev/uhid /dev/uinput /dev/input; do
        if [ -e "${p}" ]; then
            ok "${p} 存在"
        else
            warn "${p} 不存在"
        fi
    done

    if [ -e /dev/binderfs ] || [ -e /dev/binder ] || [ -e /dev/hwbinder ] || [ -e /dev/vndbinder ]; then
        binder_runtime=1
    fi
    if ls /dev/dri/renderD* >/dev/null 2>&1 || [ -e /dev/mali0 ]; then
        gpu_runtime=1
    fi

    echo
    echo "redroid 分层结论："
    [ "${binder_cfg}" -eq 1 ] && ok "binder/binderfs 内核配置具备" || warn "binder/binderfs 内核配置不完整"
    [ "${binder_runtime}" -eq 1 ] && ok "binder 运行时节点已存在" || warn "binder 运行时节点未创建/未挂载，容器启动前需处理 binderfs"
    [ "${gpu_runtime}" -eq 1 ] && ok "GPU 加速节点存在" || warn "未发现 /dev/dri/renderD* 或 /dev/mali0，redroid GPU 加速当前不可用"

    sub_title "KVM / QEMU"
    check_feature "KVM" CONFIG_KVM
    if [ -e /dev/kvm ]; then
        ok "/dev/kvm 存在"
    else
        warn "/dev/kvm 不存在"
    fi

    echo
    ok "场景能力检测完成"
}


performance_menu() {
    while true; do
        clear || true
        title "${HWT_NAME} - 性能测试"
        echo "1. 基本检测 / CPU / VPN 加密 / 网卡速率"
        echo "2. GPU 检测"
        echo "3. VPU 检测"
        echo "4. NPU 检测"
        echo "5. 检测依赖安装"
        echo "6. 检测依赖卸载"
        echo "0. 返回"
        echo
        read -r -p "请选择： " choice
        case "${choice}" in
            1) perf_basic; pause ;;
            2) perf_gpu; pause ;;
            3) perf_vpu; pause ;;
            4) perf_npu; pause ;;
            5) install_test_deps; pause ;;
            6) uninstall_test_deps; pause ;;
            0) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        clear || true
        echo -e "${C_BOLD}${C_BLUE}${HWT_NAME}${C_RESET} ${HWT_VERSION}"
        echo "适用：EasePi-R2 / RK3588 / Debian / Armbian"
        line
        echo "1. 设备检测"
        echo "2. 性能测试"
        echo "3. 场景能力检测"
        echo "4. 脚本卸载"
        echo "0. 退出"
        line
        read -r -p "请选择： " choice
        case "${choice}" in
            1) device_detect; pause ;;
            2) performance_menu ;;
            3) scenario_detect; pause ;;
            4) uninstall_self; pause; return 0 ;;
            0) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --version)
        echo "${HWT_VERSION}"
        ;;
    --install)
        install_self
        ;;
    --uninstall)
        uninstall_self
        ;;
    --device)
        device_detect
        ;;
    --scenario)
        scenario_detect
        ;;
    --perf-basic)
        perf_basic
        ;;
    --install-deps)
        install_test_deps
        ;;
    --uninstall-deps)
        uninstall_test_deps
        ;;
    *)
        main_menu
        ;;
esac
