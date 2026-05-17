#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="${1:-}"

if [ -z "${ROOTFS_DIR}" ]; then
    echo "ERROR: missing rootfs directory." >&2
    echo "Usage: bash scripts/write-build-time-seed.sh /path/to/rootfs" >&2
    exit 1
fi

if [ -z "${SUDO:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
    fi
fi

if [ ! -d "${ROOTFS_DIR}" ]; then
    echo "ERROR: rootfs directory not found: ${ROOTFS_DIR}" >&2
    exit 1
fi

build_epoch="${EASEPI_R2_BUILD_EPOCH:-$(date -u +%s)}"
build_utc="$(date -u -d "@${build_epoch}" '+%Y-%m-%d %H:%M:%S UTC')"
build_local="$(TZ="${EASEPI_R2_BUILD_TZ:-Asia/Shanghai}" date -d "@${build_epoch}" '+%Y-%m-%d %H:%M:%S %Z')"

${SUDO} mkdir -p \
    "${ROOTFS_DIR}/etc" \
    "${ROOTFS_DIR}/usr/local/sbin" \
    "${ROOTFS_DIR}/etc/systemd/system/sysinit.target.wants" \
    "${ROOTFS_DIR}/var/lib/systemd/timesync"

${SUDO} tee "${ROOTFS_DIR}/etc/easepi-r2-build-time" >/dev/null <<EOF_BUILD_TIME
BUILD_EPOCH_UTC=${build_epoch}
BUILD_TIME_UTC=${build_utc}
BUILD_TIME_LOCAL=${build_local}
EOF_BUILD_TIME

${SUDO} tee "${ROOTFS_DIR}/etc/fake-hwclock.data" >/dev/null <<EOF_FAKE_HWCLOCK
$(date -u -d "@${build_epoch}" '+%Y-%m-%d %H:%M:%S')
EOF_FAKE_HWCLOCK

${SUDO} touch -d "@${build_epoch}" "${ROOTFS_DIR}/var/lib/systemd/timesync/clock" 2>/dev/null || true

${SUDO} tee "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-seed-clock" >/dev/null <<'EOF_SEED_CLOCK'
#!/usr/bin/env bash
set -euo pipefail

seed_file="/etc/easepi-r2-build-time"
[ -f "${seed_file}" ] || exit 0

build_epoch="$(awk -F= '$1 == "BUILD_EPOCH_UTC" { print $2 }' "${seed_file}" | tr -cd '0-9' | head -c 16)"
[ -n "${build_epoch}" ] || exit 0

now_epoch="$(date -u +%s 2>/dev/null || printf '0')"
case "${now_epoch}" in
    ''|*[!0-9]*) now_epoch=0 ;;
esac

if [ "${now_epoch}" -lt "${build_epoch}" ]; then
    date -u -s "@${build_epoch}" >/dev/null 2>&1 || exit 0
    logger -t easepi-r2-seed-clock "system clock seeded from image build time: ${build_epoch}" 2>/dev/null || true
fi

mkdir -p /var/lib/systemd/timesync
touch -d "@${build_epoch}" /var/lib/systemd/timesync/clock 2>/dev/null || true
EOF_SEED_CLOCK

${SUDO} chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/easepi-r2-seed-clock"

${SUDO} tee "${ROOTFS_DIR}/etc/systemd/system/easepi-r2-seed-clock.service" >/dev/null <<'EOF_SEED_CLOCK_SERVICE'
[Unit]
Description=Seed system clock from EasePi-R2 image build time
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target time-set.target time-sync.target systemd-timesyncd.service chrony.service chronyd.service ntp.service
ConditionPathExists=/etc/easepi-r2-build-time

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easepi-r2-seed-clock

[Install]
WantedBy=sysinit.target
EOF_SEED_CLOCK_SERVICE

${SUDO} ln -sfn ../easepi-r2-seed-clock.service \
    "${ROOTFS_DIR}/etc/systemd/system/sysinit.target.wants/easepi-r2-seed-clock.service"

printf 'EasePi-R2 build time seed: %s\n' "${build_utc}"
