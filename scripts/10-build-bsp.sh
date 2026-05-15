#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUDO="${SUDO:-sudo}"

BOARD="${BOARD:-easepi-r2}"
BRANCH="${BRANCH:-current}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-${BRANCH}}"
RELEASE="${RELEASE:-trixie}"
IMAGE_TYPE="${IMAGE_TYPE:-minimal}"
FORCE_BSP_REBUILD="${FORCE_BSP_REBUILD:-no}"
EASEPI_R2_KERNEL_PROFILE="${EASEPI_R2_KERNEL_PROFILE:-}"

if [ "${BRANCH}" = "linux7" ]; then
    ARMBIAN_BRANCH="edge"
    EASEPI_R2_KERNEL_PROFILE="linux7"
fi
export EASEPI_R2_KERNEL_PROFILE

# ============================================================
# 镜像源 / 构建策略
# ============================================================
#
# 默认策略：
# - REGIONAL_MIRROR 默认留空，不再默认 china，避免 Armbian 区域缓存源慢。
# - MAINLINE_MIRROR=auto：自动选择 Linux 内核 Git 源。
# - UBOOT_MIRROR=auto：自动选择 U-Boot Git 源。
# - GITHUB_SOURCE=auto：自动选择 GitHub Release 下载源。
# - GITHUB_MIRROR 默认留空，避免 gitclone 下载 GitHub Release 返回 500。
# - KERNEL_GIT=shallow：下载量小，适合普通用户首次编译。
#
# 可手动覆盖：
# REGIONAL_MIRROR=china bash build-bsp-image.sh debian trixie current minimal
# MAINLINE_MIRROR=google bash build-bsp-image.sh debian trixie current minimal
# MAINLINE_MIRROR=tuna bash build-bsp-image.sh debian trixie current minimal
# MAINLINE_MIRROR=bfsu bash build-bsp-image.sh debian trixie current minimal
# UBOOT_MIRROR=github bash build-bsp-image.sh debian trixie current minimal
# KERNEL_GIT=full bash build-bsp-image.sh debian trixie current minimal

REGIONAL_MIRROR="${REGIONAL_MIRROR-}"
MAINLINE_MIRROR="${MAINLINE_MIRROR:-auto}"
UBOOT_MIRROR="${UBOOT_MIRROR:-auto}"
GITHUB_SOURCE="${GITHUB_SOURCE:-auto}"
GITHUB_MIRROR="${GITHUB_MIRROR-}"
KERNEL_GIT="${KERNEL_GIT:-shallow}"
CPUTHREADS="${CPUTHREADS:-$(nproc)}"

ORAS_PREFETCH="${ORAS_PREFETCH:-yes}"
ORAS_VERSION="${ORAS_VERSION:-1.3.1}"

ARMBIAN_BUILD_REPO="${ARMBIAN_BUILD_REPO:-https://github.com/armbian/build.git}"

BSP_DIR="${REPO_DIR}/output/bsp/${BRANCH}"
mkdir -p "${BSP_DIR}"

msg() {
    printf '%s\n' "$*"
}

append_csv_value() {
    local csv="${1-}"
    local value="$2"

    case ",${csv}," in
        *,"${value}",*)
            printf '%s\n' "${csv}"
            return 0
            ;;
    esac

    if [ -z "${csv}" ]; then
        printf '%s\n' "${value}"
    else
        printf '%s,%s\n' "${csv}" "${value}"
    fi
}

remove_matching_files() {
    local pattern file removed=0

    shopt -s nullglob
    for pattern in "$@"; do
        for file in ${pattern}; do
            rm -f "${file}"
            msg "Removed stale artifact: ${file}"
            removed=1
        done
    done
    shopt -u nullglob

    return "${removed}"
}

