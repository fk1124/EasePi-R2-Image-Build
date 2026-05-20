#!/usr/bin/env bash
# ============================================================================
#  EasePi-R2 Alpine Linux image command adapter
#
#  This file intentionally reserves the public command shape before the Alpine
#  rootfs/BSP installer is implemented.
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
export REPO_DIR

RELEASE="${1:-${RELEASE:-stable}}"
BRANCH="${2:-${BRANCH:-current}}"
IMAGE_TYPE="${3:-${IMAGE_TYPE:-minimal}}"

usage() {
    cat <<USAGE
Usage:
  bash build-alpine-image.sh stable current <minimal|server>

Preferred public entry:
  bash build-image.sh alpine stable 6.18 minimal
  bash build-image.sh alpine stable 6.18 server

Current Alpine command contract:
  release: stable
  kernel : 6.18 / current
  type   : minimal, server

Status:
  The command contract is reserved. The Alpine rootfs adapter is not
  implemented yet, so this script exits before modifying output files.
USAGE
}

case "${RELEASE}" in
    -h|--help|help)
        usage
        exit 0
        ;;
    stable) ;;
    *)
        echo "ERROR: Alpine adapter currently reserves release 'stable' only." >&2
        usage >&2
        exit 1
        ;;
esac

case "${BRANCH}" in
    current) ;;
    *)
        echo "ERROR: Alpine adapter currently reserves kernel profile 'current' / 6.18 only." >&2
        usage >&2
        exit 1
        ;;
esac

case "${IMAGE_TYPE}" in
    minimal|server) ;;
    desktop)
        echo "ERROR: Alpine desktop image is not part of the first command contract." >&2
        echo "Use minimal or server." >&2
        exit 1
        ;;
    *)
        echo "ERROR: unsupported Alpine IMAGE_TYPE: ${IMAGE_TYPE}" >&2
        usage >&2
        exit 1
        ;;
esac

cat >&2 <<TODO
TODO: Alpine image build adapter is not implemented yet.

Reserved command:
  bash build-image.sh alpine ${RELEASE} 6.18 ${IMAGE_TYPE}

Planned implementation boundary:
  1. scripts/10-build-bsp.sh
     Reuse the Armbian BSP/kernel package build for EasePi-R2.
  2. scripts/20-make-alpine-rootfs.sh
     Bootstrap an Alpine arm64 rootfs with apk static tooling.
  3. scripts/30-install-alpine-bsp.sh
     Install kernel modules, firmware, boot files, and OpenRC network services.
  4. scripts/40-pack-image.sh
     Reuse the existing GPT/FAT32 boot/ext4 rootfs image packer.

Important design note:
  Alpine uses OpenRC by default. The current Debian/Ubuntu BSP overlay depends
  on systemd-networkd, so Alpine needs its own network/service policy instead
  of reusing the systemd overlay directly.
TODO

exit 2
