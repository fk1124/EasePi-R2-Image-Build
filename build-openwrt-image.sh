#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

usage() {
    cat <<USAGE
Usage:
  OPENWRT_PROFILE=rk3588-max bash build-openwrt-image.sh <24|25> current <squashfs|ext4>

Usually call this through:
  OPENWRT_PROFILE=rk3588-max bash build-image.sh openwrt <24|25> 6.18 <squashfs|ext4>

Important environment variables:
  OPENWRT_SOURCE_REF=auto              OpenWrt branch/tag to use, or auto
  OPENWRT_KERNEL_TREE=/path/to/tree    Optional external Linux 6.18 tree; use auto to search work/cache
  OPENWRT_KERNEL_VERSION=6.18          Exact kernel version label
  OPENWRT_KERNEL_HASH=<sha256>         Optional kernel tarball hash
  OPENWRT_CONFIG_ONLY=yes              Stop after OpenWrt .config generation
  EASEPI_R2_DRY_RUN=yes                Print resolved plan without cloning/building
USAGE
}

log() {
    printf '[openwrt] %s\n' "$*"
}

warn() {
    printf '[openwrt][warn] %s\n' "$*" >&2
}

die() {
    printf '[openwrt][error] %s\n' "$*" >&2
    exit 1
}

is_yes() {
    case "${1:-}" in
        1|y|Y|yes|YES|true|TRUE|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

trim_config_line() {
    local value="${1//$'\r'/}"
    value="${value%%#*}"
    printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

join_by_space() {
    local IFS=' '
    printf '%s' "$*"
}

kernel_version_suffix() {
    local version="$1"
    local patchver="$2"

    if [ "${version}" = "${patchver}" ]; then
        printf '\n'
        return 0
    fi

    printf '%s\n' "${version#${patchver}}"
}

set_make_colon_equals() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp

    [ -f "${file}" ] || die "missing Makefile: ${file}"
    tmp="${file}.tmp.$$"

    awk -v key="${key}" -v value="${value}" '
        {
            normalized = $0
            sub(/^[[:space:]]*/, "", normalized)
            split(normalized, parts, /[[:space:]]*:=[[:space:]]*/)
            if (parts[1] == key) {
                print key ":=" value
                done = 1
                next
            }
            print
        }
        END {
            if (!done) {
                print key ":=" value
            }
        }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
}

merge_kernel_config_line() {
    local config_file="$1"
    local line="$2"
    local key tmp

    case "${line}" in
        CONFIG_*=*) key="${line%%=*}" ;;
        "# CONFIG_"*" is not set") key="${line#\# }"; key="${key% is not set}" ;;
        *) return 0 ;;
    esac

    mkdir -p "$(dirname "${config_file}")"
    [ -f "${config_file}" ] || : > "${config_file}"
    tmp="${config_file}.tmp.$$"

    awk -v key="${key}" '
        index($0, key "=") == 1 { next }
        $0 == "# " key " is not set" { next }
        { print }
    ' "${config_file}" > "${tmp}"
    printf '%s\n' "${line}" >> "${tmp}"
    mv "${tmp}" "${config_file}"
}

copy_closest_versioned_file() {
    local dst="$1"
    local pattern="$2"
    local required="${3:-yes}"
    local base src

    if [ -f "${dst}" ]; then
        return 0
    fi

    base="$(dirname "${dst}")"
    mkdir -p "${base}"
    src="$(find "${base}" -maxdepth 1 -type f -name "${pattern}" 2>/dev/null | sort -V | tail -n 1 || true)"

    if [ -n "${src}" ]; then
        log "copy baseline $(basename "${src}") -> $(basename "${dst}")"
        cp "${src}" "${dst}"
        return 0
    fi

    if is_yes "${required}"; then
        die "cannot find a baseline ${pattern} under ${base}"
    fi

    : > "${dst}"
}

release_ref_candidates() {
    case "$1" in
        24)
            printf '%s\n' openwrt-24.10
            ;;
        25)
            printf '%s\n' openwrt-25.12 openwrt-25.10 openwrt-25.05
            ;;
        *)
            die "unsupported OpenWrt release: $1"
            ;;
    esac
}

remote_ref_exists() {
    local repo="$1"
    local ref="$2"

    git ls-remote --exit-code --heads "${repo}" "${ref}" >/dev/null 2>&1 ||
        git ls-remote --exit-code --tags "${repo}" "${ref}" >/dev/null 2>&1
}

