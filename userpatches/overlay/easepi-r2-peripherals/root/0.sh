#!/usr/bin/env bash
# 0.sh - install EasePi-R2 systemd-networkd router manager
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请用 root 执行：sudo bash 0.sh"
  exit 1
fi

install -d /usr/local/sbin /etc/systemd/system /etc/systemd/network

cat > /usr/local/sbin/easepi-r2-eth-order <<'ETH_ORDER'
#!/usr/bin/env bash
# Align EasePi-R2 physical port order to kernel interface names without relying
# on systemd-networkd/NetworkManager.  It reads /proc/device-tree/eth_order and
# matches each NIC by its stable PCIe root bus/root port path.  Do not rely on
# the kernel's initial ethX order or on endpoint bus numbers such as 41/21/11/31;
# those can differ between cold boot and warm reboot.
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
DEFAULT_ORDER="0004:40,0002:20,0001:10,0003:30"
TMP_PREFIX="r2tmp"
LOG_TAG="easepi-r2-eth-order"
WAIT_TIMEOUT="${EASEPI_R2_ETH_ORDER_WAIT_TIMEOUT:-15}"
WAIT_INTERVAL="${EASEPI_R2_ETH_ORDER_WAIT_INTERVAL:-1}"
SELECTORS=()

log() {
  echo "[$LOG_TAG] $*"
  command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" -- "$*" || true
}

read_order() {
  local order=""
  if [ -r /proc/device-tree/eth_order ]; then
    order="$(tr -d '\000' < /proc/device-tree/eth_order 2>/dev/null | tr -d '[:space:]')"
  fi
  [ -n "$order" ] || order="$DEFAULT_ORDER"
  printf '%s\n' "$order"
}

normalize_selector() {
  local selector="$1" domain bus rest bus_dec root_bus

  # New format: domain:root-bus, e.g. 0004:40.
  case "$selector" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])
      printf '%s\n' "$selector"
      return 0
      ;;
  esac

  # Backward compatibility for old DTBs that used endpoint BDFs such as
  # 0004:41:00.0.  On this board the RTL8125 endpoint sits one bus below the
  # root port, so root-bus = endpoint-bus - 1.
  case "$selector" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:*)
      domain="${selector%%:*}"
      rest="${selector#*:}"
      bus="${rest%%:*}"
      bus_dec=$((16#$bus))
      if [ "$bus_dec" -gt 0 ]; then
        root_bus="$(printf '%02x' $((bus_dec - 1)))"
        printf '%s:%s\n' "$domain" "$root_bus"
        return 0
      fi
      ;;
  esac

  printf '%s\n' "$selector"
}

selector_matches_path() {
  local selector="$1" devpath="$2"
  case "$devpath" in
    *"/pci${selector}/"*|*"/${selector}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

iface_for_selector() {
  local selector="$1" p i dev
  for p in /sys/class/net/*; do
    [ -e "$p" ] || continue
    i="${p##*/}"
    [ "$i" = "lo" ] && continue
    dev="$(readlink -f "$p/device" 2>/dev/null || true)"
    if selector_matches_path "$selector" "$dev"; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

selector_for_iface() {
  local iface="$1" selector dev
  dev="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
  [ -n "$dev" ] || return 1
  for selector in "${SELECTORS[@]}"; do
    if selector_matches_path "$selector" "$dev"; then
      printf '%s\n' "$selector"
      return 0
    fi
  done
  return 1
}

iface_exists() {
  [ -e "/sys/class/net/$1" ]
}

unique_iface_name() {
  local base="$1" name="$1" n=0
  while iface_exists "$name"; do
    n=$((n + 1))
    name="${base}${n}"
  done
  printf '%s\n' "$name"
}

rename_iface() {
  local old="$1" new="$2"
  [ -n "$old" ] && [ -n "$new" ] || return 1
  [ "$old" = "$new" ] && return 0
  iface_exists "$old" || { log "skip: $old not found while renaming to $new"; return 1; }

  log "rename $old -> $new"
  ip link set dev "$old" down 2>/dev/null || true
  ip link set dev "$old" name "$new"
}

report_alignment() {
  local i selector target cur dev
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ -n "$cur" ]; then
      dev="$(readlink -f "/sys/class/net/$cur/device" 2>/dev/null || echo unknown)"
      log "$selector -> $cur (target $target, path $dev)"
    else
      log "$selector -> missing (target $target)"
    fi
  done
}

wait_for_all_devices() {
  local deadline missing i selector cur
  deadline=$((SECONDS + WAIT_TIMEOUT))

  while :; do
    missing=""
    for i in 0 1 2 3; do
      selector="${SELECTORS[$i]}"
      cur="$(iface_for_selector "$selector" || true)"
      [ -n "$cur" ] || missing="${missing}${missing:+ }$selector"
    done

    if [ -z "$missing" ]; then
      log "all target RTL8125 interfaces are present"
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      log "timeout waiting for target interfaces; missing: $missing"
      report_alignment
      return 1
    fi

    log "waiting for target interfaces; missing: $missing"
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=5 >/dev/null 2>&1 || true
    sleep "$WAIT_INTERVAL"
  done
}

verify_alignment() {
  local i selector target cur ok=1
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" = "$target" ]; then
      log "verified $target -> $(readlink -f "/sys/class/net/$target/device" 2>/dev/null || echo unknown)"
    else
      log "verify failed for $selector: current=${cur:-missing}, target=$target"
      ok=0
    fi
  done
  [ "$ok" = "1" ]
}

align_once() {
  local i selector cur target tmp tmp_selector hold

  # Stage 1: move every target device to a unique temporary name.  Do not run
  # this unless wait_for_all_devices has confirmed all four target NICs exist.
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    tmp="${TMP_PREFIX}${i}"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" != "$tmp" ]; then
      if iface_exists "$tmp"; then
        tmp_selector="$(selector_for_iface "$tmp" || true)"
        if [ "$tmp_selector" != "$selector" ]; then
          rename_iface "$tmp" "$(unique_iface_name "${TMP_PREFIX}x${i}")" || return 1
        fi
      fi
      rename_iface "$cur" "$tmp" || return 1
    fi
  done

  # Stage 2: move temporary names to final eth0-eth3.
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" != "$target" ]; then
      if iface_exists "$target"; then
        hold="$(unique_iface_name "${TMP_PREFIX}hold${i}")"
        log "target $target still exists before final rename; move it aside as $hold"
        rename_iface "$target" "$hold" || return 1
      fi
      rename_iface "$cur" "$target" || return 1
    fi
  done

  verify_alignment
}

main() {
  if ! command -v ip >/dev/null 2>&1; then
    log "ip command not found; cannot align port names"
    exit 0
  fi

  local order i selector all_ok=1
  order="$(read_order)"
  log "eth_order=$order"

  IFS=',' read -r -a SELECTORS <<< "$order"
  if [ "${#SELECTORS[@]}" -lt 4 ]; then
    log "eth_order has less than 4 entries; fallback to $DEFAULT_ORDER"
    IFS=',' read -r -a SELECTORS <<< "$DEFAULT_ORDER"
  fi

  for i in 0 1 2 3; do
    selector="$(normalize_selector "${SELECTORS[$i]}")"
    SELECTORS[$i]="$selector"
    log "target eth$i selector=$selector"
  done

  # Quick path: already correct.
  for i in 0 1 2 3; do
    if [ "$(iface_for_selector "${SELECTORS[$i]}" || true)" != "eth$i" ]; then
      all_ok=0
    fi
  done
  if [ "$all_ok" = "1" ]; then
    log "port order already aligned; nothing to do"
    exit 0
  fi

  if wait_for_all_devices && align_once; then
    log "port order aligned successfully"
    exit 0
  fi

  log "failed to align port order"
  report_alignment
  exit 1
}

main "$@"
ETH_ORDER"
  case "$devpath" in
    *"/pci${selector}/"*|*"/${selector}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

iface_for_selector() {
  local selector="cat > /usr/local/sbin/easepi-r2-eth-order <<'ETH_ORDER'
#!/usr/bin/env bash
# Align EasePi-R2 physical port order to kernel interface names without relying
# on systemd-networkd/NetworkManager.  It reads /proc/device-tree/eth_order and
# matches each NIC by its stable PCIe root bus/root port path.  Do not rely on
# the kernel's initial ethX order or on endpoint bus numbers such as 41/21/11/31;
# those can differ between cold boot and warm reboot.
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
DEFAULT_ORDER="0004:40,0002:20,0001:10,0003:30"
TMP_PREFIX="r2tmp"
LOG_TAG="easepi-r2-eth-order"
WAIT_TIMEOUT="${EASEPI_R2_ETH_ORDER_WAIT_TIMEOUT:-15}"
WAIT_INTERVAL="${EASEPI_R2_ETH_ORDER_WAIT_INTERVAL:-1}"
SELECTORS=()

log() {
  echo "[$LOG_TAG] $*"
  command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" -- "$*" || true
}

read_order() {
  local order=""
  if [ -r /proc/device-tree/eth_order ]; then
    order="$(tr -d '\000' < /proc/device-tree/eth_order 2>/dev/null | tr -d '[:space:]')"
  fi
  [ -n "$order" ] || order="$DEFAULT_ORDER"
  printf '%s\n' "$order"
}

normalize_selector() {
  local selector="$1" domain bus rest bus_dec root_bus

  # New format: domain:root-bus, e.g. 0004:40.
  case "$selector" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])
      printf '%s\n' "$selector"
      return 0
      ;;
  esac

  # Backward compatibility for old DTBs that used endpoint BDFs such as
  # 0004:41:00.0.  On this board the RTL8125 endpoint sits one bus below the
  # root port, so root-bus = endpoint-bus - 1.
  case "$selector" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:*)
      domain="${selector%%:*}"
      rest="${selector#*:}"
      bus="${rest%%:*}"
      bus_dec=$((16#$bus))
      if [ "$bus_dec" -gt 0 ]; then
        root_bus="$(printf '%02x' $((bus_dec - 1)))"
        printf '%s:%s\n' "$domain" "$root_bus"
        return 0
      fi
      ;;
  esac

  printf '%s\n' "$selector"
}

selector_matches_path() {
  local selector="$1" devpath="$2"
  case "$devpath" in
    *"/pci${selector}/"*|*"/${selector}:"*) return 0 ;;
    *) return 1 ;;
  esac
}