prepare_vendor_clean_build() {
    [ "${BRANCH}" = "vendor" ] || return 0
    [ "${EASEPI_R2_VENDOR_CLEAN_BUILD:-yes}" = "yes" ] || {
        msg "Vendor clean rebuild disabled by EASEPI_R2_VENDOR_CLEAN_BUILD=${EASEPI_R2_VENDOR_CLEAN_BUILD:-no}"
        return 0
    }

    msg
    msg "Vendor branch: forcing clean kernel/u-boot/BSP rebuild to avoid stale local deb reuse."

    CLEAN_LEVEL="$(append_csv_value "${CLEAN_LEVEL-}" "make-kernel")"
    CLEAN_LEVEL="$(append_csv_value "${CLEAN_LEVEL}" "make-uboot")"

    remove_matching_files \
        "${BUILD_DIR}/output/debs/linux-image-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-dtb-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-headers-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-libc-dev-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-u-boot-${BOARD}-vendor_"*.deb \
        "${BUILD_DIR}/output/debs/armbian-bsp-cli-${BOARD}-vendor_"*.deb \
        "${BUILD_DIR}/output/packages-hashed/kernel-rk35xx-vendor_"*.tar \
        "${BUILD_DIR}/output/packages-hashed/linux-u-boot-${BOARD}-vendor_"*.deb \
        "${BUILD_DIR}/output/packages-hashed/armbian-bsp-cli-${BOARD}-vendor_"*.tar || true
}

install_pv_cat_wrapper() {
    local wrapper_dir
    wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/easepi-r2-pv.XXXXXX")"
    cat > "${wrapper_dir}/pv" <<'PV_WRAPPER'
#!/usr/bin/env bash
set -e

files=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --)
            shift
            while [ "$#" -gt 0 ]; do
                files+=("$1")
                shift
            done
            ;;
        -N|--name|-s|--size|-i|--interval|-w|--width|-H|--height|-L|--rate-limit|-B|--buffer-size|-A|--last-written|-F|--format|-o|--output)
            shift
            [ "$#" -gt 0 ] && shift || true
            ;;
        --*=*)
            shift
            ;;
        -*)
            shift
            ;;
        *)
            files+=("$1")
            shift
            ;;
    esac
done

if [ "${#files[@]}" -gt 0 ]; then
    exec cat -- "${files[@]}"
fi
exec cat
PV_WRAPPER
    chmod +x "${wrapper_dir}/pv"
    printf '%s\n' "${wrapper_dir}"
}

probe_git() {
    local name="$1"
    local url="$2"
    local ref="${3:-HEAD}"
    local timeout_sec="${4:-15}"

    printf 'Probe git %-20s : %s ... ' "${name}" "${url}"

    if timeout "${timeout_sec}" git ls-remote --exit-code "${url}" "${ref}" >/dev/null 2>&1; then
        printf 'OK\n'
        return 0
    fi

    printf 'FAIL\n'
    return 1
}

probe_url() {
    local name="$1"
    local url="$2"
    local timeout_sec="${3:-15}"

    printf 'Probe url %-20s : %s ... ' "${name}" "${url}"

    if timeout "${timeout_sec}" curl -fsIL --connect-timeout 8 --max-time "${timeout_sec}" "${url}" >/dev/null 2>&1; then
        printf 'OK\n'
        return 0
    fi

    printf 'FAIL\n'
    return 1
}

locate_build_dir() {
    if [ -n "${ARMBIAN_BUILD_DIR:-}" ] && [ -f "${ARMBIAN_BUILD_DIR}/compile.sh" ]; then
        printf '%s\n' "${ARMBIAN_BUILD_DIR}"
    elif [ -d "${REPO_DIR}/../build" ] && [ -f "${REPO_DIR}/../build/compile.sh" ]; then
        printf '%s\n' "$(cd "${REPO_DIR}/../build" && pwd)"
    elif [ -d "${HOME}/rk3588_build/build" ] && [ -f "${HOME}/rk3588_build/build/compile.sh" ]; then
        printf '%s\n' "${HOME}/rk3588_build/build"
    elif [ -d "${REPO_DIR}/work/armbian-build" ] && [ -f "${REPO_DIR}/work/armbian-build/compile.sh" ]; then
        printf '%s\n' "${REPO_DIR}/work/armbian-build"
    else
        printf ''
    fi
}