latest_release_tag() {
    local repo="$1"
    local release="$2"

    git ls-remote --tags "${repo}" "refs/tags/v${release}.*" 2>/dev/null |
        awk -F/ '{print $3}' |
        sed 's/\^{}$//' |
        sort -Vu |
        tail -n 1
}

resolve_openwrt_ref() {
    local repo="$1"
    local release="$2"
    local requested="$3"
    local candidate tag

    if [ "${requested}" != "auto" ]; then
        printf '%s\n' "${requested}"
        return 0
    fi

    while IFS= read -r candidate; do
        if remote_ref_exists "${repo}" "${candidate}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done < <(release_ref_candidates "${release}")

    tag="$(latest_release_tag "${repo}" "${release}")"
    if [ -n "${tag}" ] && remote_ref_exists "${repo}" "${tag}"; then
        printf '%s\n' "${tag}"
        return 0
    fi

    warn "no release ${release} branch/tag was found; falling back to main"
    printf '%s\n' main
}

read_package_plan() {
    REQUIRED_PACKAGES=()
    OPTIONAL_PACKAGES=()
    SELECTED_PACKAGES=()

    local raw line prefix pkg
    while IFS= read -r raw || [ -n "${raw}" ]; do
        line="$(trim_config_line "${raw}")"
        [ -n "${line}" ] || continue

        prefix="${line:0:1}"
        case "${prefix}" in
            !)
                pkg="${line:1}"
                REQUIRED_PACKAGES+=("${pkg}")
                SELECTED_PACKAGES+=("${pkg}")
                ;;
            ?)
                pkg="${line:1}"
                OPTIONAL_PACKAGES+=("${pkg}")
                SELECTED_PACKAGES+=("${pkg}")
                ;;
            *)
                pkg="${line}"
                REQUIRED_PACKAGES+=("${pkg}")
                SELECTED_PACKAGES+=("${pkg}")
                ;;
        esac
    done < "${PACKAGE_FILE}"
}

validate_profile() {
    case " ${OPENWRT_RELEASES:-} " in
        *" ${RELEASE} "*) ;;
        *) die "profile ${OPENWRT_PROFILE} does not support OpenWrt ${RELEASE}" ;;
    esac

    case " ${OPENWRT_IMAGE_TYPES:-} " in
        *" ${IMAGE_TYPE} "*) ;;
        *) die "profile ${OPENWRT_PROFILE} does not support image type ${IMAGE_TYPE}" ;;
    esac

    case "${KERNEL_PROFILE}" in
        current|6.18|6.18.*) ;;
        *) die "OpenWrt adapter only supports the custom 6.18/current kernel profile" ;;
    esac

    [ -f "${PACKAGE_FILE}" ] || die "missing package list: ${PACKAGE_FILE}"
    [ -f "${KERNEL_FRAGMENT}" ] || die "missing kernel fragment: ${KERNEL_FRAGMENT}"
    [ -d "${DTS_SOURCE_DIR}" ] || die "missing EasePi R2 DTS directory: ${DTS_SOURCE_DIR}"
}

parse_target() {
    TARGET_ROOT="${OPENWRT_DEVICE_TARGET%%/*}"
    TARGET_SUBTARGET="${OPENWRT_DEVICE_TARGET#*/}"

    [ -n "${TARGET_ROOT}" ] || die "invalid OPENWRT_DEVICE_TARGET: ${OPENWRT_DEVICE_TARGET}"
    [ "${TARGET_ROOT}" != "${OPENWRT_DEVICE_TARGET}" ] || die "OPENWRT_DEVICE_TARGET must look like rockchip/armv8"
    [ -n "${TARGET_SUBTARGET}" ] || die "invalid OPENWRT_DEVICE_TARGET: ${OPENWRT_DEVICE_TARGET}"
}

prepare_source_tree() {
    mkdir -p "${OPENWRT_WORK_DIR}"

    if [ -d "${OPENWRT_SOURCE_DIR}/.git" ]; then
        log "reuse OpenWrt tree: ${OPENWRT_SOURCE_DIR}"
        git -C "${OPENWRT_SOURCE_DIR}" remote set-url origin "${OPENWRT_SOURCE_REPO}" || true
    else
        log "clone OpenWrt source: ${OPENWRT_SOURCE_REPO}"
        git clone --depth "${OPENWRT_GIT_DEPTH}" "${OPENWRT_SOURCE_REPO}" "${OPENWRT_SOURCE_DIR}"
    fi

    if ! is_yes "${OPENWRT_SKIP_SOURCE_UPDATE}"; then
        log "checkout OpenWrt ref: ${RESOLVED_OPENWRT_REF}"
        git -C "${OPENWRT_SOURCE_DIR}" fetch --depth "${OPENWRT_GIT_DEPTH}" origin "${RESOLVED_OPENWRT_REF}" ||
            git -C "${OPENWRT_SOURCE_DIR}" fetch origin "${RESOLVED_OPENWRT_REF}"
        git -C "${OPENWRT_SOURCE_DIR}" checkout -B "easepi-r2-openwrt-${RELEASE}-${OPENWRT_KERNEL_PATCHVER}" FETCH_HEAD
    else
        log "OPENWRT_SKIP_SOURCE_UPDATE=yes, keeping current source checkout"
    fi
}

