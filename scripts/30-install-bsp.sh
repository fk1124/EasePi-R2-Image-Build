#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -z "${SUDO:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
fi

DIST="${DIST:-debian}"
RELEASE="${RELEASE:-trixie}"
BRANCH="${BRANCH:-current}"
IMAGE_TYPE="${IMAGE_TYPE:-minimal}"
ROOTFS_NAME="${ROOTFS_NAME:-${DIST}-${RELEASE}-${BRANCH}-${IMAGE_TYPE}}"
ROOTFS_DIR="${REPO_DIR}/output/rootfs/${ROOTFS_NAME}"
BSP_NAME="${BSP_NAME:-${DIST}-${RELEASE}-${BRANCH}}"
BSP_DIR="${REPO_DIR}/output/bsp/${BSP_NAME}"

CREATE_USER="${CREATE_USER:-no}"
IMAGE_USER="${IMAGE_USER:-}"
IMAGE_PASSWORD="${IMAGE_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
LOCK_ROOT="${LOCK_ROOT:-no}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-easepi-r2}"
EASEPI_R2_VENDOR_GPU_STACK="${EASEPI_R2_VENDOR_GPU_STACK:-libmali}"
EASEPI_R2_LIBMALI_DEB_URL="${EASEPI_R2_LIBMALI_DEB_URL:-https://github.com/tsukumijima/libmali-rockchip/releases/download/v1.9-1-20260312-bd33ee2/libmali-valhall-g610-g24p0-gbm_1.9-1_arm64.deb}"
EASEPI_R2_LIBMALI_DEB_SHA256="${EASEPI_R2_LIBMALI_DEB_SHA256:-32ffe853e8d56295284637252f1da15dd868a8f7c6b8da6b9f77616ba285eb1a}"
EASEPI_R2_VENDOR_HDMI_DEBUG="${EASEPI_R2_VENDOR_HDMI_DEBUG:-no}"
EASEPI_R2_DESKTOP_PROFILE="${EASEPI_R2_DESKTOP_PROFILE:-}"
EASEPI_R2_DESKTOP_LOCALE="${EASEPI_R2_DESKTOP_LOCALE:-zh_CN.UTF-8}"

printf '\n[3/4] Install EasePi-R2 kernel / DTB / boot files into rootfs\n'

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

cleanup_mounts() {
    ${SUDO} umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    ${SUDO} umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
}
trap cleanup_mounts EXIT

stage_vendor_libmali() {
    [ "${BRANCH}" = "vendor" ] || return 0
    [ "${EASEPI_R2_VENDOR_GPU_STACK}" = "libmali" ] || return 0

    local cache_dir="${REPO_DIR}/work/cache/libmali"
    local deb_name deb_path tmp_path

    deb_name="$(basename "${EASEPI_R2_LIBMALI_DEB_URL}")"
    deb_path="${cache_dir}/${deb_name}"
    tmp_path="${deb_path}.tmp"

    mkdir -p "${cache_dir}"
    if [ ! -f "${deb_path}" ]; then
        curl -fL --retry 3 --connect-timeout 15 -o "${tmp_path}" "${EASEPI_R2_LIBMALI_DEB_URL}"
        mv -f "${tmp_path}" "${deb_path}"
    fi

    printf '%s  %s\n' "${EASEPI_R2_LIBMALI_DEB_SHA256}" "${deb_path}" | sha256sum -c -
    ${SUDO} cp "${deb_path}" "${ROOTFS_DIR}/tmp/easepi-r2-libmali.deb"
}

decompress_zst_firmware_in_rootfs() {
    local root="$1"
    local zst base

    command -v zstd >/dev/null 2>&1 || return 0
    for zst in \
        "${root}/lib/firmware/brcm/"*.zst \
        "${root}/lib/firmware/cypress/"*.zst \
        "${root}/lib/firmware/rtl_nic/"*.zst \
        "${root}/lib/firmware/arm/mali/arch10.8/"*.zst \
        "${root}/lib/firmware/regulatory.db.zst"; do
        [ -f "${zst}" ] || continue
        base="${zst%.zst}"
        [ -e "${base}" ] || ${SUDO} zstd -d -q -f "${zst}" -o "${base}" || true
    done
}