iface_for_selector() {
  local selector="$1" p i dev
  for p in /sys/class/net/*; do
    [ -e "$p" ] || continue
    i="${p##*/}"
    [ "$i" = "lo" ] && continue
    dev="$(readlink -f "$p/device" 2>/dev/null || true)"
    if selector_matches_path "$selector" "$dev"; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

selector_for_iface() {
  local iface="$1" selector dev
  dev="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
  [ -n "$dev" ] || return 1
  for selector in "${SELECTORS[@]}"; do
    if selector_matches_path "$selector" "$dev"; then
      printf '%s\n' "$selector"
      return 0
    fi
  done
  return 1
}

iface_exists() {
  [ -e "/sys/class/net/$1" ]
}

unique_iface_name() {
  local base="$1" name="$1" n=0
  while iface_exists "$name"; do
    n=$((n + 1))
    name="${base}${n}"
  done
  printf '%s\n' "$name"
}

rename_iface() {
  local old="$1" new="$2"
  [ -n "$old" ] && [ -n "$new" ] || return 1
  [ "$old" = "$new" ] && return 0
  iface_exists "$old" || { log "skip: $old not found while renaming to $new"; return 1; }

  log "rename $old -> $new"
  ip link set dev "$old" down 2>/dev/null || true
  ip link set dev "$old" name "$new"
}

report_alignment() {
  local i selector target cur dev
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ -n "$cur" ]; then
      dev="$(readlink -f "/sys/class/net/$cur/device" 2>/dev/null || echo unknown)"
      log "$selector -> $cur (target $target, path $dev)"
    else
      log "$selector -> missing (target $target)"
    fi
  done
}

wait_for_all_devices() {
  local deadline missing i selector cur
  deadline=$((SECONDS + WAIT_TIMEOUT))

  while :; do
    missing=""
    for i in 0 1 2 3; do
      selector="${SELECTORS[$i]}"
      cur="$(iface_for_selector "$selector" || true)"
      [ -n "$cur" ] || missing="${missing}${missing:+ }$selector"
    done

    if [ -z "$missing" ]; then
      log "all target RTL8125 interfaces are present"
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      log "timeout waiting for target interfaces; missing: $missing"
      report_alignment
      return 1
    fi

    log "waiting for target interfaces; missing: $missing"
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=5 >/dev/null 2>&1 || true
    sleep "$WAIT_INTERVAL"
  done
}

verify_alignment() {
  local i selector target cur ok=1
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" = "$target" ]; then
      log "verified $target -> $(readlink -f "/sys/class/net/$target/device" 2>/dev/null || echo unknown)"
    else
      log "verify failed for $selector: current=${cur:-missing}, target=$target"
      ok=0
    fi
  done
  [ "$ok" = "1" ]
}