locate_kernel_tree() {
    EFFECTIVE_KERNEL_TREE=""

    if [ -n "${OPENWRT_KERNEL_TREE}" ] && [ "${OPENWRT_KERNEL_TREE}" != "auto" ]; then
        EFFECTIVE_KERNEL_TREE="${OPENWRT_KERNEL_TREE}"
    elif [ "${OPENWRT_KERNEL_TREE}" = "auto" ]; then
        local candidate
        for candidate in \
            "${REPO_DIR}/work/linux-${OPENWRT_KERNEL_VERSION}" \
            "${REPO_DIR}/work/linux-${OPENWRT_KERNEL_PATCHVER}" \
            "${REPO_DIR}/work/kernel/linux-${OPENWRT_KERNEL_VERSION}" \
            "${REPO_DIR}/work/kernel/linux-${OPENWRT_KERNEL_PATCHVER}" \
            "${REPO_DIR}/cache/sources/linux-kernel-worktree/${OPENWRT_KERNEL_PATCHVER}"* \
            "${REPO_DIR}/work/armbian-build/cache/sources/linux-kernel-worktree/${OPENWRT_KERNEL_PATCHVER}"* \
            "${REPO_DIR}/../build/cache/sources/linux-kernel-worktree/${OPENWRT_KERNEL_PATCHVER}"* \
            "${REPO_DIR}/../armbian-build/cache/sources/linux-kernel-worktree/${OPENWRT_KERNEL_PATCHVER}"*
        do
            if [ -f "${candidate}/Makefile" ] && [ -d "${candidate}/arch/arm64/boot/dts/rockchip" ]; then
                EFFECTIVE_KERNEL_TREE="${candidate}"
                break
            fi
        done
    fi

    if [ -n "${EFFECTIVE_KERNEL_TREE}" ]; then
        [ -f "${EFFECTIVE_KERNEL_TREE}/Makefile" ] || die "OPENWRT_KERNEL_TREE is not a kernel tree: ${EFFECTIVE_KERNEL_TREE}"
        validate_kernel_tree "${EFFECTIVE_KERNEL_TREE}"
        log "external kernel tree: ${EFFECTIVE_KERNEL_TREE}"
        return 0
    fi

    log "external kernel tree not used; OpenWrt will download Linux ${OPENWRT_KERNEL_VERSION}"
}

validate_kernel_tree() {
    local tree="$1"
    local version patchlevel sublevel series exact

    version="$(awk -F= '/^VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "${tree}/Makefile")"
    patchlevel="$(awk -F= '/^PATCHLEVEL[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "${tree}/Makefile")"
    sublevel="$(awk -F= '/^SUBLEVEL[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "${tree}/Makefile")"
    sublevel="${sublevel:-0}"
    series="${version}.${patchlevel}"
    exact="${version}.${patchlevel}.${sublevel}"
    DETECTED_KERNEL_VERSION="${exact}"

    if [ "${series}" != "${OPENWRT_KERNEL_PATCHVER}" ]; then
        if is_yes "${OPENWRT_ALLOW_KERNEL_MISMATCH}"; then
            warn "kernel tree reports ${exact}, expected ${OPENWRT_KERNEL_PATCHVER}.x"
        else
            die "kernel tree reports ${exact}, expected ${OPENWRT_KERNEL_PATCHVER}.x; set OPENWRT_ALLOW_KERNEL_MISMATCH=yes to override"
        fi
    fi
}

