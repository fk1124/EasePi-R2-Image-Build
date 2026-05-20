#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -z "${SUDO:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
fi

DIST="${DIST:-alpine}"
RELEASE="${RELEASE:-stable}"
BRANCH="${BRANCH:-current}"
BOARD="${BOARD:-easepi-r2}"
ARCH="${ARCH:-arm64}"
IMAGE_TYPE="${IMAGE_TYPE:-minimal}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/work}"
ROOTFS_NAME="${ROOTFS_NAME:-${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}}"
ROOTFS_DIR="${REPO_DIR}/output/rootfs/${ROOTFS_NAME}"
BSP_NAME="${BSP_NAME:-${DIST}-${RELEASE}-${BRANCH}}"
BSP_DIR="${REPO_DIR}/output/bsp/${BSP_NAME}"
TMP_DIR="${REPO_DIR}/output/tmp/portable-bsp-${ROOTFS_NAME}"
PERIPHERAL_OVERLAY_DIR="${WORK_DIR}/userpatches.generated/overlay/easepi-r2-peripherals"

CREATE_USER="${CREATE_USER:-no}"
IMAGE_USER="${IMAGE_USER:-}"
IMAGE_PASSWORD="${IMAGE_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
LOCK_ROOT="${LOCK_ROOT:-no}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-easepi-r2}"

printf '\n[3/4] Install EasePi-R2 portable BSP into %s rootfs\n' "${DIST}"

if [ ! -d "${ROOTFS_DIR}" ]; then
    echo "ERROR: rootfs not found: ${ROOTFS_DIR}"
    exit 1
fi

if [ ! -d "${BSP_DIR}" ]; then
    echo "ERROR: BSP directory not found: ${BSP_DIR}"
    exit 1
fi

if ! command -v mkimage >/dev/null 2>&1; then
    echo "ERROR: mkimage not found on build host."
    echo "Please install u-boot-tools first: sudo apt-get install -y u-boot-tools"
    exit 1
fi

branch_kernel_flavor() {
    case "${BRANCH}" in
        vendor) printf '%s\n' "vendor-rk35xx" ;;
        current) printf '%s\n' "current-rockchip64" ;;
        edge|linux7) printf '%s\n' "edge-rockchip64" ;;
        *)
            echo "ERROR: unsupported BRANCH inside portable BSP install: ${BRANCH}"
            exit 1
            ;;
    esac
}

cleanup_mounts() {
    ${SUDO} umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
}

mount_chroot() {
    ${SUDO} mount --bind /dev "${ROOTFS_DIR}/dev"
    ${SUDO} mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    ${SUDO} mount -t proc proc "${ROOTFS_DIR}/proc"
    ${SUDO} mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
}

copy_qemu() {
    ${SUDO} mkdir -p "${ROOTFS_DIR}/usr/bin"
    if [ -x /usr/bin/qemu-aarch64-static ]; then
        ${SUDO} cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"
    fi
}

extract_bsp_debs() {
    local kernel_flavor kernel_deb dtb_deb

    kernel_flavor="$(branch_kernel_flavor)"
    kernel_deb="$(find "${BSP_DIR}" -maxdepth 1 -type f -name "linux-image-${kernel_flavor}_*.deb" | sort -V | tail -1 || true)"
    dtb_deb="$(find "${BSP_DIR}" -maxdepth 1 -type f -name "linux-dtb-${kernel_flavor}_*.deb" | sort -V | tail -1 || true)"

    if [ -z "${kernel_deb}" ] || [ -z "${dtb_deb}" ]; then
        echo "ERROR: missing required BSP packages for ${kernel_flavor}"
        [ -n "${kernel_deb}" ] || echo "  missing: linux-image-${kernel_flavor}_*.deb"
        [ -n "${dtb_deb}" ] || echo "  missing: linux-dtb-${kernel_flavor}_*.deb"
        find "${BSP_DIR}" -maxdepth 1 -type f -printf '  %f\n' | sort
        exit 1
    fi

    ${SUDO} rm -rf "${TMP_DIR}"
    mkdir -p "${TMP_DIR}/extract"
    dpkg-deb -x "${kernel_deb}" "${TMP_DIR}/extract"
    dpkg-deb -x "${dtb_deb}" "${TMP_DIR}/extract"

    ${SUDO} rsync -a "${TMP_DIR}/extract/" "${ROOTFS_DIR}/"
}