align_once() {
  local i selector cur target tmp tmp_selector hold

  # Stage 1: move every target device to a unique temporary name.  Do not run
  # this unless wait_for_all_devices has confirmed all four target NICs exist.
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    tmp="${TMP_PREFIX}${i}"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" != "$tmp" ]; then
      if iface_exists "$tmp"; then
        tmp_selector="$(selector_for_iface "$tmp" || true)"
        if [ "$tmp_selector" != "$selector" ]; then
          rename_iface "$tmp" "$(unique_iface_name "${TMP_PREFIX}x${i}")" || return 1
        fi
      fi
      rename_iface "$cur" "$tmp" || return 1
    fi
  done

  # Stage 2: move temporary names to final eth0-eth3.
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" != "$target" ]; then
      if iface_exists "$target"; then
        hold="$(unique_iface_name "${TMP_PREFIX}hold${i}")"
        log "target $target still exists before final rename; move it aside as $hold"
        rename_iface "$target" "$hold" || return 1
      fi
      rename_iface "$cur" "$target" || return 1
    fi
  done

  verify_alignment
}

main() {
  if ! command -v ip >/dev/null 2>&1; then
    log "ip command not found; cannot align port names"
    exit 0
  fi

  local order i selector all_ok=1
  order="$(read_order)"
  log "eth_order=$order"

  IFS=',' read -r -a SELECTORS <<< "$order"
  if [ "${#SELECTORS[@]}" -lt 4 ]; then
    log "eth_order has less than 4 entries; fallback to $DEFAULT_ORDER"
    IFS=',' read -r -a SELECTORS <<< "$DEFAULT_ORDER"
  fi

  for i in 0 1 2 3; do
    selector="$(normalize_selector "${SELECTORS[$i]}")"
    SELECTORS[$i]="$selector"
    log "target eth$i selector=$selector"
  done

  # Quick path: already correct.
  for i in 0 1 2 3; do
    if [ "$(iface_for_selector "${SELECTORS[$i]}" || true)" != "eth$i" ]; then
      all_ok=0
    fi
  done
  if [ "$all_ok" = "1" ]; then
    log "port order already aligned; nothing to do"
    exit 0
  fi

  if wait_for_all_devices && align_once; then
    log "port order aligned successfully"
    exit 0
  fi

  log "failed to align port order"
  report_alignment
  exit 1
}

main "$@"
ETH_ORDER"
  [ -n "$old" ] && [ -n "$new" ] || return 1
  [ "$old" = "$new" ] && return 0
  iface_exists "$old" || { log "skip: $old not found while renaming to $new"; return 1; }

  log "rename $old -> $new"
  ip link set dev "$old" down 2>/dev/null || true
  ip link set dev "$old" name "$new"
}

report_alignment() {
  local i selector target cur dev
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ -n "$cur" ]; then
      dev="$(readlink -f "/sys/class/net/$cur/device" 2>/dev/null || echo unknown)"
      log "$selector -> $cur (target $target, path $dev)"
    else
      log "$selector -> missing (target $target)"
    fi
  done
}

wait_for_all_devices() {
  local deadline missing i selector cur
  deadline=$((SECONDS + WAIT_TIMEOUT))

  while :; do
    missing=""
    for i in 0 1 2 3; do
      selector="${SELECTORS[$i]}"
      cur="$(iface_for_selector "$selector" || true)"
      [ -n "$cur" ] || missing="${missing}${missing:+ }$selector"
    done

    if [ -z "$missing" ]; then
      log "all target RTL8125 interfaces are present"
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      log "timeout waiting for target interfaces; missing: $missing"
      report_alignment
      return 1
    fi

    log "waiting for target interfaces; missing: $missing"
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=5 >/dev/null 2>&1 || true
    sleep "$WAIT_INTERVAL"
  done
}

verify_alignment() {
  local i selector target cur ok=1
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" = "$target" ]; then
      log "verified $target -> $(readlink -f "/sys/class/net/$target/device" 2>/dev/null || echo unknown)"
    else
      log "verify failed for $selector: current=${cur:-missing}, target=$target"
      ok=0
    fi
  done
  [ "$ok" = "1" ]
}

align_once() {
  local i selector cur target tmp tmp_selector hold

  # Stage 1: move every target device to a unique temporary name.  Do not run
  # this unless wait_for_all_devices has confirmed all four target NICs exist.
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    tmp="${TMP_PREFIX}${i}"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" != "$tmp" ]; then
      if iface_exists "$tmp"; then
        tmp_selector="$(selector_for_iface "$tmp" || true)"
        if [ "$tmp_selector" != "$selector" ]; then
          rename_iface "$tmp" "$(unique_iface_name "${TMP_PREFIX}x${i}")" || return 1
        fi
      fi
      rename_iface "$cur" "$tmp" || return 1
    fi
  done

  # Stage 2: move temporary names to final eth0-eth3.
  for i in 0 1 2 3; do
    selector="${SELECTORS[$i]}"
    target="eth$i"
    cur="$(iface_for_selector "$selector" || true)"
    if [ "$cur" != "$target" ]; then
      if iface_exists "$target"; then
        hold="$(unique_iface_name "${TMP_PREFIX}hold${i}")"
        log "target $target still exists before final rename; move it aside as $hold"
        rename_iface "$target" "$hold" || return 1
      fi
      rename_iface "$cur" "$target" || return 1
    fi
  done

  verify_alignment
}

main() {
  if ! command -v ip >/dev/null 2>&1; then
    log "ip command not found; cannot align port names"
    exit 0
  fi

  local order i selector all_ok=1
  order="$(read_order)"
  log "eth_order=$order"

  IFS=',' read -r -a SELECTORS <<< "$order"
  if [ "${#SELECTORS[@]}" -lt 4 ]; then
    log "eth_order has less than 4 entries; fallback to $DEFAULT_ORDER"
    IFS=',' read -r -a SELECTORS <<< "$DEFAULT_ORDER"
  fi

  for i in 0 1 2 3; do
    selector="$(normalize_selector "${SELECTORS[$i]}")"
    SELECTORS[$i]="$selector"
    log "target eth$i selector=$selector"
  fi

  # Quick path: already correct.
  for i in 0 1 2 3; do
    if [ "$(iface_for_selector "${SELECTORS[$i]}" || true)" != "eth$i" ]; then
      all_ok=0
    fi
  done
  if [ "$all_ok" = "1" ]; then
    log "port order already aligned; nothing to do"
    exit 0
  fi

  if wait_for_all_devices && align_once; then
    log "port order aligned successfully"
    exit 0
  fi

  log "failed to align port order"
  report_alignment
  exit 1
}

main "$@"
ETH_ORDER
chmod +x /usr/local/sbin/easepi-r2-eth-order

cat > /etc/systemd/system/easepi-r2-eth-order.service <<'ETH_ORDER_SERVICE'
[Unit]
Description=EasePi-R2 align RTL8125 interface names from device-tree eth_order
DefaultDependencies=no
Wants=systemd-udev-trigger.service systemd-udev-settle.service network-pre.target
After=local-fs.target systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service
Before=network-pre.target network.target systemd-networkd.service NetworkManager.service networking.service dnsmasq.service nftables.service
ConditionPathExists=/sys/class/net
StartLimitIntervalSec=45
StartLimitBurst=2

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easepi-r2-eth-order
RemainAfterExit=yes
TimeoutStartSec=30
Restart=on-failure
RestartSec=1

