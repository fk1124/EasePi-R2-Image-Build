#!/usr/bin/env bash
# ============================================================================
#  EasePi-R2 Debian / Ubuntu BSP image builder
#
#  Usage:
#    bash build-bsp-image.sh <debian|ubuntu> <release> [current|edge|vendor|linux7] [minimal|server|desktop]
#
#  Examples:
#    bash build-bsp-image.sh debian trixie current minimal
#    bash build-bsp-image.sh debian trixie linux7 minimal
#    bash build-bsp-image.sh debian bookworm vendor server
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
export REPO_DIR

DIST="${1:-${DIST:-debian}}"
RELEASE="${2:-${RELEASE:-trixie}}"
BRANCH="${3:-${BRANCH:-current}}"
IMAGE_TYPE="${4:-${IMAGE_TYPE:-minimal}}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-${BRANCH}}"
EASEPI_R2_KERNEL_PROFILE="${EASEPI_R2_KERNEL_PROFILE:-}"

BOARD="${BOARD:-easepi-r2}"
ARCH="${ARCH:-arm64}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-easepi-r2}"

# 安全默认值：不创建任何普通用户，也不写死任何公开默认密码。
# 默认情况下，如果没有创建普通用户，则构建时必须设置 root 密码，
# 这样刷机后仍然可以通过 root 登录进行初始化。
CREATE_USER="${CREATE_USER:-no}"
IMAGE_USER="${IMAGE_USER:-}"
IMAGE_PASSWORD="${IMAGE_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
LOCK_ROOT="${LOCK_ROOT:-no}"
EASEPI_R2_DESKTOP_PROFILE="${EASEPI_R2_DESKTOP_PROFILE:-}"
EASEPI_R2_DESKTOP_LOCALE="${EASEPI_R2_DESKTOP_LOCALE:-}"

if [ "$(id -u)" -eq 0 ]; then
    SUDO="${SUDO:-}"
else
    SUDO="${SUDO:-sudo}"
fi
export SUDO

if [ "${BRANCH}" = "linux7" ]; then
    ARMBIAN_BRANCH="edge"
    EASEPI_R2_KERNEL_PROFILE="linux7"
fi

export DIST RELEASE BRANCH ARMBIAN_BRANCH IMAGE_TYPE BOARD ARCH TARGET_HOSTNAME
export EASEPI_R2_KERNEL_PROFILE
export CREATE_USER IMAGE_USER IMAGE_PASSWORD ROOT_PASSWORD LOCK_ROOT
export EASEPI_R2_DESKTOP_PROFILE EASEPI_R2_DESKTOP_LOCALE

usage() {
    cat <<USAGE
Usage:
  bash build-bsp-image.sh <debian|ubuntu> <release> [current|edge|vendor|linux7] [minimal|server|desktop]

Debian releases:
  forky       Debian 14 preview
  trixie      Debian 13
  bookworm    Debian 12

Ubuntu releases:
  resolute    Ubuntu 26.04 LTS preview
  noble       Ubuntu 24.04 LTS
  jammy       Ubuntu 22.04 LTS

Examples:
  bash build-bsp-image.sh debian trixie current minimal
  bash build-bsp-image.sh debian trixie linux7 minimal
  bash build-bsp-image.sh debian bookworm vendor server
  bash build-bsp-image.sh debian forky linux7 desktop
  bash build-bsp-image.sh ubuntu noble current minimal

Optional environment variables:
  ARMBIAN_BUILD_DIR=/path/to/armbian/build
  TARGET_HOSTNAME=easepi-r2
  IMAGE_SIZE_MB=4096
  BOOT_SIZE_MB=256
  FORCE_BSP_REBUILD=yes
  EASEPI_R2_DESKTOP_PROFILE=xfce|kde
  EASEPI_R2_DESKTOP_LOCALE=zh_CN.UTF-8

Optional login configuration, disabled by default:
  CREATE_USER=no
      Default. Do not create any normal user.

  CREATE_USER=yes IMAGE_USER=fk IMAGE_PASSWORD='your_password'
      Explicitly create a normal sudo user.

  ROOT_PASSWORD='your_root_password'
      Set root password for first login.

  LOCK_ROOT=yes
      Advanced option. Build an image without a root password.
      Only use this when you have another way to enter the system.
USAGE
}

