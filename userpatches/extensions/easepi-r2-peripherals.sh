# EasePi-R2 Peripherals Extension: IR + AP6255 Bluetooth + systemd-networkd router base
# This extension intentionally keeps the classic userpatches/extensions/*.sh path
# for broad Armbian compatibility, while reading overlay files from the kit's
# userpatches/overlay/easepi-r2-peripherals directory.

: "${EASEPI_R2_VENDOR_GPU_STACK:=libmali}"
: "${EASEPI_R2_LIBMALI_DEB_URL:=https://github.com/tsukumijima/libmali-rockchip/releases/download/v1.9-1-20260312-bd33ee2/libmali-valhall-g610-g24p0-gbm_1.9-1_arm64.deb}"
: "${EASEPI_R2_LIBMALI_DEB_SHA256:=32ffe853e8d56295284637252f1da15dd868a8f7c6b8da6b9f77616ba285eb1a}"
: "${EASEPI_R2_VENDOR_HDMI_DEBUG:=no}"

function extension_prepare_config__easepi_r2_peripherals() {
	display_alert "Extension: EasePi-R2 Peripherals" "IR + Bluetooth + networkd router base" "info"
}

function easepi_r2_write_gpu_profile() {
	mkdir -p "${SDCARD}/etc/modules-load.d" "${SDCARD}/etc/modprobe.d"

	if [[ "${BRANCH:-current}" == "vendor" ]]; then
		cat > "${SDCARD}/etc/modules-load.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODULES_VENDOR'
# Rockchip vendor 6.1 uses the in-tree Mali kbase driver. Do not force-load panthor.
EOF_GPU_MODULES_VENDOR
		cat > "${SDCARD}/etc/modprobe.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODPROBE_VENDOR'
# Vendor kernel uses ARM/Rockchip Mali kbase for RK3588 Mali-G610.
blacklist panfrost
blacklist panthor
EOF_GPU_MODPROBE_VENDOR
	else
		cat > "${SDCARD}/etc/modules-load.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODULES_MAINLINE'
# Load RK3588 Mali-G610's mainline DRM driver early.
panthor
EOF_GPU_MODULES_MAINLINE
		cat > "${SDCARD}/etc/modprobe.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODPROBE_MAINLINE'
# panfrost is for older Mali generations and should not bind this GPU.
blacklist panfrost
EOF_GPU_MODPROBE_MAINLINE
	fi
}

function easepi_r2_stage_vendor_libmali() {
	[[ "${BRANCH:-current}" == "vendor" ]] || return 0
	[[ "${EASEPI_R2_VENDOR_GPU_STACK}" == "libmali" ]] || return 0

	local cache_root="${SRC:-/tmp}/cache/easepi-r2-libmali"
	local deb_name deb_path tmp_path

	deb_name="$(basename "${EASEPI_R2_LIBMALI_DEB_URL}")"
	deb_path="${cache_root}/${deb_name}"
	tmp_path="${deb_path}.tmp"

	mkdir -p "${cache_root}" "${SDCARD}/tmp"
	if [[ ! -f "${deb_path}" ]]; then
		curl -fL --retry 3 --connect-timeout 15 -o "${tmp_path}" "${EASEPI_R2_LIBMALI_DEB_URL}"
		mv -f "${tmp_path}" "${deb_path}"
	fi
	printf '%s  %s\n' "${EASEPI_R2_LIBMALI_DEB_SHA256}" "${deb_path}" | sha256sum -c -
	cp -f "${deb_path}" "${SDCARD}/tmp/easepi-r2-libmali.deb"
}

