#!/usr/bin/env bash
# ============================================================================
#  EasePi-R2 portable rootfs image builder
#
#  Handles non-Armbian userlands that reuse the project Armbian-built BSP:
#  Alpine Linux, Fedora, Arch Linux ARM, and Kali ARM.
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
export REPO_DIR

DIST="${1:-${DIST:-alpine}}"
RELEASE="${2:-${RELEASE:-stable}}"
BRANCH="${3:-${BRANCH:-current}}"
IMAGE_TYPE="${4:-${IMAGE_TYPE:-minimal}}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-${BRANCH}}"
EASEPI_R2_KERNEL_PROFILE="${EASEPI_R2_KERNEL_PROFILE:-}"
ARMBIAN_BSP_RELEASE="${ARMBIAN_BSP_RELEASE:-trixie}"

BOARD="${BOARD:-easepi-r2}"
ARCH="${ARCH:-arm64}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-easepi-r2}"

CREATE_USER="${CREATE_USER:-no}"
IMAGE_USER="${IMAGE_USER:-}"
IMAGE_PASSWORD="${IMAGE_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
LOCK_ROOT="${LOCK_ROOT:-no}"

if [ "$(id -u)" -eq 0 ]; then
    SUDO="${SUDO:-}"
else
    SUDO="${SUDO:-sudo}"
fi
export SUDO

case "${BRANCH}" in
    6.18|6.18.*)
        BRANCH="current"
        ARMBIAN_BRANCH="current"
        ;;
esac

if [ "${BRANCH}" = "linux7" ]; then
    ARMBIAN_BRANCH="edge"
    EASEPI_R2_KERNEL_PROFILE="linux7"
fi

usage() {
    cat <<USAGE
Usage:
  bash build-rootfs-image.sh <alpine|fedora|archlinuxarm|kali> <release> current <minimal|server>

Public examples:
  bash build-image.sh alpine stable 6.18 minimal
  bash build-image.sh fedora latest 6.18 minimal
  bash build-image.sh archlinuxarm rolling 6.18 minimal
  bash build-image.sh kali rolling 6.18 minimal

Supported targets:
  alpine       stable   current/6.18   minimal, server
  fedora       latest   current/6.18   minimal, server
  archlinuxarm rolling  current/6.18   minimal, server
  kali         rolling  current/6.18   minimal, server

Optional login configuration:
  ROOT_PASSWORD='your_root_password'
  CREATE_USER=yes IMAGE_USER=fk IMAGE_PASSWORD='your_password'
  LOCK_ROOT=yes

Optional BSP configuration:
  ARMBIAN_BSP_RELEASE=trixie
      Armbian build release used only to compile BSP debs for non-Debian
      userlands. The generated image release remains the requested target.
USAGE
}

case "${DIST}" in
    -h|--help|help)
        usage
        exit 0
        ;;
    alpine)
        case "${RELEASE}" in stable) ;; *) echo "ERROR: Alpine supports release stable only."; usage; exit 1 ;; esac
        ;;
    fedora)
        case "${RELEASE}" in latest) ;; *) echo "ERROR: Fedora supports release latest only."; usage; exit 1 ;; esac
        ;;
    archlinuxarm)
        case "${RELEASE}" in rolling) ;; *) echo "ERROR: Arch Linux ARM supports release rolling only."; usage; exit 1 ;; esac
        ;;
    kali)
        case "${RELEASE}" in rolling) ;; *) echo "ERROR: Kali ARM supports release rolling only."; usage; exit 1 ;; esac
        ;;
    *)
        echo "ERROR: unsupported DIST: ${DIST}"
        usage
        exit 1
        ;;
esac

case "${BRANCH}" in current) ;; *) echo "ERROR: ${DIST} currently supports current/6.18 only."; usage; exit 1 ;; esac
case "${IMAGE_TYPE}" in minimal|server) ;; *) echo "ERROR: ${DIST} currently supports minimal/server only."; usage; exit 1 ;; esac
case "${CREATE_USER}" in yes|no) ;; *) echo "ERROR: CREATE_USER only supports yes/no."; usage; exit 1 ;; esac
case "${LOCK_ROOT}" in yes|no) ;; *) echo "ERROR: LOCK_ROOT only supports yes/no."; usage; exit 1 ;; esac

