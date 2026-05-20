#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -z "${SUDO:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
fi

DIST="${DIST:-archlinuxarm}"
RELEASE="${RELEASE:-rolling}"
BRANCH="${BRANCH:-current}"
IMAGE_TYPE="${IMAGE_TYPE:-minimal}"
ROOTFS_NAME="${ROOTFS_NAME:-${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}}"
ROOTFS_DIR="${REPO_DIR}/output/rootfs/${ROOTFS_NAME}"

ARCHLINUXARM_TARBALL_URL="${ARCHLINUXARM_TARBALL_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
CACHE_DIR="${REPO_DIR}/work/cache/archlinuxarm"
TARBALL_PATH="${CACHE_DIR}/$(basename "${ARCHLINUXARM_TARBALL_URL}")"

printf '\n[2/4] Create Arch Linux ARM rolling aarch64 rootfs\n'
printf 'Rootfs directory: %s\n' "${ROOTFS_DIR}"

case "${IMAGE_TYPE}" in
    minimal|server) ;;
    *) echo "ERROR: Arch Linux ARM rootfs supports minimal/server only."; exit 1 ;;
esac

mkdir -p "${CACHE_DIR}"
if [ ! -f "${TARBALL_PATH}" ]; then
    curl -fL --retry 3 --connect-timeout 20 -o "${TARBALL_PATH}.tmp" "${ARCHLINUXARM_TARBALL_URL}"
    mv -f "${TARBALL_PATH}.tmp" "${TARBALL_PATH}"
fi

${SUDO} rm -rf "${ROOTFS_DIR}"
${SUDO} mkdir -p "${ROOTFS_DIR}"

if command -v bsdtar >/dev/null 2>&1; then
    ${SUDO} bsdtar -xpf "${TARBALL_PATH}" -C "${ROOTFS_DIR}"
else
    ${SUDO} tar -xpf "${TARBALL_PATH}" -C "${ROOTFS_DIR}"
fi

${SUDO} cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
${SUDO} mkdir -p "${ROOTFS_DIR}/usr/bin"
${SUDO} cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"

cleanup_mounts() {
    ${SUDO} umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
}
trap cleanup_mounts EXIT

read_packages() {
    grep -h -vE '^[[:space:]]*(#|$)' "$@" 2>/dev/null | awk '{print $1}'
}

mapfile -t REQUIRED_PACKAGES < <(
    read_packages "${REPO_DIR}/rootfs/archlinuxarm/packages-minimal.txt"
    if [ "${IMAGE_TYPE}" = "server" ]; then
        read_packages "${REPO_DIR}/rootfs/archlinuxarm/packages-server.txt"
    fi
)

mapfile -t OPTIONAL_PACKAGES < <(read_packages "${REPO_DIR}/rootfs/archlinuxarm/packages-optional.txt")

${SUDO} mount --bind /dev "${ROOTFS_DIR}/dev"
${SUDO} mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
${SUDO} mount -t proc proc "${ROOTFS_DIR}/proc"
${SUDO} mount -t sysfs sysfs "${ROOTFS_DIR}/sys"

${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -e <<'CHROOT'
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy --noconfirm archlinuxarm-keyring
CHROOT

${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -e <<CHROOT
pacman -Syu --noconfirm
pacman -S --needed --noconfirm ${REQUIRED_PACKAGES[*]}
CHROOT

for pkg in "${OPTIONAL_PACKAGES[@]}"; do
    ${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -c "pacman -S --needed --noconfirm '${pkg}'" || \
        printf 'WARN: optional Arch Linux ARM package install failed: %s\n' "${pkg}"
done

cleanup_mounts
trap - EXIT

printf 'Arch Linux ARM rootfs created: %s\n' "${ROOTFS_DIR}"