fix_firmware_aliases_in_rootfs() {
    local root="$1"
    local fw_dir="${root}/lib/firmware/brcm"
    local cy_fw_dir="${root}/lib/firmware/cypress"
    local candidate=""

    [ -d "${fw_dir}" ] || return 0

    if [ ! -f "${fw_dir}/brcmfmac43455-sdio.txt" ]; then
        for candidate in \
            "${fw_dir}/brcmfmac43455-sdio.AW-CM256SM.txt" \
            "${fw_dir}/brcmfmac43455-sdio.acepc-t8.txt" \
            "${fw_dir}/brcmfmac43455-sdio.raspberrypi,4-model-b.txt"; do
            [ -f "${candidate}" ] || continue
            ${SUDO} ln -sfn "$(basename "${candidate}")" "${fw_dir}/brcmfmac43455-sdio.txt"
            break
        done
    fi

    if [ ! -f "${fw_dir}/brcmfmac43455-sdio.bin" ] && [ -f "${cy_fw_dir}/cyfmac43455-sdio.bin" ]; then
        ${SUDO} ln -sfn ../cypress/cyfmac43455-sdio.bin "${fw_dir}/brcmfmac43455-sdio.bin"
    fi
    if [ ! -f "${fw_dir}/brcmfmac43455-sdio.clm_blob" ] && [ -f "${cy_fw_dir}/cyfmac43455-sdio.clm_blob" ]; then
        ${SUDO} ln -sfn ../cypress/cyfmac43455-sdio.clm_blob "${fw_dir}/brcmfmac43455-sdio.clm_blob"
    fi

    [ -f "${fw_dir}/brcmfmac43455-sdio.bin" ] && \
        ${SUDO} ln -sfn brcmfmac43455-sdio.bin "${fw_dir}/brcmfmac43455-sdio.linkease,easepi-r2.bin"
    [ -f "${fw_dir}/brcmfmac43455-sdio.txt" ] && \
        ${SUDO} ln -sfn brcmfmac43455-sdio.txt "${fw_dir}/brcmfmac43455-sdio.linkease,easepi-r2.txt"
    [ -f "${fw_dir}/brcmfmac43455-sdio.clm_blob" ] && \
        ${SUDO} ln -sfn brcmfmac43455-sdio.clm_blob "${fw_dir}/brcmfmac43455-sdio.linkease,easepi-r2.clm_blob"
}

write_gpu_profile() {
    ${SUDO} mkdir -p "${ROOTFS_DIR}/etc/modules-load.d" "${ROOTFS_DIR}/etc/modprobe.d"

    if [ "${BRANCH}" = "vendor" ]; then
        ${SUDO} tee "${ROOTFS_DIR}/etc/modules-load.d/easepi-r2-gpu.conf" >/dev/null <<'EOF_GPU_MODULES_VENDOR'
# Rockchip vendor 6.1 uses the in-tree Mali kbase driver. Do not force-load panthor.
EOF_GPU_MODULES_VENDOR
        ${SUDO} tee "${ROOTFS_DIR}/etc/modprobe.d/easepi-r2-gpu.conf" >/dev/null <<'EOF_GPU_MODPROBE_VENDOR'
# Vendor kernel uses ARM/Rockchip Mali kbase for RK3588 Mali-G610.
blacklist panfrost
blacklist panthor
EOF_GPU_MODPROBE_VENDOR
    else
        ${SUDO} tee "${ROOTFS_DIR}/etc/modules-load.d/easepi-r2-gpu.conf" >/dev/null <<'EOF_GPU_MODULES_MAINLINE'
# Load RK3588 Mali-G610's mainline DRM driver early.
panthor
EOF_GPU_MODULES_MAINLINE
        ${SUDO} tee "${ROOTFS_DIR}/etc/modprobe.d/easepi-r2-gpu.conf" >/dev/null <<'EOF_GPU_MODPROBE_MAINLINE'
# panfrost is for older Mali generations and should not bind this GPU.
blacklist panfrost
EOF_GPU_MODPROBE_MAINLINE
    fi
}

configure_desktop_profile() {
    [ "${IMAGE_TYPE}" = "desktop" ] || return 0
    [ -n "${EASEPI_R2_DESKTOP_PROFILE}" ] || return 0

    local session="xfce"
    local start_command="startxfce4"

    case "${EASEPI_R2_DESKTOP_PROFILE}" in
        xfce)
            session="xfce"
            start_command="startxfce4"
            ;;
        kde)
            session="plasma"
            start_command="startplasma-x11"
            ;;
        *)
            echo "ERROR: unsupported EASEPI_R2_DESKTOP_PROFILE: ${EASEPI_R2_DESKTOP_PROFILE}"
            exit 1
            ;;
    esac

    ${SUDO} mkdir -p "${ROOTFS_DIR}/etc/skel/.config"
    ${SUDO} tee "${ROOTFS_DIR}/etc/easepi-r2-desktop.env" >/dev/null <<EOF_DESKTOP_ENV
DESKTOP_ENABLED=yes
DESKTOP_PROFILE=${EASEPI_R2_DESKTOP_PROFILE}
DESKTOP_SESSION=${session}
DESKTOP_USER=${IMAGE_USER}
DESKTOP_START_COMMAND=${start_command}
DESKTOP_LOCALE=${EASEPI_R2_DESKTOP_LOCALE}
EOF_DESKTOP_ENV

    ${SUDO} tee "${ROOTFS_DIR}/etc/default/locale" >/dev/null <<EOF_LOCALE
LANG=${EASEPI_R2_DESKTOP_LOCALE}
LANGUAGE=zh_CN:zh
LC_CTYPE=${EASEPI_R2_DESKTOP_LOCALE}
LC_MESSAGES=${EASEPI_R2_DESKTOP_LOCALE}
LC_ALL=
EOF_LOCALE

    ${SUDO} tee "${ROOTFS_DIR}/etc/environment" >/dev/null <<EOF_ENVIRONMENT
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LANG=${EASEPI_R2_DESKTOP_LOCALE}
LANGUAGE=zh_CN:zh
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
INPUT_METHOD=fcitx
SDL_IM_MODULE=fcitx
EOF_ENVIRONMENT

    ${SUDO} mkdir -p "${ROOTFS_DIR}/etc/X11/xorg.conf.d"
    ${SUDO} tee "${ROOTFS_DIR}/etc/X11/Xwrapper.config" >/dev/null <<'EOF_XWRAPPER'