kernel_version_from_modules() {
    local version
    version="$(find "${ROOTFS_DIR}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1 || true)"
    if [ -z "${version}" ]; then
        echo "ERROR: cannot find /lib/modules/<kernel-version> after BSP extraction."
        exit 1
    fi
    printf '%s\n' "${version}"
}

stage_boot_files() {
    local kernel_version="$1"
    local kernel_src dtb_src latest_initrd

    ${SUDO} mkdir -p "${ROOTFS_DIR}/boot/dtb/rockchip"

    kernel_src="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -type f \( -name "vmlinuz-${kernel_version}" -o -name "Image-${kernel_version}" -o -name 'vmlinuz-*' -o -name 'Image-*' -o -name 'Image' \) | sort -V | tail -1 || true)"
    if [ -z "${kernel_src}" ]; then
        echo "ERROR: cannot find kernel image under ${ROOTFS_DIR}/boot"
        exit 1
    fi

    if [ "${kernel_src}" != "${ROOTFS_DIR}/boot/Image" ]; then
        ${SUDO} rm -f "${ROOTFS_DIR}/boot/Image"
        ${SUDO} cp -f "${kernel_src}" "${ROOTFS_DIR}/boot/Image"
    fi
    ${SUDO} ln -sfn "$(basename "${kernel_src}")" "${ROOTFS_DIR}/boot/vmlinuz"

    dtb_src="$(find "${ROOTFS_DIR}/boot" "${ROOTFS_DIR}/usr/lib" -type f -name 'rk3588-easepi-r2.dtb' 2>/dev/null | head -1 || true)"
    if [ -z "${dtb_src}" ]; then
        echo "ERROR: cannot find rk3588-easepi-r2.dtb after BSP extraction."
        exit 1
    fi
    ${SUDO} cp -f "${dtb_src}" "${ROOTFS_DIR}/boot/dtb/rockchip/rk3588-easepi-r2.dtb"

    ${SUDO} depmod -b "${ROOTFS_DIR}" "${kernel_version}" || true

    latest_initrd="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -type f -name "initrd.img-${kernel_version}" | head -1 || true)"
    [ -z "${latest_initrd}" ] || ${SUDO} rm -f "${latest_initrd}"
}

generate_initramfs() {
    local kernel_version="$1"
    local initrd="/boot/initrd.img-${kernel_version}"

    copy_qemu
    trap cleanup_mounts EXIT
    mount_chroot

    case "${DIST}" in
        alpine)
            ${SUDO} mkdir -p "${ROOTFS_DIR}/etc/mkinitfs"
            if [ ! -f "${ROOTFS_DIR}/etc/mkinitfs/mkinitfs.conf" ]; then
                ${SUDO} tee "${ROOTFS_DIR}/etc/mkinitfs/mkinitfs.conf" >/dev/null <<'EOF_MKINITFS'
features="ata base ide scsi usb virtio ext4 vfat nvme mmc raid crypto lvm"
EOF_MKINITFS
            fi
            ${SUDO} chroot "${ROOTFS_DIR}" /bin/sh -e <<CHROOT
mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / -o "${initrd}" "${kernel_version}"
CHROOT
            ;;
        fedora)
            ${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -e <<CHROOT
dracut --force --no-hostonly "${initrd}" "${kernel_version}"
CHROOT
            ;;
        archlinuxarm)
            ${SUDO} tee "${ROOTFS_DIR}/etc/mkinitcpio-easepi-r2.conf" >/dev/null <<'EOF_MKINITCPIO'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev modconf block filesystems keyboard fsck)
EOF_MKINITCPIO
            ${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -e <<CHROOT
mkinitcpio -c /etc/mkinitcpio-easepi-r2.conf -k "${kernel_version}" -g "${initrd}"
CHROOT
            ;;
        *)
            echo "ERROR: portable initramfs does not support DIST=${DIST}"
            exit 1
            ;;
    esac

    cleanup_mounts
    trap - EXIT

    if [ ! -f "${ROOTFS_DIR}${initrd}" ]; then
        echo "ERROR: initramfs was not generated: ${ROOTFS_DIR}${initrd}"
        exit 1
    fi

    ${SUDO} rm -f "${ROOTFS_DIR}/boot/initrd.img" "${ROOTFS_DIR}/boot/uInitrd"
    ${SUDO} ln -sfn "initrd.img-${kernel_version}" "${ROOTFS_DIR}/boot/initrd.img"
    ${SUDO} mkimage -A arm64 -O linux -T ramdisk -C none -n uInitrd \
        -d "${ROOTFS_DIR}${initrd}" \
        "${ROOTFS_DIR}/boot/uInitrd" >/dev/null
}

