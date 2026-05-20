#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -z "${SUDO:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
fi

DIST="${DIST:-alpine}"
RELEASE="${RELEASE:-stable}"
BRANCH="${BRANCH:-current}"
IMAGE_TYPE="${IMAGE_TYPE:-minimal}"
ROOTFS_NAME="${ROOTFS_NAME:-${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}}"
ROOTFS_DIR="${REPO_DIR}/output/rootfs/${ROOTFS_NAME}"

ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-latest-stable}"
ALPINE_ARCH="${ALPINE_ARCH:-aarch64}"
CACHE_DIR="${REPO_DIR}/work/cache/alpine"

printf '\n[2/4] Create Alpine Linux %s %s rootfs\n' "${ALPINE_BRANCH}" "${ALPINE_ARCH}"
printf 'Rootfs directory: %s\n' "${ROOTFS_DIR}"

case "${IMAGE_TYPE}" in
    minimal|server) ;;
    *) echo "ERROR: Alpine rootfs supports minimal/server only."; exit 1 ;;
esac

mkdir -p "${CACHE_DIR}"

release_yaml="${ALPINE_MIRROR%/}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/latest-releases.yaml"
release_yaml_cache="${CACHE_DIR}/latest-releases.yaml"
curl -fsSL "${release_yaml}" -o "${release_yaml_cache}"

minirootfs_file="$(awk '/file: alpine-minirootfs-.*-aarch64\.tar\.gz/ {print $2; exit}' "${release_yaml_cache}")"
if [ -z "${minirootfs_file}" ]; then
    echo "ERROR: cannot find Alpine minirootfs entry in ${release_yaml}"
    exit 1
fi

minirootfs_url="${ALPINE_MIRROR%/}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${minirootfs_file}"
minirootfs_path="${CACHE_DIR}/${minirootfs_file}"

if [ ! -f "${minirootfs_path}" ]; then
    curl -fL --retry 3 --connect-timeout 20 -o "${minirootfs_path}.tmp" "${minirootfs_url}"
    mv -f "${minirootfs_path}.tmp" "${minirootfs_path}"
fi

${SUDO} rm -rf "${ROOTFS_DIR}"
${SUDO} mkdir -p "${ROOTFS_DIR}"
${SUDO} tar -xpf "${minirootfs_path}" -C "${ROOTFS_DIR}"

${SUDO} mkdir -p "${ROOTFS_DIR}/etc/apk"
${SUDO} tee "${ROOTFS_DIR}/etc/apk/repositories" >/dev/null <<EOF_REPOS
${ALPINE_MIRROR%/}/${ALPINE_BRANCH}/main
${ALPINE_MIRROR%/}/${ALPINE_BRANCH}/community
EOF_REPOS

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
    read_packages "${REPO_DIR}/rootfs/alpine/packages-minimal.txt"
    if [ "${IMAGE_TYPE}" = "server" ]; then
        read_packages "${REPO_DIR}/rootfs/alpine/packages-server.txt"
    fi
)

mapfile -t OPTIONAL_PACKAGES < <(read_packages "${REPO_DIR}/rootfs/alpine/packages-optional.txt")

${SUDO} mount --bind /dev "${ROOTFS_DIR}/dev"
${SUDO} mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
${SUDO} mount -t proc proc "${ROOTFS_DIR}/proc"
${SUDO} mount -t sysfs sysfs "${ROOTFS_DIR}/sys"

${SUDO} chroot "${ROOTFS_DIR}" /bin/sh -e <<CHROOT
apk update
apk add --no-cache ${REQUIRED_PACKAGES[*]}
CHROOT

for pkg in "${OPTIONAL_PACKAGES[@]}"; do
    ${SUDO} chroot "${ROOTFS_DIR}" /bin/sh -c "apk add --no-cache '${pkg}'" || \
        printf 'WARN: optional Alpine package install failed: %s\n' "${pkg}"
done

${SUDO} chroot "${ROOTFS_DIR}" /bin/sh -e <<'CHROOT'
update-ca-certificates || true
rc-update add devfs sysinit 2>/dev/null || true
rc-update add dmesg sysinit 2>/dev/null || true
rc-update add mdev sysinit 2>/dev/null || true
rc-update add hwdrivers sysinit 2>/dev/null || true
rc-update add modules boot 2>/dev/null || true
rc-update add hostname boot 2>/dev/null || true
rc-update add sysctl boot 2>/dev/null || true
rc-update add bootmisc boot 2>/dev/null || true
rc-update add networking boot 2>/dev/null || true
rc-update add sshd default 2>/dev/null || true
rc-update add dnsmasq default 2>/dev/null || true
rc-update add nftables default 2>/dev/null || true
CHROOT

cleanup_mounts
trap - EXIT

printf 'Alpine rootfs created: %s\n' "${ROOTFS_DIR}"