[Install]
WantedBy=sysinit.target
ETH_ORDER_SERVICE

cat > /etc/systemd/network/10-easepi-r2-r8169-keep-kernel.link <<'KEEP_LINK'
[Match]
Driver=r8169

[Link]
NamePolicy=keep
KEEP_LINK
rm -f /etc/systemd/network/10-easepi-r2-eth{0,1,2,3}.link
systemctl daemon-reload 2>/dev/null || true
systemctl enable easepi-r2-eth-order.service 2>/dev/null || true
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

cat > /usr/local/sbin/0 <<'ZERO_ROUTER'
#!/usr/bin/env bash
# EasePi-R2 Router Manager - systemd-networkd edition
set -o pipefail

VERSION="2026-05-11-networkd-router-v5-eth-order"
BASE_DIR="/etc/easepi-r2-router"
CONF_FILE="$BASE_DIR/router.env"
BACKUP_DIR="$BASE_DIR/backups"
NET_DIR="/etc/systemd/network"
DNSMASQ_CONF="/etc/dnsmasq.d/0-router.conf"
NFT_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-easepi-r2-router.conf"

C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_BOLD='\033[1m'
msg(){ echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[提示]${C_RESET} $*"; }
err(){ echo -e "${C_RED}[错误]${C_RESET} $*"; }
info(){ echo -e "${C_BLUE}[信息]${C_RESET} $*"; }
pause(){ read -r -p "按回车继续..." _; }

require_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { err "请用 root 执行：sudo 0"; exit 1; }; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
read_default(){ local p="$1" d="$2" v; read -r -p "$p [$d]: " v; printf '%s' "${v:-$d}"; }
ask_yn(){ local p="$1" d="${2:-y}" v h; [ "$d" = y ] && h="Y/n" || h="y/N"; read -r -p "$p [$h]: " v; v="${v:-$d}"; case "${v,,}" in y|yes|是|好|确认|ok) return 0;; *) return 1;; esac; }

init_defaults(){
  WAN_IFACE="${WAN_IFACE:-eth0}"
  WAN_MODE="${WAN_MODE:-dhcp}"
  WAN_METRIC="${WAN_METRIC:-100}"
  WAN_ADDR="${WAN_ADDR:-}"
  WAN_GW="${WAN_GW:-}"
  WAN_DNS="${WAN_DNS:-223.5.5.5 119.29.29.29}"
  LAN_IFACES="${LAN_IFACES:-eth1 eth2 eth3}"
  LAN_CIDR="${LAN_CIDR:-10.10.0.1/24}"
  LAN_IP="${LAN_IP:-10.10.0.1}"
  DHCP_START="${DHCP_START:-10.10.0.100}"
  DHCP_END="${DHCP_END:-10.10.0.200}"
  DHCP_NETMASK="${DHCP_NETMASK:-255.255.255.0}"
  DNS_UPSTREAM="${DNS_UPSTREAM:-223.5.5.5 119.29.29.29}"
  NAT_OUT="${NAT_OUT:-$WAN_IFACE}"
  LTE4G_METRIC="${LTE4G_METRIC:-900}"
  WLAN_IFACE="${WLAN_IFACE:-wlan0}"
  WLAN_METRIC="${WLAN_METRIC:-800}"
  WLAN_ENABLE_DHCP="${WLAN_ENABLE_DHCP:-no}"
}

load_conf(){
  mkdir -p "$BASE_DIR" "$BACKUP_DIR"
  if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi
  init_defaults
}

save_conf(){
  mkdir -p "$BASE_DIR"
  cat > "$CONF_FILE" <<EOF_CONF
WAN_IFACE='$WAN_IFACE'
WAN_MODE='$WAN_MODE'
WAN_METRIC='$WAN_METRIC'
WAN_ADDR='$WAN_ADDR'
WAN_GW='$WAN_GW'
WAN_DNS='$WAN_DNS'
LAN_IFACES='$LAN_IFACES'
LAN_CIDR='$LAN_CIDR'
LAN_IP='$LAN_IP'
DHCP_START='$DHCP_START'
DHCP_END='$DHCP_END'
DHCP_NETMASK='$DHCP_NETMASK'
DNS_UPSTREAM='$DNS_UPSTREAM'
NAT_OUT='$NAT_OUT'
LTE4G_METRIC='$LTE4G_METRIC'
WLAN_IFACE='$WLAN_IFACE'
WLAN_METRIC='$WLAN_METRIC'
WLAN_ENABLE_DHCP='$WLAN_ENABLE_DHCP'
EOF_CONF
}

cidr_ip(){ echo "${1%/*}"; }
cidr_prefix(){ [ "$1" = "${1#*/}" ] && echo "24" || echo "${1#*/}"; }
prefix_to_netmask(){
  local p="${1:-24}" mask="" full rem i val
  full=$((p/8)); rem=$((p%8))
  for i in 0 1 2 3; do
    if [ $i -lt $full ]; then val=255
    elif [ $i -eq $full ]; then val=$((256 - 2**(8-rem))); [ $rem -eq 0 ] && val=0
    else val=0; fi
    mask+="${mask:+.}$val"
  done
  echo "$mask"
}
subnet_prefix3(){ echo "$1" | awk -F. '{print $1"."$2"."$3}'; }

physical_ifaces(){
  local p i t
  for p in /sys/class/net/*; do
    i="${p##*/}"; [ "$i" = lo ] && continue
    case "$i" in br-*|docker*|veth*|virbr*|tun*|tap*|wg*|ppp*|ifb*) continue;; esac
    t="$(cat "$p/type" 2>/dev/null || echo 0)"; [ "$t" = 1 ] || continue
    echo "$i"
  done
}

backup_now(){
  local reason="${1:-manual}" ts b
  ts="$(date +%Y%m%d-%H%M%S)"; b="$BACKUP_DIR/$ts-$reason"; mkdir -p "$b"
  cp -a "$NET_DIR" "$b/systemd-network" 2>/dev/null || true
  cp -a /etc/dnsmasq.d "$b/dnsmasq.d" 2>/dev/null || true
  cp -a "$NFT_CONF" "$b/nftables.conf" 2>/dev/null || true
  cp -a /etc/sysctl.d "$b/sysctl.d" 2>/dev/null || true
  cp -a /etc/ppp "$b/ppp" 2>/dev/null || true
  cp -a "$CONF_FILE" "$b/router.env" 2>/dev/null || true
  echo "$b"
}