function pre_customize_image__copy_easepi_r2_peripheral_files() {
	display_alert "EasePi-R2" "Copying peripheral overlay files" "info"

	local OVERLAY_DIR=""

	# Preferred path inside the active Armbian build tree.
	if [[ -n "${SRC:-}" && -d "${SRC}/userpatches/overlay/easepi-r2-peripherals" ]]; then
		OVERLAY_DIR="${SRC}/userpatches/overlay/easepi-r2-peripherals"
	# Fallback: if EXTENSION_DIR is available and overlay sits next to extension.
	elif [[ -n "${EXTENSION_DIR:-}" && -d "${EXTENSION_DIR}/overlay" ]]; then
		OVERLAY_DIR="${EXTENSION_DIR}/overlay"
	fi

	if [[ -z "${OVERLAY_DIR}" || ! -d "${OVERLAY_DIR}" ]]; then
		display_alert "EasePi-R2" "Peripheral overlay not found; skipping IR/BT files" "wrn"
		return 0
	fi

	mkdir -p "${SDCARD}"
	cp -a "${OVERLAY_DIR}/." "${SDCARD}/"
	# eth0-eth3 are aligned by the early easepi-r2-eth-order service. Remove
	# legacy direct .link renames that cannot safely swap eth1 and eth2.
	rm -f "${SDCARD}"/etc/systemd/network/10-easepi-r2-eth{0,1,2,3}.link
	rm -f "${SDCARD}/etc/modprobe.d/99-easepi-r2-panthor-manual-only.conf"
	rm -f "${SDCARD}/usr/local/sbin/easepi-r2-gpu-check"
	chmod +x "${SDCARD}/usr/local/sbin/easepi-r2-eth-order" 2>/dev/null || true
	easepi_r2_write_gpu_profile

	if [[ -f "${SDCARD}/usr/local/sbin/bluetooth-hciattach.sh" ]]; then
		chmod +x "${SDCARD}/usr/local/sbin/bluetooth-hciattach.sh"
	fi


	if [[ -f "${SDCARD}/usr/local/ir/fix_infrared.sh" ]]; then
		chmod +x "${SDCARD}/usr/local/ir/fix_infrared.sh"
	fi
}

function easepi_r2_fix_brcm_firmware_aliases() {
	local FW_DIR="${SDCARD}/lib/firmware/brcm"
	local BT_PATCH="BCM4345C0_003.001.025.0162.0000_Generic_UART_37_4MHz_wlbga_ref_iLNA_iTR_eLG.hcd"

	[[ -d "${FW_DIR}" ]] || return 0

	if [[ -f "${FW_DIR}/${BT_PATCH}" ]]; then
		ln -sfn "${BT_PATCH}" "${FW_DIR}/BCM4345C0.linkease,easepi-r2.hcd"
		ln -sfn "${BT_PATCH}" "${FW_DIR}/BCM4345C0.hcd"
	fi

	[[ -f "${FW_DIR}/brcmfmac43455-sdio.bin" ]] && \
		ln -sfn "brcmfmac43455-sdio.bin" "${FW_DIR}/brcmfmac43455-sdio.linkease,easepi-r2.bin"
	[[ -f "${FW_DIR}/brcmfmac43455-sdio.txt" ]] && \
		ln -sfn "brcmfmac43455-sdio.txt" "${FW_DIR}/brcmfmac43455-sdio.linkease,easepi-r2.txt"
	[[ -f "${FW_DIR}/brcmfmac43455-sdio.clm_blob" ]] && \
		ln -sfn "brcmfmac43455-sdio.clm_blob" "${FW_DIR}/brcmfmac43455-sdio.linkease,easepi-r2.clm_blob"
}

function easepi_r2_tune_vendor_bootenv() {
	[[ "${BRANCH:-current}" == "vendor" ]] || return 0

	local env_file="${SDCARD}/boot/armbianEnv.txt"
	local extraargs=""

	[[ -f "${env_file}" ]] || return 0

	extraargs="$(sed -n 's/^extraargs=//p' "${env_file}" | tail -1)"
	case " ${extraargs} " in
		*" cma=256M "*) ;;
		*) extraargs="cma=256M${extraargs:+ ${extraargs}}" ;;
	esac

	sed -i \
		-e '/^overlay_prefix=/d' \
		-e '/^usbstoragequirks=/d' \
		-e '/^extraargs=/d' \
		"${env_file}"

	cat >> "${env_file}" <<EOF_VENDOR_BOOTENV
