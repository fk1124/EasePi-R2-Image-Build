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
  ubuntu         Reserved for Ubuntu BSP packed images

Kernel aliases:
  6.1 | vendor
  6.18 | current
  7.0

Image types:
  minimal | server | desktop

Examples:
  bash build-image.sh armbian bookworm 6.1 minimal
  bash build-image.sh armbian trixie 6.18 minimal
  bash build-image.sh debian trixie 6.18 minimal
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
    echo "This target is reserved in the project matrix, but its build adapter is not implemented yet." >&2
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
    case "${SYSTEM}:${RELEASE}:${KERNEL_PROFILE}" in
        armbian:bookworm:vendor|armbian:bookworm:current|armbian:trixie:current|armbian:trixie:linux7|armbian:forky:linux7|debian:bookworm:vendor|debian:bookworm:current|debian:trixie:current|debian:trixie:linux7|debian:forky:linux7)
            return 0
            ;;
        ubuntu:*)
            not_ready "Ubuntu BSP images are reserved for jammy/noble/resolute."
            ;;
        *)
            not_ready "${SYSTEM} ${RELEASE} ${KERNEL} ${IMAGE_TYPE}"
            ;;
    esac
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
            bookworm|trixie|forky) ;;
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
        not_ready "Ubuntu BSP images are reserved for jammy/noble/resolute."
        ;;
    *)
        not_ready "system ${SYSTEM}"
        ;;
esac