patch_kernel_line() {
    local include_file="${OPENWRT_SOURCE_DIR}/include/kernel-${OPENWRT_KERNEL_PATCHVER}"
    local generic_include_file="${OPENWRT_SOURCE_DIR}/target/linux/generic/kernel-${OPENWRT_KERNEL_PATCHVER}"
    local suffix

    case "${OPENWRT_KERNEL_VERSION}" in
        "${OPENWRT_KERNEL_PATCHVER}"|"${OPENWRT_KERNEL_PATCHVER}".*) ;;
        *) die "OPENWRT_KERNEL_VERSION=${OPENWRT_KERNEL_VERSION} does not match ${OPENWRT_KERNEL_PATCHVER}.x" ;;
    esac

    suffix="$(kernel_version_suffix "${OPENWRT_KERNEL_VERSION}" "${OPENWRT_KERNEL_PATCHVER}")"
    write_kernel_details "${include_file}" "${suffix}"
    write_kernel_details "${generic_include_file}" "${suffix}"

    set_make_colon_equals "${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/Makefile" "KERNEL_PATCHVER" "${OPENWRT_KERNEL_PATCHVER}"

    if grep -q '^KERNEL_TESTING_PATCHVER[[:space:]]*:=' "${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/Makefile"; then
        set_make_colon_equals "${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/Makefile" "KERNEL_TESTING_PATCHVER" "${OPENWRT_KERNEL_PATCHVER}"
    fi
}

write_kernel_details() {
    local file="$1"
    local suffix="$2"
    local hash="${OPENWRT_KERNEL_HASH:-x}"

    mkdir -p "$(dirname "${file}")"
    {
        printf 'LINUX_VERSION-%s = %s\n' "${OPENWRT_KERNEL_PATCHVER}" "${suffix}"
        printf 'LINUX_KERNEL_HASH-%s = %s\n' "${OPENWRT_KERNEL_VERSION}" "${hash}"
    } > "${file}"
}