case "${DIST}" in
    debian)
        case "${RELEASE}" in forky|trixie|bookworm) ;; *) echo "ERROR: Debian only supports forky/trixie/bookworm in this kit."; usage; exit 1 ;; esac
        ;;
    ubuntu)
        case "${RELEASE}" in resolute|noble|jammy) ;; *) echo "ERROR: Ubuntu only supports resolute/noble/jammy in this kit."; usage; exit 1 ;; esac
        ;;
    -h|--help|help)
        usage; exit 0
        ;;
    *)
        echo "ERROR: unsupported DIST: ${DIST}"
        echo "This kit supports Debian and Ubuntu BSP images."
        usage
        exit 1
        ;;
esac

case "${BRANCH}" in current|edge|vendor|linux7) ;; *) echo "ERROR: unsupported BRANCH: ${BRANCH}"; usage; exit 1 ;; esac
case "${IMAGE_TYPE}" in minimal|server|desktop) ;; *) echo "ERROR: unsupported IMAGE_TYPE: ${IMAGE_TYPE}"; usage; exit 1 ;; esac
case "${CREATE_USER}" in yes|no) ;; *) echo "ERROR: CREATE_USER only supports yes/no."; usage; exit 1 ;; esac
case "${LOCK_ROOT}" in yes|no) ;; *) echo "ERROR: LOCK_ROOT only supports yes/no."; usage; exit 1 ;; esac
case "${EASEPI_R2_DESKTOP_PROFILE}" in ""|xfce|kde) ;; *) echo "ERROR: EASEPI_R2_DESKTOP_PROFILE only supports xfce/kde."; usage; exit 1 ;; esac

if [ -n "${ROOT_PASSWORD}" ] && [ "${LOCK_ROOT}" = "yes" ]; then
    echo "ERROR: ROOT_PASSWORD and LOCK_ROOT=yes cannot be used together."
    exit 1
fi

if [ -n "${EASEPI_R2_DESKTOP_PROFILE}" ] && [ "${IMAGE_TYPE}" != "desktop" ]; then
    echo "ERROR: EASEPI_R2_DESKTOP_PROFILE can only be used with IMAGE_TYPE=desktop."
    exit 1
fi

if [ "${CREATE_USER}" = "yes" ]; then
    if [ -z "${IMAGE_USER}" ] || [ -z "${IMAGE_PASSWORD}" ]; then
        echo "ERROR: CREATE_USER=yes requires IMAGE_USER and IMAGE_PASSWORD."
        echo "Example: CREATE_USER=yes IMAGE_USER=fk IMAGE_PASSWORD='your_password' bash build-bsp-image.sh debian trixie current minimal"
        exit 1
    fi
fi

if [ -n "${EASEPI_R2_DESKTOP_PROFILE}" ] && [ "${CREATE_USER}" != "yes" ]; then
    echo "ERROR: desktop presets require CREATE_USER=yes so the GUI can log into a normal sudo user."
    exit 1
fi

prompt_root_password() {
    if [ ! -t 0 ]; then
        echo "ERROR: ROOT_PASSWORD is required in non-interactive builds."
        echo "Example: ROOT_PASSWORD='your_root_password' bash build-bsp-image.sh ${DIST} ${RELEASE} ${BRANCH} ${IMAGE_TYPE}"
        exit 1
    fi

    echo
    echo "Please set a root password for first login. It will not be printed or saved in the repository."
    while true; do
        read -r -s -p "Root password: " ROOT_PASSWORD
        echo
        read -r -s -p "Confirm root password: " ROOT_PASSWORD_CONFIRM
        echo
        if [ -z "${ROOT_PASSWORD}" ]; then
            echo "ERROR: root password cannot be empty."
            continue
        fi
        if [ "${ROOT_PASSWORD}" != "${ROOT_PASSWORD_CONFIRM}" ]; then
            echo "ERROR: passwords do not match."
            continue
        fi
        break
    done
    unset ROOT_PASSWORD_CONFIRM
    export ROOT_PASSWORD
}