allowed_users=console
needs_root_rights=yes
EOF_XWRAPPER

    ${SUDO} tee "${ROOTFS_DIR}/etc/X11/xorg.conf.d/40-libinput.conf" >/dev/null <<'EOF_LIBINPUT'
Section "InputClass"
        Identifier "libinput keyboard catchall"
        MatchIsKeyboard "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
EndSection

Section "InputClass"
        Identifier "libinput pointer catchall"
        MatchIsPointer "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
EndSection

Section "InputClass"
        Identifier "libinput touchpad catchall"
        MatchIsTouchpad "on"
        MatchDevicePath "/dev/input/event*"
        Driver "libinput"
EndSection
EOF_LIBINPUT

    ${SUDO} tee "${ROOTFS_DIR}/etc/skel/.xinputrc" >/dev/null <<'EOF_XINPUT'
run_im fcitx5
EOF_XINPUT

    ${SUDO} tee "${ROOTFS_DIR}/etc/skel/.xinitrc" >/dev/null <<EOF_SKEL_XINITRC
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=${EASEPI_R2_DESKTOP_LOCALE}
export LANGUAGE=zh_CN:zh
export LC_CTYPE=${EASEPI_R2_DESKTOP_LOCALE}
export LC_MESSAGES=${EASEPI_R2_DESKTOP_LOCALE}
export LC_ALL=
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export INPUT_METHOD=fcitx
export SDL_IM_MODULE=fcitx

[ -f "\$HOME/.xinputrc" ] && . "\$HOME/.xinputrc"
exec dbus-run-session sh -c 'fcitx5 -d >/tmp/fcitx5-\$USER.log 2>&1; exec ${start_command}'
EOF_SKEL_XINITRC

    ${SUDO} tee "${ROOTFS_DIR}/etc/skel/.xsession" >/dev/null <<EOF_SKEL_XSESSION
#!/bin/sh
exec "\$HOME/.xinitrc"
EOF_SKEL_XSESSION
}

install_desktop_grow_rootfs_service() {
    [ "${IMAGE_TYPE}" = "desktop" ] || return 0

    ${SUDO} mkdir -p "${ROOTFS_DIR}/usr/local/sbin" "${ROOTFS_DIR}/etc/systemd/system"

    ${SUDO} tee "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-grow-rootfs" >/dev/null <<'EOF_GROW_ROOTFS_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

STAMP="/var/lib/easepi-r2/grow-rootfs.done"
SERVICE="easepi-r2-grow-rootfs.service"

log() {
    printf 'easepi-r2-grow-rootfs: %s\n' "$*"
}

finish() {
    mkdir -p "$(dirname "${STAMP}")"
    touch "${STAMP}"
    systemctl disable "${SERVICE}" >/dev/null 2>&1 || true
}

[ ! -e "${STAMP}" ] || exit 0

if ! command -v growpart >/dev/null 2>&1; then
    log "growpart not found"
    exit 1
fi

root_source="$(findmnt -no SOURCE / | head -n1 || true)"
root_dev="$(readlink -f "${root_source}" 2>/dev/null || true)"

if [ -z "${root_dev}" ] || [ ! -b "${root_dev}" ]; then
    root_majmin="$(findmnt -no MAJ:MIN / | head -n1 || true)"
    if [ -n "${root_majmin}" ] && [ -e "/dev/block/${root_majmin}" ]; then
        root_dev="$(readlink -f "/dev/block/${root_majmin}")"
    fi
fi

if [ -z "${root_dev}" ] || [ ! -b "${root_dev}" ]; then
    log "cannot resolve root block device from ${root_source:-unknown}"
    exit 1
fi

disk_name="$(lsblk -no PKNAME "${root_dev}" | head -n1 | tr -d '[:space:]')"
part_num="$(lsblk -no PARTN "${root_dev}" | head -n1 | tr -d '[:space:]')"

if [ -z "${disk_name}" ] || [ -z "${part_num}" ]; then
    log "root device ${root_dev} is not a plain disk partition"
    exit 1
fi

disk="/dev/${disk_name}"
if [ ! -b "${disk}" ]; then
    log "parent disk ${disk} not found"
    exit 1
fi

before_bytes="$(blockdev --getsize64 "${root_dev}" 2>/dev/null || printf '0')"
disk_bytes="$(blockdev --getsize64 "${disk}" 2>/dev/null || printf '0')"
log "expanding ${root_dev} on ${disk} to fill ${disk_bytes} bytes"

set +e
grow_output="$(growpart "${disk}" "${part_num}" 2>&1)"
grow_rc=$?
set -e

if [ -n "${grow_output}" ]; then
    printf '%s\n' "${grow_output}"
fi

if [ "${grow_rc}" -ne 0 ]; then
    case "${grow_output}" in
        *NOCHANGE*) ;;
        *)
            log "growpart failed"
            exit "${grow_rc}"
            ;;
    esac