overlay_prefix=rockchip-rk3588
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
extraargs=${extraargs}
EOF_VENDOR_BOOTENV
}

function easepi_r2_enable_vendor_hdmi_debug() {
	[[ "${BRANCH:-current}" == "vendor" ]] || return 0
	[[ "${EASEPI_R2_VENDOR_HDMI_DEBUG}" == "yes" ]] || return 0

	local env_file="${SDCARD}/boot/armbianEnv.txt"
	local boot_cmd="${SDCARD}/boot/boot.cmd"
	local boot_scr="${SDCARD}/boot/boot.scr"
	local extraargs=""
	local arg=""

	[[ -f "${env_file}" ]] || return 0
	display_alert "EasePi-R2" "Enabling vendor HDMI debug console" "info"

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

	sed -i \
		-e 's/^verbosity=.*/verbosity=7/' \
		-e 's/^console=.*/console=both/' \
		-e 's/^bootlogo=.*/bootlogo=false/' \
		-e '/^stdin=/d' \
		-e '/^stdout=/d' \
		-e '/^stderr=/d' \
		-e '/^extraargs=/d' \
		"${env_file}"

	cat >> "${env_file}" <<EOF_VENDOR_HDMI_DEBUG
stdin=serial,usbkbd
stdout=serial,vidconsole
stderr=serial,vidconsole
extraargs=${extraargs}
EOF_VENDOR_HDMI_DEBUG

	if [[ -f "${boot_cmd}" && -x "$(command -v mkimage)" ]]; then
		sed -i \
			-e 's/setenv consoleargs "splash plymouth.ignore-serial-consoles ${consoleargs}"/setenv consoleargs "${consoleargs}"/' \
			-e 's/setenv consoleargs "splash=verbose ${consoleargs}"/setenv consoleargs "${consoleargs}"/' \
			"${boot_cmd}"
		mkimage -C none -A arm -T script -d "${boot_cmd}" "${boot_scr}" >/dev/null
	fi
}

