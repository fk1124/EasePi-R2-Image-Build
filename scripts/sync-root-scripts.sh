#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/work}"

SCRIPT_REPO="${EASEPI_R2_SCRIPT_REPO:-https://github.com/fk1124/EasePi-R2-Script.git}"
SCRIPT_REF="${EASEPI_R2_SCRIPT_REF:-main}"
SCRIPT_SYNC="${EASEPI_R2_SCRIPT_SYNC:-yes}"
CACHE_DIR="${EASEPI_R2_SCRIPT_CACHE_DIR:-${WORK_DIR}/cache/easepi-r2-script}"
DEST_DIR="${1:-${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals/root}"

msg() {
    printf 'EasePi-R2 script sync: %s\n' "$*"
}

if [ "${SCRIPT_SYNC}" = "no" ] || [ "${SCRIPT_SYNC}" = "0" ]; then
    msg "disabled by EASEPI_R2_SCRIPT_SYNC=${SCRIPT_SYNC}"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to sync EasePi-R2 root scripts." >&2
    exit 1
fi

tmp_dir=""
cleanup() {
    [ -z "${tmp_dir}" ] || rm -rf "${tmp_dir}"
}
trap cleanup EXIT

configure_sparse_checkout() {
    local repo_dir="$1"

    git -C "${repo_dir}" config core.sparseCheckout true
    git -C "${repo_dir}" config core.sparseCheckoutCone false
    mkdir -p "${repo_dir}/.git/info"
    printf '/*.sh\n' > "${repo_dir}/.git/info/sparse-checkout"
}

mkdir -p "$(dirname "${CACHE_DIR}")"

if [ -d "${CACHE_DIR}/.git" ]; then
    msg "updating ${SCRIPT_REPO} (${SCRIPT_REF})"
    git -C "${CACHE_DIR}" remote set-url origin "${SCRIPT_REPO}"
    configure_sparse_checkout "${CACHE_DIR}"
    git -C "${CACHE_DIR}" fetch --depth=1 --no-tags origin "${SCRIPT_REF}"
    git -C "${CACHE_DIR}" checkout -q --detach FETCH_HEAD
    git -C "${CACHE_DIR}" clean -fdx -q
else
    msg "cloning ${SCRIPT_REPO} (${SCRIPT_REF})"
    tmp_dir="${CACHE_DIR}.tmp.$$"
    rm -rf "${tmp_dir}"
    git clone --depth=1 --filter=blob:none --no-tags --no-checkout "${SCRIPT_REPO}" "${tmp_dir}"
    configure_sparse_checkout "${tmp_dir}"
    git -C "${tmp_dir}" fetch --depth=1 --no-tags origin "${SCRIPT_REF}"
    git -C "${tmp_dir}" checkout -q --detach FETCH_HEAD
    rm -rf "${CACHE_DIR}"
    mv "${tmp_dir}" "${CACHE_DIR}"
    tmp_dir=""
fi

shopt -s nullglob
scripts=("${CACHE_DIR}"/*.sh)
shopt -u nullglob

if [ "${#scripts[@]}" -eq 0 ]; then
    echo "ERROR: no root-level .sh scripts found in ${SCRIPT_REPO} (${SCRIPT_REF})." >&2
    exit 1
fi

mkdir -p "${DEST_DIR}"
find "${DEST_DIR}" -maxdepth 1 -type f -name '*.sh' -delete
cp -f "${scripts[@]}" "${DEST_DIR}/"
chmod 0755 "${DEST_DIR}"/*.sh

msg "synced ${#scripts[@]} script(s) to ${DEST_DIR}"