if [ -n "${ROOT_PASSWORD}" ] && [ "${LOCK_ROOT}" = "yes" ]; then
    echo "ERROR: ROOT_PASSWORD and LOCK_ROOT=yes cannot be used together."
    exit 1
fi

if [ "${CREATE_USER}" = "yes" ]; then
    if [ -z "${IMAGE_USER}" ] || [ -z "${IMAGE_PASSWORD}" ]; then
        echo "ERROR: CREATE_USER=yes requires IMAGE_USER and IMAGE_PASSWORD."
        exit 1
    fi
fi

prompt_root_password() {
    if [ ! -t 0 ]; then
        echo "ERROR: ROOT_PASSWORD is required in non-interactive builds."
        echo "Example: ROOT_PASSWORD='your_root_password' bash build-image.sh ${DIST} ${RELEASE} 6.18 ${IMAGE_TYPE}"
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

if [ "${CREATE_USER}" = "no" ] && [ -z "${ROOT_PASSWORD}" ] && [ "${LOCK_ROOT}" != "yes" ]; then
    echo
    echo "No normal user will be created."
    prompt_root_password
fi

ROOTFS_NAME="${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}"
IMAGE_NAME="EasePi-R2-${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}"
BSP_NAME="${DIST}-${RELEASE}-${BRANCH}"

export DIST RELEASE BRANCH ARMBIAN_BRANCH IMAGE_TYPE BOARD ARCH TARGET_HOSTNAME
export EASEPI_R2_KERNEL_PROFILE ARMBIAN_BSP_RELEASE
export CREATE_USER IMAGE_USER IMAGE_PASSWORD ROOT_PASSWORD LOCK_ROOT
export ROOTFS_NAME IMAGE_NAME BSP_NAME

cd "${REPO_DIR}"

printf '\n============================================\n'
printf '  EasePi-R2 Portable Rootfs Image Build\n'
printf '============================================\n'
printf '  DIST        = %s\n' "${DIST}"
printf '  RELEASE     = %s\n' "${RELEASE}"
printf '  BRANCH      = %s\n' "${BRANCH}"
printf '  BSP_RELEASE = %s\n' "${ARMBIAN_BSP_RELEASE}"
printf '  IMAGE_TYPE  = %s\n' "${IMAGE_TYPE}"
printf '  BOARD       = %s\n' "${BOARD}"
printf '  HOSTNAME    = %s\n' "${TARGET_HOSTNAME}"
printf '  CREATE_USER = %s\n' "${CREATE_USER}"
if [ "${CREATE_USER}" = "yes" ]; then
    printf '  IMAGE_USER  = %s\n' "${IMAGE_USER}"
fi
printf '  ROOT_PASS   = %s\n' "$([ -n "${ROOT_PASSWORD}" ] && echo "set" || echo "not set")"
printf '  LOCK_ROOT   = %s\n' "${LOCK_ROOT}"
printf '============================================\n\n'

if [ "${EASEPI_R2_DRY_RUN:-no}" = "yes" ]; then
    echo "Dry run requested; target validation passed and no build stages were executed."
    exit 0
fi

bash scripts/00-env.sh
bash scripts/10-build-bsp.sh

case "${DIST}" in
    alpine)
        bash scripts/20-make-alpine-rootfs.sh
        bash scripts/30-install-portable-bsp.sh
        ;;
    fedora)
        bash scripts/20-make-fedora-rootfs.sh
        bash scripts/30-install-portable-bsp.sh
        ;;
    archlinuxarm)
        bash scripts/20-make-archlinuxarm-rootfs.sh
        bash scripts/30-install-portable-bsp.sh
        ;;
    kali)
        bash scripts/20-make-rootfs.sh
        bash scripts/30-install-bsp.sh
        ;;
esac

bash scripts/40-pack-image.sh

printf '\n============================================\n'
printf '  DONE\n'
printf '============================================\n'
printf 'Output:\n'
ls -lh "${REPO_DIR}/output/images" | sed 's/^/  /'