function post_customize_image__enable_easepi_r2_peripheral_services() {
	display_alert "EasePi-R2" "Enabling peripheral services" "info"

	# Armbian's extension path does not consume rootfs/debian/packages-*.txt.
	# Install the router runtime explicitly so first boot has working DHCP/NAT.
	# Important: the overlay already contains /etc/nftables.conf. If nftables is
	# installed after that file exists, dpkg asks a conffile question and Armbian's
	# non-interactive chroot build fails with "end of file on stdin". Temporarily
	# move our custom nftables.conf away, install packages, then restore it. The
	# dpkg options are kept as an additional guard for future conffile changes.
	display_alert "EasePi-R2" "Installing router runtime packages" "info"
	local R2_NFT_BACKUP="${SDCARD}/tmp/easepi-r2-nftables.conf.router"
	mkdir -p "${SDCARD}/tmp"
	easepi_r2_stage_vendor_libmali
	if [[ -f "${SDCARD}/etc/nftables.conf" ]]; then
		mv "${SDCARD}/etc/nftables.conf" "${R2_NFT_BACKUP}"
	fi
	local EASEPI_R2_COMMON_RUNTIME=(
		iproute2 iputils-ping ethtool bridge-utils
		dnsmasq nftables iptables
		ppp pppoe curl ca-certificates
		wpasupplicant hostapd
		rfkill bluetooth bluez bluez-tools
		v4l-utils
	)
	local EASEPI_R2_GPU_RUNTIME=()
	if [[ "${BRANCH:-current}" == "vendor" ]]; then
		EASEPI_R2_GPU_RUNTIME=(libdrm2 libgbm1 ocl-icd-libopencl1 clinfo)
	else
		EASEPI_R2_GPU_RUNTIME=(
			libdrm2 libegl-mesa0 libgles2 libgl1-mesa-dri
			mesa-vulkan-drivers mesa-utils vulkan-tools
			kmscube glmark2-es2-drm
		)
	fi
	chroot_sdcard apt-get update || true
	chroot_sdcard apt-get install -y --no-install-recommends \
		-o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold \
		"${EASEPI_R2_COMMON_RUNTIME[@]}" \
		"${EASEPI_R2_GPU_RUNTIME[@]}" || true
	if [[ -f "${R2_NFT_BACKUP}" ]]; then
		mv "${R2_NFT_BACKUP}" "${SDCARD}/etc/nftables.conf"
	fi
	if [[ "${BRANCH:-current}" == "vendor" && "${EASEPI_R2_VENDOR_GPU_STACK}" == "libmali" && -f "${SDCARD}/tmp/easepi-r2-libmali.deb" ]]; then
		chroot_sdcard apt-get update || true
		chroot_sdcard apt-get install -y --no-install-recommends \
			-o Dpkg::Options::=--force-confdef \
			-o Dpkg::Options::=--force-confold \
			libdrm2 libgbm1 ocl-icd-libopencl1 clinfo v4l-utils ca-certificates || true
		chroot_sdcard dpkg -i /tmp/easepi-r2-libmali.deb || chroot_sdcard apt-get -f install -y
		rm -f "${SDCARD}/tmp/easepi-r2-libmali.deb"
	fi
	easepi_r2_fix_brcm_firmware_aliases
	easepi_r2_tune_vendor_bootenv
	easepi_r2_enable_vendor_hdmi_debug

	if [[ -f "${SDCARD}/etc/systemd/system/ir-keymap.service" ]]; then
		chroot_sdcard systemctl enable ir-keymap.service || true
	fi

	if [[ -f "${SDCARD}/etc/systemd/system/bluetooth-hciattach.service" ]]; then
		chroot_sdcard systemctl enable bluetooth-hciattach.service || true
	fi


	# Router base: systemd-networkd owns WAN/LAN/lte4g, dnsmasq serves br-lan DHCP, nftables does NAT.
	# Disable netplan YAML because generated /run/systemd/network/10-netplan-*.network
	# can win systemd-networkd first-match before EasePi-R2 bridge slave files.
	mkdir -p "${SDCARD}/etc/easepi-r2-router/disabled-netplan-build" "${SDCARD}/etc/easepi-r2-router/disabled-networkd-build"
	if [[ -d "${SDCARD}/etc/netplan" ]]; then
		find "${SDCARD}/etc/netplan" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -exec mv -t "${SDCARD}/etc/easepi-r2-router/disabled-netplan-build" {} + 2>/dev/null || true
	fi
	if [[ -d "${SDCARD}/etc/systemd/network" ]]; then
		for f in "${SDCARD}"/etc/systemd/network/*.network; do
			[[ -e "$f" ]] || continue
			b="$(basename "$f")"
			case "$b" in
				*easepi-r2*.network) ;;
				*) mv "$f" "${SDCARD}/etc/easepi-r2-router/disabled-networkd-build/$b" 2>/dev/null || true ;;
			esac
		done
	fi
	chroot_sdcard systemctl disable NetworkManager.service || true
	# Align RTL8125 interface names before any network manager starts.
	chroot_sdcard systemctl enable easepi-r2-eth-order.service || true
	chroot_sdcard systemctl enable systemd-networkd.service || true
	chroot_sdcard systemctl enable dnsmasq.service || true
	chroot_sdcard systemctl enable nftables.service || true
	# This service only waits for network-online and commonly times out on router
	# devices with unplugged LAN/backup-WAN ports. It is not needed for DHCP/NAT.
	chroot_sdcard systemctl disable systemd-networkd-wait-online.service || true
	chroot_sdcard systemctl mask systemd-networkd-wait-online.service || true

	chroot_sdcard systemctl enable bluetooth.service || true
}