fi

partx -u "${disk}" >/dev/null 2>&1 || true
blockdev --rereadpt "${disk}" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true

resize2fs "${root_dev}"

after_bytes="$(blockdev --getsize64 "${root_dev}" 2>/dev/null || printf '0')"
log "root partition size: ${before_bytes} -> ${after_bytes} bytes"

finish
EOF_GROW_ROOTFS_SCRIPT

    ${SUDO} chmod +x "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-grow-rootfs"

    ${SUDO} tee "${ROOTFS_DIR}/etc/systemd/system/easepi-r2-grow-rootfs.service" >/dev/null <<'EOF_GROW_ROOTFS_SERVICE'
[Unit]
Description=Grow root filesystem to fill storage
After=local-fs.target systemd-udevd.service
Before=multi-user.target
ConditionPathExists=!/var/lib/easepi-r2/grow-rootfs.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easepi-r2-grow-rootfs
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF_GROW_ROOTFS_SERVICE
}

${SUDO} mkdir -p "${ROOTFS_DIR}/tmp/bsp"
${SUDO} cp "${BSP_DIR}"/*.deb "${ROOTFS_DIR}/tmp/bsp/"
stage_vendor_libmali

${SUDO} mount --bind /dev "${ROOTFS_DIR}/dev"
${SUDO} mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
${SUDO} mount -t proc proc "${ROOTFS_DIR}/proc"
${SUDO} mount -t sysfs sysfs "${ROOTFS_DIR}/sys"

${SUDO} chroot "${ROOTFS_DIR}" /usr/bin/env \
  BRANCH="${BRANCH}" \
  /bin/bash -e <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
shopt -s nullglob

branch_kernel_flavor() {
  case "${BRANCH}" in
    vendor) printf '%s\n' "vendor-rk35xx" ;;
    current) printf '%s\n' "current-rockchip64" ;;
    edge|linux7) printf '%s\n' "edge-rockchip64" ;;
    *)
      echo "ERROR: unsupported BRANCH inside BSP install: ${BRANCH}"
      exit 1
      ;;
  esac
}

KERNEL_FLAVOR="$(branch_kernel_flavor)"

KERNEL_DEBS=(/tmp/bsp/linux-image-${KERNEL_FLAVOR}_*.deb)
DTB_DEBS=(/tmp/bsp/linux-dtb-${KERNEL_FLAVOR}_*.deb)
if [ ${#KERNEL_DEBS[@]} -eq 0 ] || [ ${#DTB_DEBS[@]} -eq 0 ]; then
  echo "ERROR: missing required BSP kernel packages for ${KERNEL_FLAVOR}"
  [ ${#KERNEL_DEBS[@]} -gt 0 ] || echo "  missing: linux-image-${KERNEL_FLAVOR}_*.deb"
  [ ${#DTB_DEBS[@]} -gt 0 ] || echo "  missing: linux-dtb-${KERNEL_FLAVOR}_*.deb"
  echo "Contents of /tmp/bsp:"
  find /tmp/bsp -maxdepth 1 -mindepth 1 -printf '  %f\n' 2>/dev/null | sort || ls -la /tmp/bsp
  exit 1
fi

DEBS=("${KERNEL_DEBS[@]}" "${DTB_DEBS[@]}")
dpkg -i "${DEBS[@]}" || apt-get -f install -y


# initrd 是启动关键文件。这里不要再 || true，否则 initrd 生成失败也会继续打包。
update-initramfs -u -k all

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/bsp
CHROOT

cleanup_mounts
trap - EXIT

decompress_zst_firmware_in_rootfs "${ROOTFS_DIR}"

# Copy EasePi-R2 peripheral overlay directly, because this image does not rely on a full Armbian userspace.
if [ -d "${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals" ]; then
    ${SUDO} rsync -a "${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals/" "${ROOTFS_DIR}/"
    # eth0-eth3 are aligned by /usr/local/sbin/easepi-r2-eth-order using
    # /proc/device-tree/eth_order. Remove legacy direct .link renames to avoid
    # eth1 <-> eth2 "File exists" conflicts.
    ${SUDO} rm -f "${ROOTFS_DIR}"/etc/systemd/network/10-easepi-r2-eth{0,1,2,3}.link
    ${SUDO} rm -f "${ROOTFS_DIR}/etc/modprobe.d/99-easepi-r2-panthor-manual-only.conf"
    ${SUDO} rm -f "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-gpu-check"
    ${SUDO} chmod +x "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-eth-order" 2>/dev/null || true
    ${SUDO} chmod +x "${ROOTFS_DIR}/usr/local/sbin/bluetooth-hciattach.sh" 2>/dev/null || true
fi
write_gpu_profile
configure_desktop_profile
install_desktop_grow_rootfs_service

# Basic system identity and optional account configuration.
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

${SUDO} chroot "${ROOTFS_DIR}" /usr/bin/env \
  DIST="${DIST}" \
  RELEASE="${RELEASE}" \
  CREATE_USER="${CREATE_USER}" \
  IMAGE_USER="${IMAGE_USER}" \
  IMAGE_PASSWORD="${IMAGE_PASSWORD}" \
  ROOT_PASSWORD="${ROOT_PASSWORD}" \
  LOCK_ROOT="${LOCK_ROOT}" \
  BRANCH="${BRANCH}" \
  EASEPI_R2_VENDOR_GPU_STACK="${EASEPI_R2_VENDOR_GPU_STACK}" \
  IMAGE_TYPE="${IMAGE_TYPE}" \
  EASEPI_R2_DESKTOP_PROFILE="${EASEPI_R2_DESKTOP_PROFILE}" \
  EASEPI_R2_DESKTOP_LOCALE="${EASEPI_R2_DESKTOP_LOCALE}" \
  /bin/bash -e <<'CHROOT_USER'
export DEBIAN_FRONTEND=noninteractive

APT_COMMON_OPTIONS=(
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

apt_install_required() {
  [ "$#" -gt 0 ] || return 0
  apt-get install -y --no-install-recommends "${APT_COMMON_OPTIONS[@]}" "$@"
}

apt_install_non_required() {
  local level="$1"
  shift

  local pkg
  for pkg in "$@"; do
    if ! apt-get install -y --no-install-recommends "${APT_COMMON_OPTIONS[@]}" "${pkg}"; then
      echo "WARN: ${level} package install failed: ${pkg}"
    fi
  done
}

apt_install_recommended() {
  apt_install_non_required "recommended" "$@"
}

apt_install_optional() {
  apt_install_non_required "optional" "$@"
}

# 默认不创建普通用户。只有显式 CREATE_USER=yes 时才创建。
if [ "${CREATE_USER}" = "yes" ]; then
  if [ -z "${IMAGE_USER}" ] || [ -z "${IMAGE_PASSWORD}" ]; then
    echo "ERROR: CREATE_USER=yes requires IMAGE_USER and IMAGE_PASSWORD."
    exit 1
  fi

  for g in sudo adm dialout video audio plugdev netdev; do
    getent group "$g" >/dev/null 2>&1 || groupadd "$g"
  done

  if ! id -u "${IMAGE_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,adm,dialout,video,audio,plugdev,netdev "${IMAGE_USER}"
  fi

  printf '%s:%s\n' "${IMAGE_USER}" "${IMAGE_PASSWORD}" | chpasswd
  cp -af /etc/skel/. "/home/${IMAGE_USER}/" 2>/dev/null || true
  chown -R "${IMAGE_USER}:${IMAGE_USER}" "/home/${IMAGE_USER}" 2>/dev/null || true
  grep -q '^PATH=' "/home/${IMAGE_USER}/.profile" 2>/dev/null || cat >>"/home/${IMAGE_USER}/.profile" <<'EOF_PROFILE_PATH'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF_PROFILE_PATH
else
  cat >/etc/easepi-r2-no-default-login.txt <<'EOF_NO_LOGIN'
This image was built without a default normal user.
No public default account or password is configured.

To create a user during build, run:
  CREATE_USER=yes IMAGE_USER=fk IMAGE_PASSWORD='your_password' bash build-bsp-image.sh ${DIST} ${RELEASE} ${BRANCH} minimal

To set a root password during build, run:
  ROOT_PASSWORD='your_root_password' bash build-bsp-image.sh ${DIST} ${RELEASE} ${BRANCH} minimal

If you intentionally want no built-in login account, run:
  LOCK_ROOT=yes bash build-bsp-image.sh ${DIST} ${RELEASE} ${BRANCH} minimal
EOF_NO_LOGIN
fi

# root 不设置公开默认密码。
# 默认不创建普通用户时，build-bsp-image.sh 会要求输入/传入 ROOT_PASSWORD，保证刷机后可登录。
# 只有显式 LOCK_ROOT=yes 时才锁定 root。
if [ "${LOCK_ROOT}" = "yes" ]; then
  passwd -l root || true
elif [ -n "${ROOT_PASSWORD}" ]; then
  printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
else
  passwd -l root || true
fi

systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
# Safety net for custom/minimal rootfs variants: ensure router runtime exists.
# The overlay may already have written /etc/nftables.conf before nftables is
# installed. Move it away during package installation to avoid dpkg's conffile
# prompt in non-interactive chroot builds, then restore our router rules.
if ! command -v dnsmasq >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
  NFT_BACKUP="/tmp/easepi-r2-nftables.conf.router"
  if [ -f /etc/nftables.conf ]; then
    mv /etc/nftables.conf "$NFT_BACKUP"
  fi
  EASEPI_R2_REQUIRED_RUNTIME=(
    iproute2 iputils-ping ethtool bridge-utils dnsmasq nftables iptables
    curl ca-certificates
  )
  EASEPI_R2_RECOMMENDED_RUNTIME=(
    ppp pppoe wpasupplicant hostapd rfkill bluetooth bluez
  )
  EASEPI_R2_OPTIONAL_RUNTIME=(
    bluez-tools v4l-utils
  )
  if [ "${BRANCH}" = "vendor" ]; then
    EASEPI_R2_REQUIRED_GPU_RUNTIME=(libdrm2 libgbm1 ocl-icd-libopencl1)
    EASEPI_R2_OPTIONAL_GPU_RUNTIME=(clinfo)
  else
    EASEPI_R2_REQUIRED_GPU_RUNTIME=(
      libdrm2 libegl-mesa0 libgles2 libgl1-mesa-dri
      mesa-vulkan-drivers mesa-utils
    )
    EASEPI_R2_OPTIONAL_GPU_RUNTIME=(
      vulkan-tools kmscube glmark2-es2-drm
    )
  fi
  apt-get update
  apt_install_required "${EASEPI_R2_REQUIRED_RUNTIME[@]}" "${EASEPI_R2_REQUIRED_GPU_RUNTIME[@]}"
  apt_install_recommended "${EASEPI_R2_RECOMMENDED_RUNTIME[@]}"
  apt_install_optional "${EASEPI_R2_OPTIONAL_RUNTIME[@]}" "${EASEPI_R2_OPTIONAL_GPU_RUNTIME[@]}"
  if [ -f "$NFT_BACKUP" ]; then
    mv "$NFT_BACKUP" /etc/nftables.conf
  fi
fi

if [ "${BRANCH}" = "vendor" ] && [ "${EASEPI_R2_VENDOR_GPU_STACK}" = "libmali" ] && [ -f /tmp/easepi-r2-libmali.deb ]; then
  apt-get update
  apt_install_required libdrm2 libgbm1 ocl-icd-libopencl1 ca-certificates
  apt_install_optional clinfo v4l-utils
  dpkg -i /tmp/easepi-r2-libmali.deb || apt-get -f install -y
  rm -f /tmp/easepi-r2-libmali.deb
fi

FW_DIR="/lib/firmware/brcm"
CY_FW_DIR="/lib/firmware/cypress"
if [ -d "$FW_DIR" ]; then
  if command -v zstd >/dev/null 2>&1; then
    for zst in "$FW_DIR"/*.zst "$CY_FW_DIR"/*.zst; do
      [ -f "$zst" ] || continue
      base="${zst%.zst}"
      [ -e "$base" ] || zstd -d -q -f "$zst" -o "$base" || true
    done
  fi
  if [ ! -f "$FW_DIR/brcmfmac43455-sdio.txt" ]; then
    for candidate in \
      "$FW_DIR/brcmfmac43455-sdio.AW-CM256SM.txt" \
      "$FW_DIR/brcmfmac43455-sdio.acepc-t8.txt" \
      "$FW_DIR/brcmfmac43455-sdio.raspberrypi,4-model-b.txt"; do
      if [ -f "$candidate" ]; then
        ln -sfn "$(basename "$candidate")" "$FW_DIR/brcmfmac43455-sdio.txt"
        break
      fi
    done
  fi
  if [ ! -f "$FW_DIR/brcmfmac43455-sdio.bin" ] && [ -f "$CY_FW_DIR/cyfmac43455-sdio.bin" ]; then
    ln -sfn ../cypress/cyfmac43455-sdio.bin "$FW_DIR/brcmfmac43455-sdio.bin"
  fi
  if [ ! -f "$FW_DIR/brcmfmac43455-sdio.clm_blob" ] && [ -f "$CY_FW_DIR/cyfmac43455-sdio.clm_blob" ]; then
    ln -sfn ../cypress/cyfmac43455-sdio.clm_blob "$FW_DIR/brcmfmac43455-sdio.clm_blob"
  fi
  [ -f "$FW_DIR/brcmfmac43455-sdio.bin" ] && ln -sfn brcmfmac43455-sdio.bin "$FW_DIR/brcmfmac43455-sdio.linkease,easepi-r2.bin"
  [ -f "$FW_DIR/brcmfmac43455-sdio.txt" ] && ln -sfn brcmfmac43455-sdio.txt "$FW_DIR/brcmfmac43455-sdio.linkease,easepi-r2.txt"
  [ -f "$FW_DIR/brcmfmac43455-sdio.clm_blob" ] && ln -sfn brcmfmac43455-sdio.clm_blob "$FW_DIR/brcmfmac43455-sdio.linkease,easepi-r2.clm_blob"
fi
# EasePi-R2 is shipped as a router base: systemd-networkd owns the network.
systemctl disable NetworkManager 2>/dev/null || true
# Align EasePi-R2 RTL8125 port names before any network manager starts.
systemctl enable easepi-r2-eth-order.service 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true
systemctl enable dnsmasq 2>/dev/null || true
systemctl enable nftables 2>/dev/null || true
# Multi-port router images often have unplugged LAN/backup-WAN links; waiting
# for "network-online" causes false boot failures and does not help DHCP/NAT.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

# Native systemd-networkd router base: disable netplan configs that can generate
# /run/systemd/network/10-netplan-*.network and preempt LAN Bridge=br-lan rules.
mkdir -p /etc/easepi-r2-router/disabled-netplan-build /etc/easepi-r2-router/disabled-networkd-build
if [ -d /etc/netplan ]; then
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [ -e "$f" ] || continue
    mv "$f" "/etc/easepi-r2-router/disabled-netplan-build/$(basename "$f")" 2>/dev/null || true
  done
fi
if [ -d /etc/systemd/network ]; then
  for f in /etc/systemd/network/*.network; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      *easepi-r2*.network) ;;
      *) mv "$f" "/etc/easepi-r2-router/disabled-networkd-build/$b" 2>/dev/null || true ;;
    esac
  done
fi
rm -f /run/systemd/network/*netplan*.network 2>/dev/null || true

systemctl enable bluetooth-hciattach.service 2>/dev/null || true
systemctl enable ir-keymap.service 2>/dev/null || true
chmod +x /usr/local/sbin/bluetooth-hciattach.sh 2>/dev/null || true

if [ "${IMAGE_TYPE}" = "desktop" ]; then
  systemctl enable easepi-r2-grow-rootfs.service 2>/dev/null || true
fi

if [ -n "${EASEPI_R2_DESKTOP_PROFILE}" ] && [ "${IMAGE_TYPE}" = "desktop" ]; then
  if [ -n "${IMAGE_USER}" ] && id -u "${IMAGE_USER}" >/dev/null 2>&1; then
    usermod -a -G render,input "${IMAGE_USER}" 2>/dev/null || true
  fi
  systemctl disable display-manager.service 2>/dev/null || true
  systemctl disable lightdm.service 2>/dev/null || true
  systemctl disable sddm.service 2>/dev/null || true
  systemctl set-default multi-user.target 2>/dev/null || true
fi

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
locale-gen zh_CN.UTF-8 en_US.UTF-8 2>/dev/null || true
if [ -n "${EASEPI_R2_DESKTOP_PROFILE}" ] && [ "${IMAGE_TYPE}" = "desktop" ]; then
  update-locale LANG="${EASEPI_R2_DESKTOP_LOCALE}" LANGUAGE=zh_CN:zh LC_CTYPE="${EASEPI_R2_DESKTOP_LOCALE}" LC_MESSAGES="${EASEPI_R2_DESKTOP_LOCALE}" GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx INPUT_METHOD=fcitx 2>/dev/null || true
else
  update-locale LANG=en_US.UTF-8 2>/dev/null || true
fi
CHROOT_USER

decompress_zst_firmware_in_rootfs "${ROOTFS_DIR}"
fix_firmware_aliases_in_rootfs "${ROOTFS_DIR}"

# Network stack is managed by systemd-networkd. NetworkManager is intentionally not configured.

# Create boot environment. ROOT_UUID is replaced during image packing.
${SUDO} mkdir -p "${ROOTFS_DIR}/boot/extlinux"
BOOTENV_EXTRAARGS="net.ifnames=1"
BOOTENV_VENDOR_LINES=""
if [ "${BRANCH}" = "vendor" ]; then
    BOOTENV_EXTRAARGS="cma=256M net.ifnames=1"
    BOOTENV_VENDOR_LINES="$(cat <<'EOF_VENDOR_BOOTENV'
overlay_prefix=rockchip-rk3588
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
EOF_VENDOR_BOOTENV
)"
fi

${SUDO} tee "${ROOTFS_DIR}/boot/armbianEnv.txt" >/dev/null <<EOF_ENV
verbosity=1
bootlogo=false
console=both
${BOOTENV_VENDOR_LINES}
fdtfile=rockchip/rk3588-easepi-r2.dtb
rootdev=UUID=ROOT_UUID
rootfstype=ext4
extraargs=${BOOTENV_EXTRAARGS}
EOF_ENV

enable_vendor_hdmi_debug() {
    [ "${BRANCH}" = "vendor" ] || return 0
    [ "${EASEPI_R2_VENDOR_HDMI_DEBUG}" = "yes" ] || return 0

    local env_file="${ROOTFS_DIR}/boot/armbianEnv.txt"
    local boot_cmd="${ROOTFS_DIR}/boot/boot.cmd"
    local boot_scr="${ROOTFS_DIR}/boot/boot.scr"
    local extraargs=""
    local arg=""

    [ -f "${env_file}" ] || return 0
    printf 'Enabling vendor HDMI debug console.\n'

    extraargs="$(sed -n 's/^extraargs=//p' "${env_file}" | tail -1)"
    for arg in \
        ignore_loglevel \
        no_console_suspend \
        log_buf_len=4M \
        systemd.log_level=debug \
        systemd.log_target=console \
        fbcon=nodefer \
        plymouth.enable=0
    do
        case " ${extraargs} " in
            *" ${arg} "*) ;;
            *) extraargs="${extraargs:+${extraargs} }${arg}" ;;
        esac
    done

    ${SUDO} sed -i \
      -e 's/^verbosity=.*/verbosity=7/' \
      -e 's/^console=.*/console=both/' \
      -e 's/^bootlogo=.*/bootlogo=false/' \
      -e '/^stdin=/d' \
      -e '/^stdout=/d' \
      -e '/^stderr=/d' \
      -e '/^extraargs=/d' \
      "${env_file}"

    ${SUDO} tee -a "${env_file}" >/dev/null <<EOF_VENDOR_HDMI_DEBUG