copy_boot_script() {
    local boot_cmd_src=""

    if [ -n "${ARMBIAN_BUILD_DIR:-}" ] && [ -f "${ARMBIAN_BUILD_DIR}/config/bootscripts/boot-rk35xx.cmd" ]; then
        boot_cmd_src="${ARMBIAN_BUILD_DIR}/config/bootscripts/boot-rk35xx.cmd"
    elif [ -f "${REPO_DIR}/../build/config/bootscripts/boot-rk35xx.cmd" ]; then
        boot_cmd_src="${REPO_DIR}/../build/config/bootscripts/boot-rk35xx.cmd"
    elif [ -f "${HOME}/rk3588_build/build/config/bootscripts/boot-rk35xx.cmd" ]; then
        boot_cmd_src="${HOME}/rk3588_build/build/config/bootscripts/boot-rk35xx.cmd"
    elif [ -f "${REPO_DIR}/work/armbian-build/config/bootscripts/boot-rk35xx.cmd" ]; then
        boot_cmd_src="${REPO_DIR}/work/armbian-build/config/bootscripts/boot-rk35xx.cmd"
    fi

    if [ -n "${boot_cmd_src}" ]; then
        ${SUDO} cp "${boot_cmd_src}" "${ROOTFS_DIR}/boot/boot.cmd"
        ${SUDO} mkimage -C none -A arm -T script \
            -d "${ROOTFS_DIR}/boot/boot.cmd" \
            "${ROOTFS_DIR}/boot/boot.scr" >/dev/null
    else
        echo "WARN: Armbian boot-rk35xx.cmd not found. Falling back to extlinux.conf."
        ${SUDO} mkdir -p "${ROOTFS_DIR}/boot/extlinux"
        ${SUDO} tee "${ROOTFS_DIR}/boot/extlinux/extlinux.conf" >/dev/null <<EOF_EXTLINUX
default linux
menu title EasePi-R2 Boot Menu
timeout 30

label linux
    menu label ${DIST} for EasePi-R2
    linux /Image
    initrd /uInitrd
    fdt /dtb/rockchip/rk3588-easepi-r2.dtb
    append root=UUID=ROOT_UUID rootfstype=ext4 rootwait rw console=tty1 console=ttyFIQ0,1500000n8 net.ifnames=1
EOF_EXTLINUX
    fi
}

write_boot_environment() {
    local extraargs="net.ifnames=1"
    local vendor_lines=""

    if [ "${BRANCH}" = "vendor" ]; then
        extraargs="cma=256M net.ifnames=1"
        vendor_lines="$(cat <<'EOF_VENDOR_BOOTENV'
overlay_prefix=rockchip-rk3588
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
EOF_VENDOR_BOOTENV
)"
    fi

    ${SUDO} tee "${ROOTFS_DIR}/boot/armbianEnv.txt" >/dev/null <<EOF_ENV
verbosity=1
bootlogo=false
console=both
${vendor_lines}
fdtfile=rockchip/rk3588-easepi-r2.dtb
rootdev=UUID=ROOT_UUID
rootfstype=ext4
extraargs=${extraargs}
EOF_ENV

    copy_boot_script
}

write_identity() {
    ${SUDO} tee "${ROOTFS_DIR}/etc/hostname" >/dev/null <<EOF_HOST
${TARGET_HOSTNAME}
EOF_HOST

    ${SUDO} tee "${ROOTFS_DIR}/etc/hosts" >/dev/null <<EOF_HOSTS
127.0.0.1 localhost
127.0.1.1 ${TARGET_HOSTNAME}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF_HOSTS
}