choose_mainline_mirror() {
    if [ "${MAINLINE_MIRROR}" != "auto" ]; then
        return 0
    fi

    msg
    msg "Auto selecting mainline kernel mirror..."

    if probe_git "linux Google" "https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux-stable.git" "HEAD" 15; then
        MAINLINE_MIRROR="google"
        return 0
    fi

    if probe_git "linux TUNA" "https://mirrors.tuna.tsinghua.edu.cn/git/linux-stable.git" "HEAD" 15; then
        MAINLINE_MIRROR="tuna"
        return 0
    fi

    if probe_git "linux BFSU" "https://mirrors.bfsu.edu.cn/git/linux-stable.git" "HEAD" 15; then
        MAINLINE_MIRROR="bfsu"
        return 0
    fi

    msg "WARN: Google/TUNA/BFSU unavailable, using Armbian default mainline source."
    MAINLINE_MIRROR=""
}

choose_uboot_mirror() {
    if [ "${UBOOT_MIRROR}" != "auto" ]; then
        return 0
    fi

    msg
    msg "Auto selecting U-Boot mirror..."

    if probe_git "u-boot GitHub" "https://github.com/u-boot/u-boot.git" "HEAD" 15; then
        UBOOT_MIRROR="github"
        return 0
    fi

    if probe_git "u-boot Gitee" "https://gitee.com/mirrors/u-boot.git" "HEAD" 15; then
        UBOOT_MIRROR="gitee"
        return 0
    fi

    msg "WARN: both GitHub and Gitee U-Boot probes failed, fallback to github."
    UBOOT_MIRROR="github"
}

choose_github_source() {
    if [ "${GITHUB_SOURCE}" != "auto" ]; then
        return 0
    fi

    local oras_file="oras_${ORAS_VERSION}_linux_amd64.tar.gz"
    local direct_url="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${oras_file}"
    local ghfast_url="https://ghfast.top/https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${oras_file}"

    msg
    msg "Auto selecting GitHub release source..."

    if probe_url "GitHub direct" "${direct_url}" 15; then
        GITHUB_SOURCE="https://github.com"
        return 0
    fi

    if probe_url "GitHub ghfast" "${ghfast_url}" 15; then
        GITHUB_SOURCE="https://ghfast.top/https://github.com"
        return 0
    fi

    msg "WARN: GitHub release probe failed, fallback to https://github.com."
    GITHUB_SOURCE="https://github.com"
}

prefetch_oras_tooling() {
    if [ "${ORAS_PREFETCH}" != "yes" ]; then
        msg "ORAS prefetch disabled."
        return 0
    fi

    local uname_s uname_m oras_os oras_arch oras_version oras_dir oras_fn oras_bin oras_url tmp_dir

    uname_s="$(uname -s)"
    uname_m="$(uname -m)"
    oras_version="${ORAS_VERSION}"

    case "${uname_s}" in
        Linux|linux)
            oras_os="linux"
            ;;
        Darwin|darwin)
            oras_os="darwin"
            ;;
        *)
            msg "WARN: unsupported host OS for ORAS prefetch: ${uname_s}"
            return 0
            ;;
    esac

    case "${uname_m}" in
        x86_64|amd64)
            oras_arch="amd64"
            ;;
        aarch64|arm64)
            oras_arch="arm64"
            ;;
        riscv64)
            oras_arch="riscv64"
            oras_version="1.2.0-beta.1"
            ;;
        *)
            msg "WARN: unsupported host arch for ORAS prefetch: ${uname_m}"
            return 0
            ;;
    esac

    oras_dir="${BUILD_DIR}/cache/tools/oras"
    oras_fn="oras_${oras_version}_${oras_os}_${oras_arch}"
    oras_bin="${oras_dir}/${oras_fn}"
    oras_url="${GITHUB_SOURCE%/}/oras-project/oras/releases/download/v${oras_version}/${oras_fn}.tar.gz"

    mkdir -p "${oras_dir}"

    if [ -x "${oras_bin}" ]; then
        msg "Using cached ORAS tooling: ${oras_bin}"
        return 0
    fi

    msg
    msg "Prefetch ORAS tooling:"
    msg "  URL : ${oras_url}"
    msg "  SAVE: ${oras_bin}"

    tmp_dir="$(mktemp -d)"

    if ! curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 \
        -o "${tmp_dir}/oras.tar.gz" \
        "${oras_url}"; then
        rm -rf "${tmp_dir}"
        msg "ERROR: failed to download ORAS tooling."
        msg "You can test manually:"
        msg "  curl -I ${oras_url}"
        exit 1
    fi

    tar -xf "${tmp_dir}/oras.tar.gz" -C "${tmp_dir}" oras
    mv "${tmp_dir}/oras" "${oras_bin}"
    chmod +x "${oras_bin}"

    "${oras_bin}" version || true

    rm -rf "${tmp_dir}"
}

