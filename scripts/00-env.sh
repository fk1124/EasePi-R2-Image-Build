#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export REPO_DIR

mkdir -p "${REPO_DIR}/work" "${REPO_DIR}/output/bsp" "${REPO_DIR}/output/rootfs" "${REPO_DIR}/output/images" "${REPO_DIR}/output/tmp"

need_cmds=(
  git curl wget rsync tar xzcat xz
  debootstrap qemu-aarch64-static update-binfmts
  parted losetup mkfs.vfat mkfs.ext4 blkid findmnt
  chroot dpkg-deb dd sed awk grep
  mkimage
)

missing=()
for c in "${need_cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
        missing+=("$c")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing required commands: ${missing[*]}"
    echo
    echo "Install dependencies on Debian host:"
    cat <<'APT'
sudo apt update
sudo apt install -y git curl wget rsync unzip xz-utils ca-certificates
sudo apt install -y build-essential gcc g++ make bc bison flex
sudo apt install -y libssl-dev libncurses-dev python3 python3-pip python3-setuptools
sudo apt install -y file cpio qemu-user-static binfmt-support debootstrap
sudo apt install -y parted dosfstools e2fsprogs util-linux u-boot-tools
APT
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi
export SUDO

if [ ! -d "${REPO_DIR}/userpatches" ]; then
    echo "ERROR: userpatches/ not found in repository root: ${REPO_DIR}"
    exit 1
fi

if [ ! -f "${REPO_DIR}/userpatches/config/boards/easepi-r2.conf" ]; then
    echo "ERROR: userpatches/config/boards/easepi-r2.conf not found."
    exit 1
fi

printf 'Environment check passed.\n'
