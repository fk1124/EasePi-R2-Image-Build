#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

usage() {
    cat <<USAGE
Usage:
  bash build-image.sh <system> <release> <kernel> <image_type>

Systems:
  armbian        Native Armbian image, routed to build.sh
  debian         Debian BSP packed image, routed to build-bsp-image.sh
  ubuntu         Ubuntu BSP packed image, routed to build-bsp-image.sh
  alpine         Alpine Linux BSP packed image, routed to build-rootfs-image.sh
  fedora         Fedora BSP packed image, routed to build-rootfs-image.sh
  archlinuxarm   Arch Linux ARM BSP packed image, routed to build-rootfs-image.sh
  kali           Kali ARM BSP packed image, routed to build-rootfs-image.sh

Kernel aliases:
  6.1 | vendor
  6.18 | current
  7.0

Image types:
  minimal | server | desktop
  Alpine/Fedora/Arch/Kali currently support minimal | server.

Examples:
  bash build-image.sh armbian bookworm 6.1 minimal
  bash build-image.sh armbian trixie 6.18 minimal
  bash build-image.sh debian trixie 6.18 minimal
  bash build-image.sh alpine stable 6.18 minimal
  bash build-image.sh fedora latest 6.18 minimal
  bash build-image.sh archlinuxarm rolling 6.18 minimal
  bash build-image.sh kali rolling 6.18 minimal
USAGE
}

fail_usage() {
    echo "ERROR: $*" >&2
    echo >&2
    usage >&2
    exit 1
}

not_ready() {
    echo "TODO: $*" >&2
    echo "This target is listed in the project matrix, but its build adapter is not implemented yet." >&2
    exit 2
}

normalize_kernel() {
    case "$1" in
        6.1|6.1.*|vendor)
            printf '%s\n' "vendor"
            ;;
        6.18|6.18.*|current)
            printf '%s\n' "current"
            ;;
        7.0|7.0.*|linux7)
            printf '%s\n' "linux7"
            ;;
        edge)
            printf '%s\n' "edge"
            ;;
        *)
            fail_usage "unsupported kernel profile: $1"
            ;;
    esac
}

assert_supported_target() {
    case "${SYSTEM}" in
        armbian)
            case "${RELEASE}:${KERNEL_PROFILE}" in
                bookworm:vendor|bookworm:current|trixie:current|trixie:linux7|forky:linux7|jammy:vendor|jammy:current|noble:current|noble:linux7|resolute:linux7)
                    return 0
                    ;;
            esac
            ;;
        debian)
            case "${RELEASE}:${KERNEL_PROFILE}" in
                bookworm:vendor|bookworm:current|trixie:current|trixie:linux7|forky:linux7)
                    return 0
                    ;;
            esac
            ;;
        ubuntu)
            case "${RELEASE}:${KERNEL_PROFILE}" in
                jammy:vendor|jammy:current|noble:current|noble:linux7|resolute:linux7)
                    return 0
                    ;;
            esac
            ;;
        alpine)
            case "${RELEASE}:${KERNEL_PROFILE}" in
                stable:current)
                    return 0
                    ;;
            esac
            ;;
        fedora)
            case "${RELEASE}:${KERNEL_PROFILE}" in
                latest:current)
                    return 0
                    ;;
            esac
            ;;
        archlinuxarm)
            case "${RELEASE}:${KERNEL_PROFILE}" in
                rolling:current)
                    return 0
                    ;;
            esac
            ;;
        kali)
            case "${RELEASE}:${KERNEL_PROFILE}" in
                rolling:current)
                    return 0
                    ;;
            esac
            ;;
    esac

    not_ready "${SYSTEM} ${RELEASE} ${KERNEL} ${IMAGE_TYPE}"
}

SYSTEM="${1:-}"
RELEASE="${2:-}"
KERNEL="${3:-}"
IMAGE_TYPE="${4:-}"

case "${SYSTEM}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

[ -n "${SYSTEM}" ] || fail_usage "missing system"
[ -n "${RELEASE}" ] || fail_usage "missing release"
[ -n "${KERNEL}" ] || fail_usage "missing kernel"
[ -n "${IMAGE_TYPE}" ] || fail_usage "missing image_type"

case "${IMAGE_TYPE}" in
    minimal|server|desktop) ;;
    *) fail_usage "unsupported image_type: ${IMAGE_TYPE}" ;;
esac

KERNEL_PROFILE="$(normalize_kernel "${KERNEL}")"
assert_supported_target

case "${SYSTEM}" in
    armbian)
        case "${RELEASE}" in
            bookworm|trixie|forky|jammy|noble|resolute) ;;
            *) not_ready "Armbian ${RELEASE} is not wired into build.sh yet." ;;
        esac
        exec bash "${REPO_DIR}/build.sh" "${KERNEL_PROFILE}" "${RELEASE}" "${IMAGE_TYPE}"
        ;;
    debian)
        case "${RELEASE}" in
            bookworm|trixie|forky) ;;
            *) not_ready "Debian BSP ${RELEASE} is not wired into build-bsp-image.sh yet." ;;
        esac
        exec bash "${REPO_DIR}/build-bsp-image.sh" debian "${RELEASE}" "${KERNEL_PROFILE}" "${IMAGE_TYPE}"
        ;;
    ubuntu)
        case "${RELEASE}" in
            jammy|noble|resolute) ;;
            *) not_ready "Ubuntu BSP ${RELEASE} is not wired into build-bsp-image.sh yet." ;;
        esac
        exec bash "${REPO_DIR}/build-bsp-image.sh" ubuntu "${RELEASE}" "${KERNEL_PROFILE}" "${IMAGE_TYPE}"
        ;;
    alpine)
        case "${RELEASE}" in
            stable) ;;
            *) not_ready "Alpine ${RELEASE} is not wired into build-rootfs-image.sh yet." ;;
        esac
        exec bash "${REPO_DIR}/build-rootfs-image.sh" alpine "${RELEASE}" "${KERNEL_PROFILE}" "${IMAGE_TYPE}"
        ;;
    fedora)
        case "${RELEASE}" in
            latest) ;;
            *) not_ready "Fedora ${RELEASE} is not wired into build-rootfs-image.sh yet." ;;
        esac
        exec bash "${REPO_DIR}/build-rootfs-image.sh" fedora "${RELEASE}" "${KERNEL_PROFILE}" "${IMAGE_TYPE}"
        ;;
    archlinuxarm)
        case "${RELEASE}" in
            rolling) ;;
            *) not_ready "Arch Linux ARM ${RELEASE} is not wired into build-rootfs-image.sh yet." ;;
        esac
        exec bash "${REPO_DIR}/build-rootfs-image.sh" archlinuxarm "${RELEASE}" "${KERNEL_PROFILE}" "${IMAGE_TYPE}"
        ;;
    kali)
        case "${RELEASE}" in
            rolling) ;;
            *) not_ready "Kali ARM ${RELEASE} is not wired into build-rootfs-image.sh yet." ;;
        esac
        exec bash "${REPO_DIR}/build-rootfs-image.sh" kali "${RELEASE}" "${KERNEL_PROFILE}" "${IMAGE_TYPE}"
        ;;
    *)
        not_ready "system ${SYSTEM}"
        ;;
esac
