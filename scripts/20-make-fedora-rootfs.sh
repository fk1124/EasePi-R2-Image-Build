#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -z "${SUDO:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
fi

DIST="${DIST:-fedora}"
RELEASE="${RELEASE:-latest}"
BRANCH="${BRANCH:-current}"
IMAGE_TYPE="${IMAGE_TYPE:-minimal}"
ROOTFS_NAME="${ROOTFS_NAME:-${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}}"
ROOTFS_DIR="${REPO_DIR}/output/rootfs/${ROOTFS_NAME}"

FEDORA_VERSION="${FEDORA_VERSION:-44}"
FEDORA_MIRROR="${FEDORA_MIRROR:-https://download.fedoraproject.org/pub/fedora/linux}"
FEDORA_ARCH="${FEDORA_ARCH:-aarch64}"

printf '\n[2/4] Create Fedora %s %s rootfs\n' "${FEDORA_VERSION}" "${FEDORA_ARCH}"
printf 'Rootfs directory: %s\n' "${ROOTFS_DIR}"

case "${IMAGE_TYPE}" in
    minimal|server) ;;
    *) echo "ERROR: Fedora rootfs supports minimal/server only."; exit 1 ;;
esac

DNF_CMD="${DNF_CMD:-}"
if [ -z "${DNF_CMD}" ]; then
    if command -v dnf5 >/dev/null 2>&1; then
        DNF_CMD="$(command -v dnf5)"
    elif command -v dnf >/dev/null 2>&1; then
        DNF_CMD="$(command -v dnf)"
    else
        echo "ERROR: dnf/dnf5 not found. Install it first: sudo apt install -y dnf"
        exit 1
    fi
fi

read_packages() {
    grep -h -vE '^[[:space:]]*(#|$)' "$@" 2>/dev/null | awk '{print $1}'
}

mapfile -t REQUIRED_PACKAGES < <(
    read_packages "${REPO_DIR}/rootfs/fedora/packages-minimal.txt"
    if [ "${IMAGE_TYPE}" = "server" ]; then
        read_packages "${REPO_DIR}/rootfs/fedora/packages-server.txt"
    fi
)

mapfile -t OPTIONAL_PACKAGES < <(read_packages "${REPO_DIR}/rootfs/fedora/packages-optional.txt")

fedora_base="${FEDORA_MIRROR%/}/releases/${FEDORA_VERSION}/Everything/${FEDORA_ARCH}/os/"
fedora_updates="${FEDORA_MIRROR%/}/updates/${FEDORA_VERSION}/Everything/${FEDORA_ARCH}/"

DNF_COMMON=(
    -y
    --installroot="${ROOTFS_DIR}"
    --releasever="${FEDORA_VERSION}"
    --forcearch="${FEDORA_ARCH}"
    --setopt=reposdir=/dev/null
    --setopt=install_weak_deps=False
    --setopt=tsflags=nodocs
    --repofrompath=fedora,"${fedora_base}"
    --repofrompath=updates,"${fedora_updates}"
    --disablerepo=*
    --enablerepo=fedora
    --enablerepo=updates
    --nogpgcheck
)

${SUDO} rm -rf "${ROOTFS_DIR}"
${SUDO} mkdir -p "${ROOTFS_DIR}"
${SUDO} mkdir -p "${ROOTFS_DIR}/usr/bin" "${ROOTFS_DIR}/etc"
${SUDO} cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"
${SUDO} cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

${SUDO} "${DNF_CMD}" "${DNF_COMMON[@]}" install "${REQUIRED_PACKAGES[@]}"

for pkg in "${OPTIONAL_PACKAGES[@]}"; do
    ${SUDO} "${DNF_CMD}" "${DNF_COMMON[@]}" install "${pkg}" || \
        printf 'WARN: optional Fedora package install failed: %s\n' "${pkg}"
done

${SUDO} "${DNF_CMD}" "${DNF_COMMON[@]}" clean all || true

printf 'Fedora rootfs created: %s\n' "${ROOTFS_DIR}"