restore_backup(){
  require_root; load_conf
  echo "可用备份："
  ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -10 | nl -w2 -s'. ' || true
  local n b
  read -r -p "输入要恢复的序号：" n
  b="$(ls -1dt "$BACKUP_DIR"/* 2>/dev/null | sed -n "${n}p")"
  [ -n "$b" ] || { err "无效序号"; pause; return; }
  if ! ask_yn "确认恢复 $b ?" n; then return; fi
  rm -rf "$NET_DIR"; mkdir -p "$NET_DIR"; cp -a "$b/systemd-network/." "$NET_DIR/" 2>/dev/null || true
  rm -rf /etc/dnsmasq.d; mkdir -p /etc/dnsmasq.d; cp -a "$b/dnsmasq.d/." /etc/dnsmasq.d/ 2>/dev/null || true
  cp -a "$b/nftables.conf" "$NFT_CONF" 2>/dev/null || true
  rm -rf /etc/sysctl.d; mkdir -p /etc/sysctl.d; cp -a "$b/sysctl.d/." /etc/sysctl.d/ 2>/dev/null || true
  rm -rf /etc/ppp; cp -a "$b/ppp" /etc/ppp 2>/dev/null || true
  cp -a "$b/router.env" "$CONF_FILE" 2>/dev/null || true
  msg "已恢复备份。建议立即重新加载网络。"
  pause
}