clean_broken_cache() {
    # 只清理明显残缺的浅层 tar 下载残留。
    # 不主动删除 u-boot bare cache，避免误删 Armbian 已经编译成功的 U-Boot 缓存。
    if [ -d "cache" ]; then
        find cache -type f -name 'linux-shallow-*.git.tar*' -size -10M -delete 2>/dev/null || true
        find cache -type f -name 'linux-complete.git.tar*' -size -10M -delete 2>/dev/null || true
    fi

    # 如果确实怀疑 U-Boot 缓存坏了，请手动清：
    # rm -rf cache/git-bare/u-boot
    # rm -rf cache/sources/u-boot-worktree
    # rm -rf cache/memoize/git2info/*
}

trust_existing_git_caches() {
    if ! command -v git >/dev/null 2>&1; then
        return 0
    fi

    local build_dir_safe
    build_dir_safe="$(readlink -f "${BUILD_DIR}" 2>/dev/null || printf '%s' "${BUILD_DIR}")"

    git config --global --add safe.directory "${BUILD_DIR}" 2>/dev/null || true
    git config --global --add safe.directory "${build_dir_safe}" 2>/dev/null || true

    local repo
    if [ -d "${build_dir_safe}/cache/git-bare" ]; then
        while IFS= read -r -d '' repo; do
            git config --global --add safe.directory "${repo}" 2>/dev/null || true
        done < <(find "${build_dir_safe}/cache/git-bare" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    if [ -d "${build_dir_safe}/cache/sources" ]; then
        while IFS= read -r -d '' repo; do
            git config --global --add safe.directory "${repo}" 2>/dev/null || true
        done < <(
            find "${build_dir_safe}/cache/sources" -mindepth 1 -maxdepth 5 \
                \( -type d -name .git -printf '%h\0' -o -type f -name .git -printf '%h\0' \) \
                2>/dev/null
        )
    fi
}

calc_bsp_input_hash() {
    (
        cd "${REPO_DIR}"
        find userpatches -type f -print0 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
            sha256sum "$f"
        done
    ) | sha256sum | awk '{print $1}'
}

set_kernel_config_not_set() {
    local file="$1"
    local name="$2"

    sed -i -E "/^${name}=|^# ${name} is not set/d" "${file}"
    printf '# %s is not set\n' "${name}" >> "${file}"
}

set_kernel_config_value() {
    local file="$1"
    local name="$2"
    local value="$3"

    sed -i -E "/^${name}=|^# ${name} is not set/d" "${file}"
    printf '%s=%s\n' "${name}" "${value}" >> "${file}"
}

prepare_kernel_configs() {
    mkdir -p "${REPO_DIR}/userpatches"

    local cfg src dst found refresh
    local configs=(
        "linux-rockchip64-current.config"
        "linux-rockchip64-edge.config"
        "linux-rk35xx-vendor.config"
    )

    refresh="${EASEPI_R2_REFRESH_KERNEL_CONFIGS:-no}"

    for cfg in "${configs[@]}"; do
        src="${BUILD_DIR}/config/kernel/${cfg}"
        dst="${REPO_DIR}/userpatches/${cfg}"
        found=""

        if [ -f "${src}" ]; then
            found="${src}"
        else
            found="$(find "${BUILD_DIR}/config" -type f -name "${cfg}" 2>/dev/null | head -1 || true)"
        fi

        if [ -n "${found}" ] && [ -f "${found}" ] && { [ ! -f "${dst}" ] || [ "${refresh}" = "yes" ]; }; then
            cp -f "${found}" "${dst}"
        elif [ -f "${dst}" ]; then
            msg "Reuse existing kernel config: ${dst}"
        else
            msg "WARN: default kernel config not found and user config missing: ${cfg}"
            continue
        fi

        # 关闭 WERROR，避免 warning 被当成 error 导致编译中断。
        sed -i \
            -e 's/^CONFIG_WERROR=y/# CONFIG_WERROR is not set/' \
            -e 's/^CONFIG_WERROR=.*/# CONFIG_WERROR is not set/' \
            "${dst}"

        grep -q '^# CONFIG_WERROR is not set' "${dst}" || \
            echo '# CONFIG_WERROR is not set' >> "${dst}"

        # 禁用 panel-simple-dsi。
        # 这是 MIPI DSI 小屏驱动，不是 HDMI。EasePi-R2 常规 HDMI 输出不依赖它。
        sed -i \
            -e 's/^CONFIG_DRM_PANEL_SIMPLE_DSI=y/# CONFIG_DRM_PANEL_SIMPLE_DSI is not set/' \
            -e 's/^CONFIG_DRM_PANEL_SIMPLE_DSI=m/# CONFIG_DRM_PANEL_SIMPLE_DSI is not set/' \
            -e 's/^CONFIG_DRM_PANEL_SIMPLE_DSI=.*/# CONFIG_DRM_PANEL_SIMPLE_DSI is not set/' \
            "${dst}"

        grep -q '^# CONFIG_DRM_PANEL_SIMPLE_DSI is not set' "${dst}" || \
            echo '# CONFIG_DRM_PANEL_SIMPLE_DSI is not set' >> "${dst}"

        if [ "${cfg}" = "linux-rk35xx-vendor.config" ]; then
            set_kernel_config_value "${dst}" "CONFIG_R8125" "m"
            set_kernel_config_value "${dst}" "CONFIG_RTL8852BS" "m"
            set_kernel_config_value "${dst}" "CONFIG_DRM_PANFROST" "m"
            set_kernel_config_value "${dst}" "CONFIG_DRM_PANTHOR" "m"
            set_kernel_config_value "${dst}" "CONFIG_AP6XXX" "m"
            set_kernel_config_value "${dst}" "CONFIG_BCMDHD_PCIE" "y"
            set_kernel_config_value "${dst}" "CONFIG_BCMDHD_FW_PATH" '"/lib/firmware/ap6275p/fw_bcmdhd.bin"'
            set_kernel_config_value "${dst}" "CONFIG_BCMDHD_NVRAM_PATH" '"/lib/firmware/ap6275p/nvram.txt"'
            set_kernel_config_value "${dst}" "CONFIG_BRCMFMAC" "m"
            set_kernel_config_value "${dst}" "CONFIG_BRCMFMAC_SDIO" "y"
            set_kernel_config_value "${dst}" "CONFIG_BT_HCIUART_BCM" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_DEVFREQ" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_MIDGARD" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_EXPERT" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_PLATFORM_THIRDPARTY" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_PLATFORM_THIRDPARTY_NAME" '"rk"'
            set_kernel_config_value "${dst}" "CONFIG_MALI_BIFROST" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_PLATFORM_NAME" '"rk"'
            set_kernel_config_value "${dst}" "CONFIG_MALI_CSF_SUPPORT" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_BIFROST_EXPERT" "y"
        else
            set_kernel_config_not_set "${dst}" "CONFIG_RTL8852BS"
        fi

        msg "Prepared kernel config: ${dst}"
    done
}

BUILD_DIR="$(locate_build_dir)"

if [ -z "${BUILD_DIR}" ]; then
    msg "Armbian build tree not found; cloning to work/armbian-build ..."
    mkdir -p "${REPO_DIR}/work"
    git clone --depth=1 "${ARMBIAN_BUILD_REPO}" "${REPO_DIR}/work/armbian-build"
    BUILD_DIR="${REPO_DIR}/work/armbian-build"
fi

if [ ! -f "${BUILD_DIR}/compile.sh" ]; then
    msg "ERROR: invalid Armbian build directory: ${BUILD_DIR}"
    exit 1
fi

prepare_kernel_configs
BSP_INPUT_HASH="$(calc_bsp_input_hash)"
BSP_STAMP="${BSP_DIR}/.bsp-input-hash"

if [ "${FORCE_BSP_REBUILD}" != "yes" ] && \
   ls "${BSP_DIR}"/linux-image-*.deb >/dev/null 2>&1 && \
   ls "${BSP_DIR}"/linux-dtb-*.deb >/dev/null 2>&1 && \
   ls "${BSP_DIR}"/*u-boot*.deb >/dev/null 2>&1 && \
   [ -f "${BSP_STAMP}" ] && \
   [ "$(cat "${BSP_STAMP}")" = "${BSP_INPUT_HASH}" ]; then
    msg "Using cached BSP debs: ${BSP_DIR}"
    exit 0
fi

if [ "${FORCE_BSP_REBUILD}" != "yes" ] && \
   ls "${BSP_DIR}"/linux-image-*.deb >/dev/null 2>&1 && \
   ls "${BSP_DIR}"/linux-dtb-*.deb >/dev/null 2>&1 && \
   ls "${BSP_DIR}"/*u-boot*.deb >/dev/null 2>&1; then
    msg "BSP cache exists but input hash changed or stamp is missing; rebuilding BSP."
fi

choose_mainline_mirror
choose_uboot_mirror
choose_github_source
prepare_vendor_clean_build

printf '\n[1/4] Build EasePi-R2 BSP with Armbian build framework\n'
printf 'Build directory : %s\n' "${BUILD_DIR}"
printf 'Board           : %s\n' "${BOARD}"
printf 'Branch          : %s\n' "${BRANCH}"
printf 'Armbian branch  : %s\n' "${ARMBIAN_BRANCH}"
printf 'Kernel profile  : %s\n' "${EASEPI_R2_KERNEL_PROFILE:-default}"
printf 'Release         : %s\n' "${RELEASE}"
printf 'Kernel git      : %s\n' "${KERNEL_GIT}"
printf 'Regional mirror : %s\n' "${REGIONAL_MIRROR:-none}"
printf 'Mainline mirror : %s\n' "${MAINLINE_MIRROR:-default}"
printf 'U-Boot mirror   : %s\n' "${UBOOT_MIRROR}"
printf 'GitHub mirror   : %s\n' "${GITHUB_MIRROR:-direct}"
printf 'GitHub source   : %s\n' "${GITHUB_SOURCE}"
printf 'Threads         : %s\n' "${CPUTHREADS}"
printf 'Clean level     : %s\n' "${CLEAN_LEVEL:-default}"

rsync -a --delete "${REPO_DIR}/userpatches/" "${BUILD_DIR}/userpatches/"

cd "${BUILD_DIR}"

export PESTER_TERMINAL=no
export WT_SESSION=1
export ALLOW_ROOT=yes
export GIT_TERMINAL_PROMPT=0
export SKIP_ORAS=yes

git config --global core.askPass '' 2>/dev/null || true
git config --global credential.helper '' 2>/dev/null || true

trust_existing_git_caches
prefetch_oras_tooling
clean_broken_cache

TMP_BSP_DIR="${BSP_DIR}.new.$$"
rm -rf "${TMP_BSP_DIR}"
mkdir -p "${TMP_BSP_DIR}"

COMPILE_ARGS=(
    "BOARD=${BOARD}"
    "BRANCH=${ARMBIAN_BRANCH}"
    "RELEASE=${RELEASE}"
    "BUILD_ONLY=u-boot,kernel,armbian-bsp"
    "BUILD_DESKTOP=no"
    "BUILD_MINIMAL=yes"
    "KERNEL_CONFIGURE=no"
    "KERNEL_GIT=${KERNEL_GIT}"
    "SKIP_ORAS=yes"
    "USE_CCACHE=yes"
    "CPUTHREADS=${CPUTHREADS}"
    "UBOOT_MIRROR=${UBOOT_MIRROR}"
    "GITHUB_SOURCE=${GITHUB_SOURCE}"
    "GITHUB_MIRROR=${GITHUB_MIRROR}"
    "ORAS_VERSION=${ORAS_VERSION}"
)

if [ -n "${EASEPI_R2_KERNEL_PROFILE}" ]; then
    COMPILE_ARGS+=("EASEPI_R2_KERNEL_PROFILE=${EASEPI_R2_KERNEL_PROFILE}")
fi

if [ "${EASEPI_R2_KERNEL_PROFILE}" = "linux7" ]; then
    COMPILE_ARGS+=(
        "KERNEL_MAJOR_MINOR=7.0"
        "KERNELBRANCH=branch:linux-7.0.y"
        "KERNELPATCHDIR=archive/rockchip64-7.0"
    )
fi

if [ -n "${REGIONAL_MIRROR}" ]; then
    COMPILE_ARGS+=("REGIONAL_MIRROR=${REGIONAL_MIRROR}")
fi

if [ -n "${MAINLINE_MIRROR}" ]; then
    COMPILE_ARGS+=("MAINLINE_MIRROR=${MAINLINE_MIRROR}")
fi

if [ -n "${CLEAN_LEVEL:-}" ]; then
    COMPILE_ARGS+=("CLEAN_LEVEL=${CLEAN_LEVEL}")
fi

PV_WRAPPER_DIR=""
if [ "${EASEPI_R2_DISABLE_ARMBIAN_PV:-yes}" = "yes" ]; then
    PV_WRAPPER_DIR="$(install_pv_cat_wrapper)"
    trap 'rm -rf "${PV_WRAPPER_DIR}"' EXIT
    msg "Using cat-based pv wrapper to avoid rootfs extraction stalls."
fi

set +e
# Keep the Armbian build non-interactive without feeding an infinite stream into
# every child process. Some extraction/logging pipelines inherit stdin; piping
# `yes` into the whole build can make them wait on the wrong input forever.
PATH="${PV_WRAPPER_DIR:+${PV_WRAPPER_DIR}:}${PATH}" ./compile.sh "${COMPILE_ARGS[@]}" </dev/null
BUILD_EXIT="$?"
set -e

if [ "${BUILD_EXIT}" -ne 0 ]; then
    msg "ERROR: Armbian BSP build failed with exit code ${BUILD_EXIT}."
    msg
    msg "Recent logs:"
    ls -lt output/logs/*.log 2>/dev/null | head -5 || true
    msg
    msg "当前选择结果："
    msg "  KERNEL_GIT=${KERNEL_GIT}"
    msg "  REGIONAL_MIRROR=${REGIONAL_MIRROR:-none}"
    msg "  MAINLINE_MIRROR=${MAINLINE_MIRROR:-default}"
    msg "  UBOOT_MIRROR=${UBOOT_MIRROR}"
    msg "  GITHUB_SOURCE=${GITHUB_SOURCE}"
    msg "  GITHUB_MIRROR=${GITHUB_MIRROR:-direct}"
    msg
    msg "可手动切换内核源："
    msg "  MAINLINE_MIRROR=google bash build-bsp-image.sh debian trixie current minimal"
    msg "  MAINLINE_MIRROR=tuna   bash build-bsp-image.sh debian trixie current minimal"
    msg "  MAINLINE_MIRROR=bfsu   bash build-bsp-image.sh debian trixie current minimal"
    msg
    msg "可手动启用区域镜像："
    msg "  REGIONAL_MIRROR=china bash build-bsp-image.sh debian trixie current minimal"
    rm -rf "${TMP_BSP_DIR}"
    exit "${BUILD_EXIT}"
fi

shopt -s nullglob
cp output/debs/*.deb "${TMP_BSP_DIR}/" || true
shopt -u nullglob

if ! ls "${TMP_BSP_DIR}"/linux-image-*.deb >/dev/null 2>&1; then
    msg "ERROR: linux-image deb not found in ${TMP_BSP_DIR}."
    rm -rf "${TMP_BSP_DIR}"
    exit 1
fi

if ! ls "${TMP_BSP_DIR}"/linux-dtb-*.deb >/dev/null 2>&1; then
    msg "ERROR: linux-dtb deb not found in ${TMP_BSP_DIR}."
    rm -rf "${TMP_BSP_DIR}"
    exit 1
fi

if ! ls "${TMP_BSP_DIR}"/*u-boot*.deb >/dev/null 2>&1; then
    msg "ERROR: u-boot deb not found in ${TMP_BSP_DIR}."
    rm -rf "${TMP_BSP_DIR}"
    exit 1
fi

rm -rf "${BSP_DIR:?}"/*
cp -a "${TMP_BSP_DIR}/." "${BSP_DIR}/"
rm -rf "${TMP_BSP_DIR}"
printf '%s\n' "${BSP_INPUT_HASH}" > "${BSP_STAMP}"

printf '\nBSP debs saved to: %s\n' "${BSP_DIR}"
ls -lh "${BSP_DIR}" | sed 's/^/  /'
