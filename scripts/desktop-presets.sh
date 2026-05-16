#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

prompt_value() {
    local var_name="$1"
    local prompt_text="$2"
    local current="${!var_name:-}"

    if [ -n "${current}" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        echo "ERROR: ${var_name} must be provided in non-interactive mode."
        exit 1
    fi

    while true; do
        read -r -p "${prompt_text}: " current
        if [ -n "${current}" ]; then
            printf -v "${var_name}" '%s' "${current}"
            export "${var_name}"
            return 0
        fi
        echo "ERROR: value cannot be empty."
    done
}

prompt_password() {
    local var_name="$1"
    local prompt_text="$2"
    local current="${!var_name:-}"
    local confirm=""

    if [ -n "${current}" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        echo "ERROR: ${var_name} must be provided in non-interactive mode."
        exit 1
    fi

    while true; do
        read -r -s -p "${prompt_text}: " current
        echo
        read -r -s -p "Confirm ${prompt_text}: " confirm
        echo
        if [ -z "${current}" ]; then
            echo "ERROR: password cannot be empty."
            continue
        fi
        if [ "${current}" != "${confirm}" ]; then
            echo "ERROR: passwords do not match."
            continue
        fi
        printf -v "${var_name}" '%s' "${current}"
        export "${var_name}"
        return 0
    done
}

run_desktop_preset() {
    local dist="$1"
    local release="$2"
    local kernel="$3"
    local profile="$4"

    prompt_value IMAGE_USER "Desktop sudo username"
    prompt_password IMAGE_PASSWORD "Desktop sudo password"
    prompt_password ROOT_PASSWORD "Root password"

    export CREATE_USER=yes
    export EASEPI_R2_DESKTOP_PROFILE="${profile}"
    export EASEPI_R2_DESKTOP_LOCALE="${EASEPI_R2_DESKTOP_LOCALE:-zh_CN.UTF-8}"

    exec bash "${REPO_DIR}/build-image.sh" "${dist}" "${release}" "${kernel}" desktop
}