stdin=serial,usbkbd
stdout=serial,vidconsole
stderr=serial,vidconsole
extraargs=${extraargs}
EOF_VENDOR_HDMI_DEBUG

    if [ -f "${boot_cmd}" ]; then
        ${SUDO} sed -i \
          -e 's/setenv consoleargs "splash plymouth.ignore-serial-consoles ${consoleargs}"/setenv consoleargs "${consoleargs}"/' \
          -e 's/setenv consoleargs "splash=verbose ${consoleargs}"/setenv consoleargs "${consoleargs}"/' \
          "${boot_cmd}"
        ${SUDO} mkimage -C none -A arm -T script \
          -d "${boot_cmd}" \
          "${boot_scr}" >/dev/null
    fi
}

# Prefer Armbian's official RK35xx boot script if the build tree is available.
BOOT_CMD_SRC=""
if [ -n "${ARMBIAN_BUILD_DIR:-}" ] && [ -f "${ARMBIAN_BUILD_DIR}/config/bootscripts/boot-rk35xx.cmd" ]; then
    BOOT_CMD_SRC="${ARMBIAN_BUILD_DIR}/config/bootscripts/boot-rk35xx.cmd"
elif [ -f "${REPO_DIR}/../build/config/bootscripts/boot-rk35xx.cmd" ]; then
    BOOT_CMD_SRC="${REPO_DIR}/../build/config/bootscripts/boot-rk35xx.cmd"