# 如果默认不创建普通用户，那么必须有一个可用的 root 登录方式。
# 优先使用 ROOT_PASSWORD；交互终端下会提示输入；非交互环境必须显式传入。
if [ "${CREATE_USER}" = "no" ] && [ -z "${ROOT_PASSWORD}" ] && [ "${LOCK_ROOT}" != "yes" ]; then
    echo
    echo "No normal user will be created."
    prompt_root_password
fi

if [ -n "${EASEPI_R2_DESKTOP_PROFILE}" ] && [ -z "${ROOT_PASSWORD}" ] && [ "${LOCK_ROOT}" != "yes" ]; then
    echo
    echo "Desktop presets keep tty boot but still require a root rescue password."
    prompt_root_password
fi

ROOTFS_NAME="${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}"
IMAGE_NAME="EasePi-R2-${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}"
BSP_NAME="${DIST}-${RELEASE}-${BRANCH}"
export ROOTFS_NAME IMAGE_NAME BSP_NAME

cd "${REPO_DIR}"

printf '\n============================================\n'
printf '  EasePi-R2 BSP Image Build\n'
printf '============================================\n'
printf '  DIST        = %s\n' "${DIST}"
printf '  RELEASE     = %s\n' "${RELEASE}"
printf '  BRANCH      = %s\n' "${BRANCH}"
printf '  ARMBIAN     = %s\n' "${ARMBIAN_BRANCH}"
printf '  KERNEL      = %s\n' "${EASEPI_R2_KERNEL_PROFILE:-default}"
printf '  IMAGE_TYPE  = %s\n' "${IMAGE_TYPE}"
printf '  BOARD       = %s\n' "${BOARD}"
printf '  HOSTNAME    = %s\n' "${TARGET_HOSTNAME}"
printf '  CREATE_USER = %s\n' "${CREATE_USER}"
if [ "${CREATE_USER}" = "yes" ]; then
    printf '  IMAGE_USER  = %s\n' "${IMAGE_USER}"
fi
printf '  ROOT_PASS   = %s\n' "$([ -n "${ROOT_PASSWORD}" ] && echo "set" || echo "not set")"
printf '  LOCK_ROOT   = %s\n' "${LOCK_ROOT}"
printf '  DESKTOP     = %s\n' "${EASEPI_R2_DESKTOP_PROFILE:-default}"
if [ -n "${EASEPI_R2_DESKTOP_LOCALE}" ]; then
    printf '  DESKTOP_LOCALE = %s\n' "${EASEPI_R2_DESKTOP_LOCALE}"
fi
printf '============================================\n\n'

bash scripts/00-env.sh
bash scripts/10-build-bsp.sh
bash scripts/20-make-rootfs.sh
bash scripts/30-install-bsp.sh
bash scripts/40-pack-image.sh

printf '\n============================================\n'
printf '  DONE\n'
printf '============================================\n'
printf 'Output:\n'
ls -lh "${REPO_DIR}/output/images" | sed 's/^/  /'

printf '\nLogin configuration:\n'
if [ "${CREATE_USER}" = "yes" ]; then
    printf '  normal user created: %s\n' "${IMAGE_USER}"
    printf '  password: use the IMAGE_PASSWORD you provided at build time\n'
else
    printf '  normal user: not created by default\n'
fi
if [ -n "${ROOT_PASSWORD}" ]; then
    printf '  root password: set during build\n'
elif [ "${LOCK_ROOT}" = "yes" ]; then
    printf '  root password: not set; root account is locked by LOCK_ROOT=yes\n'
else
    printf '  root password: not set\n'
fi
printf 'No fixed public default normal user or password is generated.\n'