configure_alpine_accounts() {
    trap cleanup_mounts EXIT
    mount_chroot

    ${SUDO} chroot "${ROOTFS_DIR}" /bin/sh -e <<CHROOT
if [ "${CREATE_USER}" = "yes" ]; then
  addgroup wheel 2>/dev/null || true
  if ! id -u "${IMAGE_USER}" >/dev/null 2>&1; then
    adduser -D -s /bin/ash "${IMAGE_USER}"
  fi
  addgroup "${IMAGE_USER}" wheel 2>/dev/null || true
  printf '%s:%s\n' "${IMAGE_USER}" "${IMAGE_PASSWORD}" | chpasswd
  mkdir -p /etc/sudoers.d
  echo '%wheel ALL=(ALL) ALL' >/etc/sudoers.d/wheel
  chmod 0440 /etc/sudoers.d/wheel
else
  cat >/etc/easepi-r2-no-default-login.txt <<'EOF_NO_LOGIN'
This image was built without a default normal user.
No public default account or password is configured.
EOF_NO_LOGIN
fi

if [ "${LOCK_ROOT}" = "yes" ]; then
  passwd -l root || true
elif [ -n "${ROOT_PASSWORD}" ]; then
  printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
else
  passwd -l root || true
fi
CHROOT

    cleanup_mounts
    trap - EXIT
}