elif [ -f "${HOME}/rk3588_build/build/config/bootscripts/boot-rk35xx.cmd" ]; then
    BOOT_CMD_SRC="${HOME}/rk3588_build/build/config/bootscripts/boot-rk35xx.cmd"
elif [ -f "${REPO_DIR}/work/armbian-build/config/bootscripts/boot-rk35xx.cmd" ]; then
    BOOT_CMD_SRC="${REPO_DIR}/work/armbian-build/config/bootscripts/boot-rk35xx.cmd"
fi

if [ -n "${BOOT_CMD_SRC}" ]; then
    ${SUDO} cp "${BOOT_CMD_SRC}" "${ROOTFS_DIR}/boot/boot.cmd"
    ${SUDO} mkimage -C none -A arm -T script \
      -d "${ROOTFS_DIR}/boot/boot.cmd" \
      "${ROOTFS_DIR}/boot/boot.scr" >/dev/null
else
    echo "WARN: Armbian boot-rk35xx.cmd not found. Falling back to extlinux.conf."
    ${SUDO} tee "${ROOTFS_DIR}/boot/extlinux/extlinux.conf" >/dev/null <<'EOF_EXTLINUX'
default linux
menu title EasePi-R2 Boot Menu
timeout 30

label linux
    menu label Debian for EasePi-R2
    linux /Image
    initrd /uInitrd
    fdt /dtb/rockchip/rk3588-easepi-r2.dtb
    append root=UUID=ROOT_UUID rootfstype=ext4 rootwait rw console=tty1 console=ttyFIQ0,1500000n8 net.ifnames=1