copy_dts_files() {
    local overlay_dir versioned_overlay_dir kernel_dts_dir dt_makefile file

    overlay_dir="${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/files/arch/arm64/boot/dts/rockchip"
    versioned_overlay_dir="${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/files-${OPENWRT_KERNEL_PATCHVER}/arch/arm64/boot/dts/rockchip"
    mkdir -p "${overlay_dir}" "${versioned_overlay_dir}"

    shopt -s nullglob
    for file in "${DTS_SOURCE_DIR}"/*.dts "${DTS_SOURCE_DIR}"/*.dtsi; do
        cp -f "${file}" "${overlay_dir}/"
        cp -f "${file}" "${versioned_overlay_dir}/"
    done
    shopt -u nullglob

    if [ -n "${EFFECTIVE_KERNEL_TREE}" ]; then
        kernel_dts_dir="${EFFECTIVE_KERNEL_TREE}/arch/arm64/boot/dts/rockchip"
        dt_makefile="${kernel_dts_dir}/Makefile"
        mkdir -p "${kernel_dts_dir}"

        shopt -s nullglob
        for file in "${DTS_SOURCE_DIR}"/*.dts "${DTS_SOURCE_DIR}"/*.dtsi; do
            cp -f "${file}" "${kernel_dts_dir}/"
        done
        shopt -u nullglob

        if [ -f "${dt_makefile}" ] && ! grep -q "${OPENWRT_DTS_NAME}.dtb" "${dt_makefile}"; then
            printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += %s.dtb\n' "${OPENWRT_DTS_NAME}" >> "${dt_makefile}"
        fi
    fi
}

append_device_profile() {
    local image_mk="${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/image/${TARGET_SUBTARGET}.mk"
    local dts_ref device_packages device_macro

    [ -f "${image_mk}" ] || die "missing OpenWrt image profile file: ${image_mk}"

    if grep -q "Device/${OPENWRT_DEVICE_PROFILE}" "${image_mk}"; then
        log "device profile already present: ${OPENWRT_DEVICE_PROFILE}"
        return 0
    fi

    if grep -q 'DEVICE_DTS_DIR' "${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/image/Makefile"; then
        dts_ref="${OPENWRT_DTS_NAME}"
    elif grep -Eq 'DEVICE_DTS[[:space:]]*:= rockchip/' "${image_mk}"; then
        dts_ref="rockchip/${OPENWRT_DTS_NAME}"
    else
        dts_ref="${OPENWRT_DTS_NAME}"
    fi

    device_packages="${OPENWRT_DEVICE_PACKAGES:-blkdiscard block-mount kmod-button-hotplug kmod-nvme kmod-r8169 kmod-usb3 kmod-usb-storage-uas}"
    device_macro=""
    if grep -q '^define Device/rk3588$' "${image_mk}"; then
        device_macro='  $(Device/rk3588)'
    fi

    cat >> "${image_mk}" <<EOF

define Device/${OPENWRT_DEVICE_PROFILE}
${device_macro}
  DEVICE_VENDOR := LinkEase
  DEVICE_MODEL := EasePi R2
  SOC := rk3588
  DEVICE_DTS := ${dts_ref}
  UBOOT_DEVICE_NAME := ${OPENWRT_UBOOT_DEVICE_NAME}
  SUPPORTED_DEVICES := linkease,easepi-r2 ${OPENWRT_DTS_NAME}
  DEVICE_PACKAGES := ${device_packages}
endef
TARGET_DEVICES += ${OPENWRT_DEVICE_PROFILE}
EOF
}

append_uboot_profile() {
    local uboot_mk="${OPENWRT_SOURCE_DIR}/package/boot/uboot-rockchip/Makefile"
    local rk_default

    [ -f "${uboot_mk}" ] || {
        warn "missing uboot-rockchip Makefile, skipping U-Boot profile injection"
        return 0
    }

    if grep -q "U-Boot/${OPENWRT_UBOOT_DEVICE_NAME}" "${uboot_mk}"; then
        log "U-Boot profile already present: ${OPENWRT_UBOOT_DEVICE_NAME}"
        return 0
    fi

    if grep -q 'define U-Boot/rk358x/Default' "${uboot_mk}"; then
        rk_default='$(U-Boot/rk358x/Default)'
    else
        rk_default='$(U-Boot/rk3588/Default)'
    fi

    cat >> "${uboot_mk}" <<EOF

define U-Boot/${OPENWRT_UBOOT_DEVICE_NAME}
  ${rk_default}
  NAME:=LinkEase EasePi R2
  BUILD_DEVICES:= \\
    ${OPENWRT_DEVICE_PROFILE}
endef
UBOOT_TARGETS += ${OPENWRT_UBOOT_DEVICE_NAME}
EOF
}

merge_kernel_fragment() {
    local target_config="${OPENWRT_SOURCE_DIR}/target/linux/${TARGET_ROOT}/${TARGET_SUBTARGET}/config-${OPENWRT_KERNEL_PATCHVER}"
    local generic_config="${OPENWRT_SOURCE_DIR}/target/linux/generic/config-${OPENWRT_KERNEL_PATCHVER}"
    local raw line

    copy_closest_versioned_file "${target_config}" "config-*" yes
    copy_closest_versioned_file "${generic_config}" "config-*" yes
    mkdir -p \
        "${OPENWRT_SOURCE_DIR}/target/linux/generic/backport-${OPENWRT_KERNEL_PATCHVER}" \
        "${OPENWRT_SOURCE_DIR}/target/linux/generic/hack-${OPENWRT_KERNEL_PATCHVER}" \
        "${OPENWRT_SOURCE_DIR}/target/linux/generic/pending-${OPENWRT_KERNEL_PATCHVER}"

    while IFS= read -r raw || [ -n "${raw}" ]; do
        line="$(trim_config_line "${raw}")"
        [ -n "${line}" ] || continue
        merge_kernel_config_line "${target_config}" "${line}"
    done < "${KERNEL_FRAGMENT}"
}

emit_kernel_fragment_to_openwrt_config() {
    local raw line key value

    while IFS= read -r raw || [ -n "${raw}" ]; do
        line="$(trim_config_line "${raw}")"
        [ -n "${line}" ] || continue

        case "${line}" in
            CONFIG_*=*)
                key="${line%%=*}"
                value="${line#*=}"
                printf 'CONFIG_KERNEL_%s=%s\n' "${key#CONFIG_}" "${value}"
                ;;
        esac
    done < "${KERNEL_FRAGMENT}"
}

write_openwrt_config() {
    local config_file="${OPENWRT_SOURCE_DIR}/.config"
    local pkg rootfs_partsize

    rootfs_partsize="${OPENWRT_ROOTFS_PARTSIZE_MB}"

    {
        printf 'CONFIG_TARGET_%s=y\n' "${TARGET_ROOT}"
        printf 'CONFIG_TARGET_%s_%s=y\n' "${TARGET_ROOT}" "${TARGET_SUBTARGET}"
        printf 'CONFIG_TARGET_%s_%s_DEVICE_%s=y\n' "${TARGET_ROOT}" "${TARGET_SUBTARGET}" "${OPENWRT_DEVICE_PROFILE}"
        printf 'CONFIG_TARGET_ROOTFS_PARTSIZE=%s\n' "${rootfs_partsize}"

        case "${IMAGE_TYPE}" in
            ext4)
                printf 'CONFIG_TARGET_ROOTFS_EXT4FS=y\n'
                printf '# CONFIG_TARGET_ROOTFS_SQUASHFS is not set\n'
                ;;
            squashfs)
                printf 'CONFIG_TARGET_ROOTFS_SQUASHFS=y\n'
                printf '# CONFIG_TARGET_ROOTFS_EXT4FS is not set\n'
                ;;
        esac

        printf 'CONFIG_DEVEL=y\n'
        printf 'CONFIG_CCACHE=y\n'
        printf 'CONFIG_BUILD_LOG=y\n'
        printf 'CONFIG_KERNEL_BUILD_USER="easepi-r2"\n'
        printf 'CONFIG_KERNEL_BUILD_DOMAIN="local"\n'
        printf 'CONFIG_KERNEL_LOCALVERSION="%s"\n' "${OPENWRT_KERNEL_LOCALVERSION}"
        printf 'CONFIG_KERNEL_KALLSYMS=y\n'
        printf 'CONFIG_KERNEL_DEBUG_FS=y\n'
        printf 'CONFIG_KERNEL_PERF_EVENTS=y\n'
        printf 'CONFIG_KERNEL_PROFILING=y\n'

        if [ -n "${EFFECTIVE_KERNEL_TREE}" ]; then
            printf 'CONFIG_EXTERNAL_KERNEL_TREE="%s"\n' "${EFFECTIVE_KERNEL_TREE}"
        fi

        if is_yes "${OPENWRT_BUILD_ALL_KMODS}"; then
            printf 'CONFIG_ALL_KMODS=y\n'
        fi

        if is_yes "${OPENWRT_BUILD_UBOOT}"; then
            printf 'CONFIG_PACKAGE_u-boot-%s=y\n' "${OPENWRT_UBOOT_DEVICE_NAME}"
        fi

        emit_kernel_fragment_to_openwrt_config

        for pkg in "${SELECTED_PACKAGES[@]}"; do
            [ -n "${pkg}" ] || continue
            printf 'CONFIG_PACKAGE_%s=y\n' "${pkg}"
        done
    } > "${config_file}"

    log "wrote OpenWrt seed config: ${config_file}"
}

run_feeds() {
    cd "${OPENWRT_SOURCE_DIR}"

    if is_yes "${OPENWRT_FEEDS_UPDATE}"; then
        log "update OpenWrt feeds"
        ./scripts/feeds update -a
    fi

    log "install OpenWrt feeds"
    ./scripts/feeds install -a
}

defconfig_and_check_packages() {
    local missing=()
    local pkg

    cd "${OPENWRT_SOURCE_DIR}"
    log "make defconfig"
    make defconfig

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        [ -n "${pkg}" ] || continue
        if ! grep -q "^CONFIG_PACKAGE_${pkg}=y" .config; then
            missing+=("${pkg}")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        warn "required packages not selected after defconfig: $(join_by_space "${missing[@]}")"
        warn "set OPENWRT_STRICT_REQUIRED_PACKAGES=yes to turn this warning into an error"
        if is_yes "${OPENWRT_STRICT_REQUIRED_PACKAGES}"; then
            exit 1
        fi
    fi
}

build_openwrt() {
    local make_extra=()

    cd "${OPENWRT_SOURCE_DIR}"
    [ -z "${OPENWRT_MAKE_VERBOSE}" ] || make_extra+=("V=${OPENWRT_MAKE_VERBOSE}")

    if is_yes "${OPENWRT_CONFIG_ONLY}"; then
        log "OPENWRT_CONFIG_ONLY=yes, stopping after defconfig"
        return 0
    fi

    if is_yes "${OPENWRT_DOWNLOAD_FIRST}"; then
        log "make download"
        make -j"${OPENWRT_JOBS}" "${make_extra[@]}" download
    fi

    log "make ${OPENWRT_MAKE_TARGET}"
    make -j"${OPENWRT_JOBS}" "${make_extra[@]}" "${OPENWRT_MAKE_TARGET}"
}

collect_outputs() {
    local target_bin="${OPENWRT_SOURCE_DIR}/bin/targets/${TARGET_ROOT}/${TARGET_SUBTARGET}"
    local dest_dir="${REPO_DIR}/output/images/${IMAGE_NAME}"

    if is_yes "${OPENWRT_CONFIG_ONLY}"; then
        return 0
    fi

    [ -d "${target_bin}" ] || die "OpenWrt build finished without target output directory: ${target_bin}"
    mkdir -p "${dest_dir}"
    cp -a "${target_bin}/." "${dest_dir}/"
    cp -f "${OPENWRT_SOURCE_DIR}/.config" "${dest_dir}/config.seed"
    cp -f "${PACKAGE_FILE}" "${dest_dir}/packages.rk3588-max.txt"
    cp -f "${KERNEL_FRAGMENT}" "${dest_dir}/kernel.rk3588-max.fragment"

    if is_yes "${OPENWRT_LOCAL_KMOD_FEED}" && [ -d "${OPENWRT_SOURCE_DIR}/bin/packages" ]; then
        mkdir -p "${dest_dir}/packages"
        cp -a "${OPENWRT_SOURCE_DIR}/bin/packages/." "${dest_dir}/packages/"
    fi

    log "artifacts copied to: ${dest_dir}"
    find "${dest_dir}" -maxdepth 1 -type f -print
}

print_plan() {
    cat <<PLAN
[openwrt] plan
  release:          ${RELEASE}
  image_type:       ${IMAGE_TYPE}
  profile:          ${OPENWRT_PROFILE}
  target:           ${OPENWRT_DEVICE_TARGET}
  device:           ${OPENWRT_DEVICE_PROFILE}
  dts:              ${OPENWRT_DTS_NAME}
  openwrt repo:     ${OPENWRT_SOURCE_REPO}
  openwrt ref:      ${RESOLVED_OPENWRT_REF:-${OPENWRT_SOURCE_REF}}
  source dir:       ${OPENWRT_SOURCE_DIR}
  kernel patchver:  ${OPENWRT_KERNEL_PATCHVER}
  kernel version:   ${OPENWRT_KERNEL_VERSION}
  kernel tree:      ${EFFECTIVE_KERNEL_TREE:-${OPENWRT_KERNEL_TREE:-download}}
  kmod strategy:    ${OPENWRT_KMOD_STRATEGY}
  build all kmods:  ${OPENWRT_BUILD_ALL_KMODS}
  packages:         ${#REQUIRED_PACKAGES[@]} required, ${#OPTIONAL_PACKAGES[@]} optional
  jobs:             ${OPENWRT_JOBS}
PLAN
}

RELEASE="${1:-}"
KERNEL_PROFILE="${2:-}"
IMAGE_TYPE="${3:-}"

case "${RELEASE}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

[ -n "${RELEASE}" ] || die "missing release"
[ -n "${KERNEL_PROFILE}" ] || die "missing kernel profile"
[ -n "${IMAGE_TYPE}" ] || die "missing image type"

case "${RELEASE}" in
    24|25) ;;
    *) die "unsupported OpenWrt release: ${RELEASE}" ;;
esac

case "${IMAGE_TYPE}" in
    squashfs|ext4) ;;
    *) die "unsupported OpenWrt image type: ${IMAGE_TYPE}" ;;
esac

OPENWRT_PROFILE="${OPENWRT_PROFILE:-rk3588-max}"
PROFILE_FILE="${REPO_DIR}/rootfs/openwrt/profiles/${OPENWRT_PROFILE}.env"
[ -f "${PROFILE_FILE}" ] || die "missing OpenWrt profile: ${PROFILE_FILE}"
# shellcheck disable=SC1090
. "${PROFILE_FILE}"

OPENWRT_PROFILE_ID="${OPENWRT_PROFILE_ID:-${OPENWRT_PROFILE}}"
OPENWRT_SOURCE_REPO="${OPENWRT_SOURCE_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_SOURCE_REF="${OPENWRT_SOURCE_REF:-auto}"
OPENWRT_GIT_DEPTH="${OPENWRT_GIT_DEPTH:-1}"
OPENWRT_WORK_DIR="${OPENWRT_WORK_DIR:-${REPO_DIR}/work/openwrt}"
OPENWRT_SOURCE_DIR="${OPENWRT_SOURCE_DIR:-${OPENWRT_WORK_DIR}/openwrt-${RELEASE}}"
OPENWRT_KERNEL_PATCHVER="${OPENWRT_KERNEL_PATCHVER:-${OPENWRT_KERNEL_SERIES:-6.18}}"
OPENWRT_KERNEL_VERSION_USER_SET="${OPENWRT_KERNEL_VERSION+x}"
OPENWRT_KERNEL_VERSION="${OPENWRT_KERNEL_VERSION:-${OPENWRT_KERNEL_PATCHVER}}"
OPENWRT_KERNEL_HASH="${OPENWRT_KERNEL_HASH:-}"
OPENWRT_KERNEL_TREE="${OPENWRT_KERNEL_TREE:-}"
OPENWRT_KERNEL_LOCALVERSION="${OPENWRT_KERNEL_LOCALVERSION:-${OPENWRT_KERNEL_LOCALVERSION_DEFAULT:--easepi-r2}}"
OPENWRT_UBOOT_DEVICE_NAME="${OPENWRT_UBOOT_DEVICE_NAME:-easepi-r2-rk3588}"
OPENWRT_BUILD_UBOOT="${OPENWRT_BUILD_UBOOT:-yes}"
OPENWRT_KMOD_STRATEGY="${OPENWRT_KMOD_STRATEGY:-${OPENWRT_KMOD_STRATEGY_DEFAULT:-build-all-preinstall-max}}"
OPENWRT_BUILD_ALL_KMODS="${OPENWRT_BUILD_ALL_KMODS:-${OPENWRT_BUILD_ALL_KMODS_DEFAULT:-yes}}"
OPENWRT_LOCAL_KMOD_FEED="${OPENWRT_LOCAL_KMOD_FEED:-${OPENWRT_LOCAL_KMOD_FEED_DEFAULT:-yes}}"
OPENWRT_PREINSTALL_MODE="${OPENWRT_PREINSTALL_MODE:-${OPENWRT_PREINSTALL_MODE_DEFAULT:-max}}"
OPENWRT_SKIP_SOURCE_UPDATE="${OPENWRT_SKIP_SOURCE_UPDATE:-no}"
OPENWRT_FEEDS_UPDATE="${OPENWRT_FEEDS_UPDATE:-yes}"
OPENWRT_DOWNLOAD_FIRST="${OPENWRT_DOWNLOAD_FIRST:-yes}"
OPENWRT_CONFIG_ONLY="${OPENWRT_CONFIG_ONLY:-no}"
OPENWRT_STRICT_REQUIRED_PACKAGES="${OPENWRT_STRICT_REQUIRED_PACKAGES:-no}"
OPENWRT_MAKE_TARGET="${OPENWRT_MAKE_TARGET:-world}"
OPENWRT_MAKE_VERBOSE="${OPENWRT_MAKE_VERBOSE:-}"
OPENWRT_ALLOW_KERNEL_MISMATCH="${OPENWRT_ALLOW_KERNEL_MISMATCH:-no}"
OPENWRT_DTS_SOURCE_DIR="${OPENWRT_DTS_SOURCE_DIR:-${REPO_DIR}/userpatches/kernel/archive/rockchip64-${OPENWRT_KERNEL_PATCHVER}/dt}"
DTS_SOURCE_DIR="${OPENWRT_DTS_SOURCE_DIR}"

if command -v nproc >/dev/null 2>&1; then
    DEFAULT_OPENWRT_JOBS="$(nproc)"
else
    DEFAULT_OPENWRT_JOBS=4
fi
OPENWRT_JOBS="${OPENWRT_JOBS:-${DEFAULT_OPENWRT_JOBS}}"

    case "${IMAGE_TYPE}" in
        ext4) OPENWRT_ROOTFS_PARTSIZE_MB="${OPENWRT_ROOTFS_PARTSIZE_MB:-8192}" ;;
        squashfs) OPENWRT_ROOTFS_PARTSIZE_MB="${OPENWRT_ROOTFS_PARTSIZE_MB:-1024}" ;;
    esac

PACKAGE_FILE="${REPO_DIR}/${OPENWRT_PACKAGE_LIST}"
KERNEL_FRAGMENT="${REPO_DIR}/${OPENWRT_KERNEL_FRAGMENT}"
IMAGE_NAME="EasePi-R2-openwrt-${RELEASE}-${OPENWRT_KERNEL_PATCHVER}-${OPENWRT_PROFILE}-${IMAGE_TYPE}"

validate_profile
parse_target
read_package_plan

if is_yes "${EASEPI_R2_DRY_RUN:-no}"; then
    RESOLVED_OPENWRT_REF="${OPENWRT_SOURCE_REF}"
    EFFECTIVE_KERNEL_TREE=""
    print_plan
    exit 0
fi

RESOLVED_OPENWRT_REF="$(resolve_openwrt_ref "${OPENWRT_SOURCE_REPO}" "${RELEASE}" "${OPENWRT_SOURCE_REF}")"
locate_kernel_tree
if [ -z "${OPENWRT_KERNEL_VERSION_USER_SET}" ] && [ -n "${DETECTED_KERNEL_VERSION:-}" ]; then
    OPENWRT_KERNEL_VERSION="${DETECTED_KERNEL_VERSION}"
fi
print_plan

prepare_source_tree
run_feeds
patch_kernel_line
copy_dts_files
append_device_profile
append_uboot_profile
merge_kernel_fragment
write_openwrt_config
defconfig_and_check_packages
build_openwrt
collect_outputs

log "done: ${IMAGE_NAME}"
