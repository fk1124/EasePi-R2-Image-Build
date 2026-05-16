#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${REPO_DIR}/scripts/desktop-presets.sh"

run_desktop_preset debian trixie 6.18 xfce