EOF_EXTLINUX
fi

# Stable generic files for Armbian RK35xx boot script, extlinux, and simple boot flows.
LATEST_KERNEL="$(${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -c "ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1" | sed 's#^/boot/##')"
LATEST_INITRD="$(${SUDO} chroot "${ROOTFS_DIR}" /bin/bash -c "ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1" | sed 's#^/boot/##')"

if [ -z "${LATEST_KERNEL}" ]; then
    echo "ERROR: no /boot/vmlinuz-* found after BSP install"
    exit 1
fi

if [ -z "${LATEST_INITRD}" ]; then
    echo "ERROR: no /boot/initrd.img-* found after BSP install"
    exit 1
fi

# /boot/vmlinuz is kept for generic compatibility.
${SUDO} ln -sf "${LATEST_KERNEL}" "${ROOTFS_DIR}/boot/vmlinuz"

# Armbian kernel postinst may already create /boot/Image as a symlink to vmlinuz-*.
# FAT32 boot partition does not preserve symlinks reliably, so force /boot/Image to be a real file.
${SUDO} rm -f "${ROOTFS_DIR}/boot/Image"
${SUDO} cp -f "${ROOTFS_DIR}/boot/${LATEST_KERNEL}" "${ROOTFS_DIR}/boot/Image"

# /boot/initrd.img is kept for generic compatibility.
${SUDO} ln -sf "${LATEST_INITRD}" "${ROOTFS_DIR}/boot/initrd.img"

# Armbian RK35xx boot script loads /boot/uInitrd, not /boot/initrd.img.
# FAT32 boot partition should receive a real uInitrd file.
${SUDO} rm -f "${ROOTFS_DIR}/boot/uInitrd"
${SUDO} mkimage -A arm64 -O linux -T ramdisk -C none -n uInitrd \
  -d "${ROOTFS_DIR}/boot/${LATEST_INITRD}" \
  "${ROOTFS_DIR}/boot/uInitrd"

# Final boot-file sanity check.
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

enable_vendor_hdmi_debug

printf 'BSP installed into rootfs.\n'