disable_netplan_runtime(){
  # netplan can generate /run/systemd/network/10-netplan-*.network, which wins
  # systemd-networkd's first-match rule before our LAN Bridge=br-lan files.
  # This router image is intentionally managed by native systemd-networkd only.
  mkdir -p "$BASE_DIR/disabled-netplan" "$BASE_DIR/disabled-networkd"
  if [ -d /etc/netplan ]; then
    local f b ts
    ts="$(date +%Y%m%d-%H%M%S)"
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
      [ -e "$f" ] || continue
      b="$(basename "$f")"
      mv "$f" "$BASE_DIR/disabled-netplan/${ts}-${b}" 2>/dev/null || true
      warn "已停用 netplan 配置：$f -> $BASE_DIR/disabled-netplan/${ts}-${b}"
    done
  fi
  rm -f /run/systemd/network/*netplan*.network 2>/dev/null || true
}

clean_conflicting_networkd_runtime(){
  # Keep only non-conflicting .link files. Interface order is handled by
  # easepi-r2-eth-order before any network manager starts.
  mkdir -p "$BASE_DIR/disabled-networkd"
  local f b ts
  ts="$(date +%Y%m%d-%H%M%S)"
  for f in "$NET_DIR"/*.network; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      *easepi-r2*.network) ;;
      *) mv "$f" "$BASE_DIR/disabled-networkd/${ts}-${b}" 2>/dev/null || true; warn "已隔离可能抢先匹配的 networkd 配置：$b" ;;
    esac
  done
}

clean_generated_networkd(){
  mkdir -p "$NET_DIR"
  # Remove old and new router-generated files and legacy eth0-eth3 .link renames.
  rm -f "$NET_DIR"/20-br-lan.netdev "$NET_DIR"/21-br-lan.network
  rm -f "$NET_DIR"/30-wan-*.network "$NET_DIR"/3[1-9]-lan-*.network
  rm -f "$NET_DIR"/40-lte4g.network "$NET_DIR"/50-*-dhcp.network "$NET_DIR"/70-*-dhcp-metric.network
  rm -f "$NET_DIR"/00-easepi-r2-br-lan.netdev
  rm -f "$NET_DIR"/0[0-9]-easepi-r2-*.network "$NET_DIR"/70-easepi-r2-*.network
  rm -f "$NET_DIR"/10-easepi-r2-eth{0,1,2,3}.link
  cat > "$NET_DIR/10-easepi-r2-r8169-keep-kernel.link" <<'EOF_KEEP_LINK'
[Match]
Driver=r8169

[Link]
NamePolicy=keep
EOF_KEEP_LINK
}

write_networkd(){
  mkdir -p "$NET_DIR"
  disable_netplan_runtime
  clean_conflicting_networkd_runtime
  clean_generated_networkd

  cat > "$NET_DIR/00-easepi-r2-br-lan.netdev" <<'EOF_BRDEV'
[NetDev]
Name=br-lan
Kind=bridge
EOF_BRDEV

  cat > "$NET_DIR/01-easepi-r2-br-lan.network" <<EOF_BRNET
[Match]
Name=br-lan

[Link]
RequiredForOnline=no
ActivationPolicy=up

[Network]
Address=$LAN_CIDR
ConfigureWithoutCarrier=yes
IPv4Forwarding=yes
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF_BRNET

  if [ "$WAN_MODE" = dhcp ]; then
    cat > "$NET_DIR/02-easepi-r2-wan-${WAN_IFACE}.network" <<EOF_WAN
[Match]
Name=$WAN_IFACE

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
$(for d in $WAN_DNS; do echo "DNS=$d"; done)

[DHCPv4]
UseDNS=no
RouteMetric=$WAN_METRIC
EOF_WAN
  elif [ "$WAN_MODE" = static ]; then
    cat > "$NET_DIR/02-easepi-r2-wan-${WAN_IFACE}.network" <<EOF_WAN
[Match]
Name=$WAN_IFACE

[Link]
RequiredForOnline=no

[Network]
Address=$WAN_ADDR
IPv6AcceptRA=no
LinkLocalAddressing=no
$(for d in $WAN_DNS; do echo "DNS=$d"; done)

[Route]
Gateway=$WAN_GW
Metric=$WAN_METRIC
EOF_WAN
  else
    cat > "$NET_DIR/02-easepi-r2-wan-${WAN_IFACE}.network" <<EOF_WAN
[Match]
Name=$WAN_IFACE

[Link]
RequiredForOnline=no

[Network]
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF_WAN
  fi

  local i idx=3
  for i in $LAN_IFACES; do
    [ -n "$i" ] || continue
    [ "$i" = "$WAN_IFACE" ] && { warn "$i 是当前 WAN 口，跳过加入 LAN 桥"; continue; }
    cat > "$NET_DIR/$(printf '%02d' "$idx")-easepi-r2-lan-${i}.network" <<EOF_LAN
[Match]
Name=$i

[Link]
RequiredForOnline=no
ActivationPolicy=up

[Network]
Bridge=br-lan
ConfigureWithoutCarrier=yes
IgnoreCarrierLoss=yes
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF_LAN
    idx=$((idx+1))
  done

  cat > "$NET_DIR/07-easepi-r2-lte4g.network" <<EOF_LTE
[Match]
Name=lte4g

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no

[DHCPv4]
UseDNS=no
RouteMetric=$LTE4G_METRIC
EOF_LTE

  if [ "$WLAN_ENABLE_DHCP" = yes ]; then
    cat > "$NET_DIR/08-easepi-r2-${WLAN_IFACE}-dhcp.network" <<EOF_WLAN
[Match]
Name=$WLAN_IFACE

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no

[DHCPv4]
UseDNS=no
RouteMetric=$WLAN_METRIC
EOF_WLAN
  fi
}

write_dnsmasq(){
  mkdir -p /etc/dnsmasq.d
  cat > "$DNSMASQ_CONF" <<EOF_DNS
# Generated by EasePi-R2 0 on $(date '+%F %T')
interface=lo
interface=br-lan
no-dhcp-interface=lo
bind-dynamic
listen-address=127.0.0.1,$LAN_IP
port=53
$(for d in $DNS_UPSTREAM; do echo "server=$d"; done)
domain-needed
bogus-priv
no-resolv
expand-hosts
domain=lan
dhcp-authoritative
dhcp-range=interface:br-lan,$DHCP_START,$DHCP_END,$DHCP_NETMASK,12h
dhcp-option=interface:br-lan,3,$LAN_IP
dhcp-option=interface:br-lan,6,$LAN_IP
EOF_DNS
}

write_nft(){
  cat > "$NFT_CONF" <<EOF_NFT
#!/usr/sbin/nft -f
# Generated by EasePi-R2 0 on $(date '+%F %T')
flush ruleset

table inet filter {
  chain forward {
    type filter hook forward priority filter; policy accept;
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$NAT_OUT" masquerade
  }
}
EOF_NFT
}

write_sysctl(){
  mkdir -p /etc/sysctl.d
  cat > "$SYSCTL_CONF" <<'EOF_SYS'
net.ipv4.ip_forward=1
EOF_SYS
}

write_pppoe(){
  [ "$WAN_MODE" = pppoe ] || return 0
  mkdir -p /etc/ppp/peers
  cat > /etc/ppp/peers/0-wan <<EOF_PPP
plugin rp-pppoe.so
$WAN_IFACE
user "$PPPOE_USER"
noauth
defaultroute
replacedefaultroute
hide-password
persist
maxfail 0
usepeerdns
mtu 1492
mru 1492
EOF_PPP
  touch /etc/ppp/chap-secrets /etc/ppp/pap-secrets
  chmod 600 /etc/ppp/chap-secrets /etc/ppp/pap-secrets
  grep -q "^\"$PPPOE_USER\"" /etc/ppp/chap-secrets 2>/dev/null || echo "\"$PPPOE_USER\" * \"$PPPOE_PASS\" *" >> /etc/ppp/chap-secrets
  grep -q "^\"$PPPOE_USER\"" /etc/ppp/pap-secrets 2>/dev/null || echo "\"$PPPOE_USER\" * \"$PPPOE_PASS\" *" >> /etc/ppp/pap-secrets
  cat > /etc/systemd/system/0-pppoe.service <<'EOF_SVC'
[Unit]
Description=EasePi-R2 PPPoE WAN
After=systemd-networkd.service
Wants=systemd-networkd.service

[Service]
Type=simple
ExecStart=/usr/sbin/pppd call 0-wan nodetach
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SVC
}

write_all(){
  save_conf
  write_networkd
  write_dnsmasq
  write_nft
  write_sysctl
}

verify_lan_network_files(){
  local i nf ok=0
  for i in $LAN_IFACES; do
    nf="$(networkctl status "$i" 2>/dev/null | sed -n 's/.*Network File: //p' | head -1)"
    printf '    %s: %s\n' "$i" "${nf:-未匹配/未受 networkd 管理}"
    case "$nf" in
      *easepi-r2-lan-${i}.network) ok=$((ok+1)) ;;
    esac
  done
  return 0
}

apply_now(){
  require_root; load_conf
  backup_now apply >/dev/null
  disable_netplan_runtime
  clean_conflicting_networkd_runtime
  write_all
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reload || true
  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    systemctl disable --now NetworkManager.service >/dev/null 2>&1 || true
  fi
  systemctl enable easepi-r2-eth-order.service >/dev/null 2>&1 || true
  systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
  systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
  systemctl enable systemd-networkd.service >/dev/null 2>&1 || true
  systemctl restart systemd-networkd.service >/dev/null 2>&1 || warn "systemd-networkd 重启失败，请看 journalctl -u systemd-networkd"
  if [ "$WAN_MODE" = pppoe ]; then systemctl enable --now 0-pppoe.service >/dev/null 2>&1 || true; fi
  systemctl enable --now nftables.service >/dev/null 2>&1 || true
  nft -f "$NFT_CONF" 2>/dev/null || warn "nftables 规则加载失败，请检查 $NFT_CONF"
  systemctl restart nftables.service >/dev/null 2>&1 || true
  systemctl enable --now dnsmasq.service >/dev/null 2>&1 || true
  systemctl restart dnsmasq.service >/dev/null 2>&1 || warn "dnsmasq 启动失败，请看 journalctl -u dnsmasq"
  msg "已应用 networkd / dnsmasq / nftables 配置。"
  verify_status
}

verify_status(){
  echo
  echo "运行核验："
  ip -br addr show "$WAN_IFACE" 2>/dev/null | sed 's/^/  WAN: /' || true
  ip -br addr show br-lan 2>/dev/null | sed 's/^/  LAN: /' || true
  ip -br addr show lte4g 2>/dev/null | sed 's/^/  4G : /' || true
  echo "  桥接端口："
  bridge link 2>/dev/null | sed 's/^/    /' || echo "    bridge 命令不可用或无端口"
  echo "  LAN/networkd 匹配："
  verify_lan_network_files
  echo "  默认路由："
  ip route show default 2>/dev/null | sed 's/^/    /' || true
  echo "  DHCP/DNS 监听："
  ss -lunp 2>/dev/null | grep -E ':(53|67)\b|dnsmasq' | sed 's/^/    /' || true
}

show_status(){
  load_conf
  clear 2>/dev/null || true
  echo "EasePi-R2 networkd 路由状态  $VERSION"
  echo "============================================================"
  echo "持久配置：$CONF_FILE"
  echo "WAN: $WAN_IFACE / $WAN_MODE / metric=$WAN_METRIC / NAT=$NAT_OUT"
  echo "LAN: br-lan $LAN_CIDR / ports: $LAN_IFACES"
  echo "DHCP: $DHCP_START - $DHCP_END / netmask=$DHCP_NETMASK"
  echo "LTE4G: metric=$LTE4G_METRIC；WLAN: $WLAN_IFACE DHCP=$WLAN_ENABLE_DHCP metric=$WLAN_METRIC"
  echo "------------------------------------------------------------"
  echo "接口："; ip -br addr | sed 's/^/  /'
  echo "------------------------------------------------------------"
  echo "默认路由："; ip route show default | sed 's/^/  /' || true
  echo "------------------------------------------------------------"
  echo "bridge link："; bridge link 2>/dev/null | sed 's/^/  /' || true
  echo "------------------------------------------------------------"
  echo "LAN/networkd 匹配："; verify_lan_network_files
  echo "------------------------------------------------------------"
  echo "服务："
  for s in systemd-networkd dnsmasq nftables NetworkManager; do
    if systemctl list-unit-files "$s.service" >/dev/null 2>&1; then
      printf '  %-18s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true) / $(systemctl is-enabled "$s" 2>/dev/null || true)"
    fi
  done
  pause
}

configure_wan(){
  require_root; load_conf
  echo "当前物理接口："; physical_ifaces | sed 's/^/  /'
  WAN_IFACE="$(read_default "WAN 接口" "$WAN_IFACE")"
  echo "WAN 模式：1) DHCP  2) 静态  3) PPPoE"
  local c; read -r -p "请选择 [1]: " c; c="${c:-1}"
  case "$c" in
    2) WAN_MODE=static; WAN_ADDR="$(read_default "WAN 静态地址/CIDR" "${WAN_ADDR:-192.168.1.2/24}")"; WAN_GW="$(read_default "WAN 网关" "${WAN_GW:-192.168.1.1}")"; WAN_DNS="$(read_default "WAN DNS，空格分隔" "$WAN_DNS")" ;;
    3) WAN_MODE=pppoe; read -r -p "PPPoE 账号: " PPPOE_USER; read -r -s -p "PPPoE 密码: " PPPOE_PASS; echo; NAT_OUT=ppp0 ;;
    *) WAN_MODE=dhcp; WAN_DNS="$(read_default "WAN DNS，空格分隔" "$WAN_DNS")"; NAT_OUT="$WAN_IFACE" ;;
  esac
  WAN_METRIC="$(read_default "WAN 默认路由跃点 metric，越小优先级越高" "$WAN_METRIC")"
  [ "$WAN_MODE" = pppoe ] || NAT_OUT="$(read_default "NAT 出口" "$NAT_OUT")"
  write_all; [ "$WAN_MODE" = pppoe ] && write_pppoe
  msg "WAN 配置已写入。"
  if ask_yn "是否立即应用？" y; then apply_now; else pause; fi
}

configure_lan(){
  require_root; load_conf
  echo "当前物理接口："; physical_ifaces | sed 's/^/  /'
  LAN_IFACES="$(read_default "加入 br-lan 的 LAN 口，空格分隔" "$LAN_IFACES")"
  LAN_CIDR="$(read_default "br-lan 地址/CIDR" "$LAN_CIDR")"
  LAN_IP="$(cidr_ip "$LAN_CIDR")"
  DHCP_NETMASK="$(prefix_to_netmask "$(cidr_prefix "$LAN_CIDR")")"
  local p3; p3="$(subnet_prefix3 "$LAN_IP")"
  if ask_yn "是否按新 br-lan 网段自动推荐 DHCP 范围？" y; then
    DHCP_START="$p3.100"; DHCP_END="$p3.200"
  fi
  DHCP_START="$(read_default "DHCP 起始地址" "$DHCP_START")"
  DHCP_END="$(read_default "DHCP 结束地址" "$DHCP_END")"
  write_all
  msg "LAN/br-lan/DHCP 配置已写入。"
  if ask_yn "是否立即应用？" y; then apply_now; else pause; fi
}

configure_dhcp(){
  require_root; load_conf
  DHCP_START="$(read_default "DHCP 起始地址" "$DHCP_START")"
  DHCP_END="$(read_default "DHCP 结束地址" "$DHCP_END")"
  DHCP_NETMASK="$(read_default "DHCP 子网掩码" "$DHCP_NETMASK")"
  DNS_UPSTREAM="$(read_default "上游 DNS，空格分隔" "$DNS_UPSTREAM")"
  write_all
  msg "DHCP/DNS 配置已写入。"
  if ask_yn "是否重启 dnsmasq？" y; then systemctl restart dnsmasq 2>/dev/null || warn "dnsmasq 重启失败"; fi
  pause
}

configure_nat(){
  require_root; load_conf
  echo "当前默认路由："; ip route show default | sed 's/^/  /'
  NAT_OUT="$(read_default "NAT 出口接口，例如 eth0/ppp0/lte4g/wlan0" "$NAT_OUT")"
  write_all
  nft -f "$NFT_CONF" 2>/dev/null || true
  systemctl restart nftables 2>/dev/null || true
  msg "NAT 出口已改为 $NAT_OUT，并已持久化。"
  pause
}

configure_metric(){
  require_root; load_conf
  echo "当前默认路由："; ip route show default | sed 's/^/  /'
  echo
  local iface metric
  iface="$(read_default "要修改路由跃点的接口" "lte4g")"
  metric="$(read_default "$iface 的 RouteMetric，越大优先级越低" "900")"
  case "$iface" in
    "$WAN_IFACE") WAN_METRIC="$metric" ;;
    lte4g) LTE4G_METRIC="$metric" ;;
    "$WLAN_IFACE"|wlan0) WLAN_IFACE="$iface"; WLAN_METRIC="$metric"; WLAN_ENABLE_DHCP="$(ask_yn "是否让 networkd 管理 $iface 的 DHCP？仅 IP 层，WiFi 密码仍需 wpa_supplicant/iwd" y && echo yes || echo no)" ;;
    *)
      mkdir -p "$NET_DIR"
      cat > "$NET_DIR/09-easepi-r2-${iface}-dhcp-metric.network" <<EOF_EXTRA
[Match]
Name=$iface

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no

[DHCPv4]
UseDNS=no
RouteMetric=$metric
EOF_EXTRA
      warn "已为 $iface 生成独立 DHCP metric 配置：$NET_DIR/09-easepi-r2-${iface}-dhcp-metric.network"
      ;;
  esac
  write_all
  msg "路由跃点已写入持久配置。"
  if ask_yn "是否重启 systemd-networkd 立即生效？" y; then apply_now; else pause; fi
}

configure_lte4g(){
  require_root; load_conf
  LTE4G_METRIC="$(read_default "lte4g DHCP 默认路由 metric，建议 800-1000" "$LTE4G_METRIC")"
  write_all
  msg "lte4g 已设置为 networkd DHCP，metric=$LTE4G_METRIC。"
  if ask_yn "是否立即应用？" y; then apply_now; else pause; fi
}

configure_wlan(){
  require_root; load_conf
  WLAN_IFACE="$(read_default "WiFi 接口名" "$WLAN_IFACE")"
  WLAN_ENABLE_DHCP="$(ask_yn "是否让 networkd 管理 $WLAN_IFACE 的 DHCP？注意：WiFi 连接认证仍需 wpa_supplicant/iwd" "${WLAN_ENABLE_DHCP:-no}" && echo yes || echo no)"
  WLAN_METRIC="$(read_default "$WLAN_IFACE 默认路由 metric，建议备用 WAN 用 700-900" "$WLAN_METRIC")"
  write_all
  msg "WiFi IP 层配置已写入。热点/AP 模式建议用 hostapd + 单独配置。"
  if ask_yn "是否立即应用？" n; then apply_now; else pause; fi
}

is_vendor_gpu_runtime(){
  grep -qiE 'vendor|rk35xx' /proc/version 2>/dev/null && return 0
  modinfo mali_kbase >/dev/null 2>&1 && return 0
  [ -e /dev/mali0 ] && return 0
  [ -e /dev/mali ] && return 0
  return 1
}

install_deps(){
  require_root
  GPU_PACKAGES=(libdrm2 libegl-mesa0 libgles2 libgl1-mesa-dri mesa-vulkan-drivers mesa-utils vulkan-tools kmscube glmark2-es2-drm)
  if is_vendor_gpu_runtime; then
    GPU_PACKAGES=(libdrm2 libgbm1 ocl-icd-libopencl1 clinfo)
  fi
  apt-get update
  apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    iproute2 ethtool dnsmasq nftables ppp pppoe curl ca-certificates bridge-utils wpasupplicant hostapd \
    rfkill bluetooth bluez bluez-tools \
    v4l-utils "${GPU_PACKAGES[@]}" || true
  FW_DIR="/lib/firmware/brcm"
  BT_PATCH="BCM4345C0_003.001.025.0162.0000_Generic_UART_37_4MHz_wlbga_ref_iLNA_iTR_eLG.hcd"
  if [ -d "$FW_DIR" ]; then
    if [ -f "$FW_DIR/$BT_PATCH" ]; then
      ln -sfn "$BT_PATCH" "$FW_DIR/BCM4345C0.linkease,easepi-r2.hcd"
      ln -sfn "$BT_PATCH" "$FW_DIR/BCM4345C0.hcd"
    fi
    [ -f "$FW_DIR/brcmfmac43455-sdio.bin" ] && ln -sfn brcmfmac43455-sdio.bin "$FW_DIR/brcmfmac43455-sdio.linkease,easepi-r2.bin"
    [ -f "$FW_DIR/brcmfmac43455-sdio.txt" ] && ln -sfn brcmfmac43455-sdio.txt "$FW_DIR/brcmfmac43455-sdio.linkease,easepi-r2.txt"
    [ -f "$FW_DIR/brcmfmac43455-sdio.clm_blob" ] && ln -sfn brcmfmac43455-sdio.clm_blob "$FW_DIR/brcmfmac43455-sdio.linkease,easepi-r2.clm_blob"
  fi
  systemctl disable --now NetworkManager.service 2>/dev/null || true
  systemctl enable easepi-r2-eth-order.service systemd-networkd dnsmasq nftables 2>/dev/null || true
  systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
  systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
  msg "依赖处理完成。"
  pause
}

menu(){
  while true; do
    load_conf
    clear 2>/dev/null || true
    echo "============================================================"
    echo " EasePi-R2 networkd 主路由管理器 $VERSION"
    echo "============================================================"
    echo " 当前：WAN=$WAN_IFACE($WAN_MODE,metric=$WAN_METRIC)  LAN=br-lan $LAN_CIDR  NAT=$NAT_OUT"
    echo " 4G：lte4g metric=$LTE4G_METRIC  WiFi：$WLAN_IFACE DHCP=$WLAN_ENABLE_DHCP metric=$WLAN_METRIC"
    echo "------------------------------------------------------------"
    echo "1. 查看状态 / 路由 / bridge / DHCP"
    echo "2. 修改 WAN 口 / 模式 / WAN 路由跃点"
    echo "3. 修改 br-lan 地址范围 / LAN 口 / DHCP 范围"
    echo "4. 只修改 DHCP / DNS 参数"
    echo "5. 修改 NAT 出口"
    echo "6. 修改默认路由跃点 metric（eth0/lte4g/wlan0 等，重启不失效）"
    echo "7. 设置 lte4g 为保底 DHCP 线路 metric"
    echo "8. 设置 wlan0 备用 WAN 的 DHCP metric（WiFi认证需另配）"
    echo "9. 重新生成并应用 networkd/dnsmasq/nftables"
    echo "10. 安装/补齐路由依赖"
    echo "11. 恢复备份"
    echo "0. 退出"
    echo "============================================================"
    local c; read -r -p "请选择：" c
    case "$c" in
      1) show_status ;;
      2) configure_wan ;;
      3) configure_lan ;;
      4) configure_dhcp ;;
      5) configure_nat ;;
      6) configure_metric ;;
      7) configure_lte4g ;;
      8) configure_wlan ;;
      9) apply_now; pause ;;
      10) install_deps ;;
      11) restore_backup ;;
      0) exit 0 ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

require_root
menu
ZERO_ROUTER

chmod +x /usr/local/sbin/0
cat > /usr/local/sbin/0en <<'ZERO_EN'
#!/usr/bin/env bash
set -euo pipefail
CONF_FILE="/etc/easepi-r2-router/router.env"
[ -r "$CONF_FILE" ] && . "$CONF_FILE" || true
WAN_IFACE="${WAN_IFACE:-eth0}"; LAN_IFACES="${LAN_IFACES:-eth1 eth2 eth3}"; NAT_OUT="${NAT_OUT:-$WAN_IFACE}"
while true; do
  clear 2>/dev/null || true
  echo "============================================================"
  echo " EasePi-R2 systemd-networkd Router Manager - English"
  echo "============================================================"
  echo "Current: WAN=$WAN_IFACE  LAN ports=[$LAN_IFACES]  NAT=$NAT_OUT"
  echo "1. Show status / routes / bridge / DHCP"
  echo "2. Apply generated networkd/dnsmasq/nftables config"
  echo "3. Open Chinese full manager"
  echo "0. Exit"
  echo "============================================================"
  read -r -p "Select: " c
  case "$c" in
    1)
      echo "Interfaces:"; ip -br addr || true
      echo; echo "Routes:"; ip route || true
      echo; echo "Bridge ports:"; bridge link || true
      echo; echo "systemd-networkd files for LAN ports:"
      for i in $LAN_IFACES; do
        nf="$(networkctl status "$i" 2>/dev/null | sed -n 's/.*Network File: //p' | head -1 || true)"
        printf '  %-8s %s\n' "$i" "${nf:-not matched}"
      done
      echo; echo "DHCP/DNS sockets:"; ss -lunp 2>/dev/null | grep -E ':(53|67)\b|dnsmasq' || true
      read -r -p "Press Enter to continue..." _ ;;
    2) exec /usr/local/sbin/0 ;;
    3) exec /usr/local/sbin/0 ;;
    0) exit 0 ;;
    *) echo "Invalid selection"; sleep 1 ;;
  esac
done
ZERO_EN
chmod +x /usr/local/sbin/0en

echo "已安装命令：0（systemd-networkd 主路由管理器）"
echo "运行：sudo 0"