configure_systemd_accounts() {
    trap cleanup_mounts EXIT
    mount_chroot

    ${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -e <<CHROOT
if [ "${CREATE_USER}" = "yes" ]; then
  getent group wheel >/dev/null 2>&1 || groupadd wheel
  if ! id -u "${IMAGE_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G wheel,adm,video,audio,input,render "${IMAGE_USER}" 2>/dev/null || \
      useradd -m -s /bin/bash -G wheel "${IMAGE_USER}"
  fi
  printf '%s:%s\n' "${IMAGE_USER}" "${IMAGE_PASSWORD}" | chpasswd
  mkdir -p /etc/sudoers.d
  echo '%wheel ALL=(ALL) ALL' >/etc/sudoers.d/wheel
  chmod 0440 /etc/sudoers.d/wheel
else
  cat >/etc/easepi-r2-no-default-login.txt <<'EOF_NO_LOGIN'
This image was built without a default normal user.
No public default account or password is configured.
EOF_NO_LOGIN
fi

if [ "${LOCK_ROOT}" = "yes" ]; then
  passwd -l root || true
elif [ -n "${ROOT_PASSWORD}" ]; then
  printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
else
  passwd -l root || true
fi
CHROOT

    cleanup_mounts
    trap - EXIT
}

prepare_systemd_overlay() {
    bash "${REPO_DIR}/scripts/sync-root-scripts.sh"

    rm -rf "${PERIPHERAL_OVERLAY_DIR}"
    mkdir -p "${PERIPHERAL_OVERLAY_DIR}"
    rsync -a "${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals/" "${PERIPHERAL_OVERLAY_DIR}/"

    ${SUDO} rsync -a "${PERIPHERAL_OVERLAY_DIR}/" "${ROOTFS_DIR}/"
    ${SUDO} rm -f "${ROOTFS_DIR}"/etc/systemd/network/10-easepi-r2-eth{0,1,2,3}.link
    ${SUDO} rm -f "${ROOTFS_DIR}/etc/modprobe.d/99-easepi-r2-panthor-manual-only.conf"
    ${SUDO} rm -f "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-gpu-check"
    ${SUDO} chmod +x "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-eth-order" 2>/dev/null || true
    ${SUDO} chmod +x "${ROOTFS_DIR}/usr/local/sbin/bluetooth-hciattach.sh" 2>/dev/null || true
}

configure_systemd_services() {
    trap cleanup_mounts EXIT
    mount_chroot

    ${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -e <<'CHROOT'
systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true
systemctl enable easepi-r2-eth-order.service 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true
systemctl enable dnsmasq 2>/dev/null || true
systemctl enable nftables 2>/dev/null || true
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
systemctl enable bluetooth-hciattach.service 2>/dev/null || true
systemctl enable ir-keymap.service 2>/dev/null || true
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
rm -f /etc/machine-id
: >/etc/machine-id
CHROOT

    cleanup_mounts
    trap - EXIT
}

configure_alpine_overlay() {
    bash "${REPO_DIR}/scripts/sync-root-scripts.sh" "${ROOTFS_DIR}/root"

    ${SUDO} mkdir -p "${ROOTFS_DIR}/etc/dnsmasq.d" "${ROOTFS_DIR}/etc/easepi-r2-router"
    ${SUDO} cp -f "${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals/etc/nftables.conf" "${ROOTFS_DIR}/etc/nftables.conf"
    ${SUDO} ln -sfn nftables.conf "${ROOTFS_DIR}/etc/nftables.nft"
    ${SUDO} cp -f "${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals/etc/dnsmasq.d/0-router.conf" "${ROOTFS_DIR}/etc/dnsmasq.d/0-router.conf"
    ${SUDO} cp -f "${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals/etc/easepi-r2-router/router.env" "${ROOTFS_DIR}/etc/easepi-r2-router/router.env"

    ${SUDO} mkdir -p "${ROOTFS_DIR}/etc/network" "${ROOTFS_DIR}/etc/conf.d"
    ${SUDO} tee "${ROOTFS_DIR}/etc/conf.d/hostname" >/dev/null <<EOF_HOSTNAME
hostname="${TARGET_HOSTNAME}"
EOF_HOSTNAME

    ${SUDO} tee "${ROOTFS_DIR}/etc/network/interfaces" >/dev/null <<'EOF_INTERFACES'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto br-lan
iface br-lan inet static
    address 192.168.2.1
    netmask 255.255.255.0
    bridge_ports eth1 eth2 eth3
    bridge_stp off
    bridge_fd 0
EOF_INTERFACES

    ${SUDO} tee "${ROOTFS_DIR}/etc/modules" >/dev/null <<'EOF_MODULES'
panthor
EOF_MODULES

    trap cleanup_mounts EXIT
    mount_chroot
    ${SUDO} chroot "${ROOTFS_DIR}" /bin/sh -e <<'CHROOT'
rc-update add networking boot 2>/dev/null || true
rc-update add sshd default 2>/dev/null || true
rc-update add dnsmasq default 2>/dev/null || true
rc-update add nftables default 2>/dev/null || true
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
CHROOT
    cleanup_mounts
    trap - EXIT
}

write_armbian_release_fallback() {
    ${SUDO} tee "${ROOTFS_DIR}/etc/armbian-release" >/dev/null <<EOF_ARMBIAN_RELEASE
# Generated by EasePi-R2 portable BSP image builder.
BOARD=${BOARD}
BOARD_NAME="EasePi R2"
BOARDFAMILY=rockchip-rk3588
BRANCH=${BRANCH}
DISTRIBUTION=${DIST}
DISTRIB_CODENAME=${RELEASE}
ARCH=${ARCH}
IMAGE_TYPE=${IMAGE_TYPE}
EOF_ARMBIAN_RELEASE
}

final_sanity_check() {
    local f

    for f in \
        armbianEnv.txt \
        Image \
        uInitrd \
        dtb/rockchip/rk3588-easepi-r2.dtb
    do
        if [ ! -e "${ROOTFS_DIR}/boot/${f}" ]; then
            echo "ERROR: missing boot file: /boot/${f}"
            exit 1
        fi
    done

    if [ ! -e "${ROOTFS_DIR}/boot/boot.scr" ] && [ ! -e "${ROOTFS_DIR}/boot/extlinux/extlinux.conf" ]; then
        echo "ERROR: missing boot loader config: /boot/boot.scr or /boot/extlinux/extlinux.conf"
        exit 1
    fi
}

copy_qemu
extract_bsp_debs
KERNEL_VERSION="$(kernel_version_from_modules)"
stage_boot_files "${KERNEL_VERSION}"

case "${DIST}" in
    alpine)
        configure_alpine_overlay
        configure_alpine_accounts
        ;;
    fedora|archlinuxarm)
        prepare_systemd_overlay
        configure_systemd_accounts
        configure_systemd_services
        ;;
    *)
        echo "ERROR: unsupported DIST for portable BSP install: ${DIST}"
        exit 1
        ;;
esac

bash "${REPO_DIR}/scripts/write-build-time-seed.sh" "${ROOTFS_DIR}"
write_identity
write_armbian_release_fallback
generate_initramfs "${KERNEL_VERSION}"
write_boot_environment
final_sanity_check

${SUDO} rm -rf "${TMP_DIR}"

printf 'Portable BSP installed into rootfs.\n'
