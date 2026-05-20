#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "${REPO_DIR}/build-rootfs-image.sh" alpine "${1:-stable}" "${2:-current}" "${3:-minimal}"
