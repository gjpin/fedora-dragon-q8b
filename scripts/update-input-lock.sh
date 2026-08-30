#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: update-input-lock.sh --env FILE" >&2; }
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_file=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) env_file=${2:?missing environment file}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -r "$env_file" ]] || { echo "missing env file: $env_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

lock="$repo_root/packaging/inputs.lock"
replace() {
    local key=$1 value=$2
    if grep -q "^${key}:" "$lock"; then
        sed -i "s#^${key}:.*#${key}: \"${value}\"#" "$lock"
    else
        printf '%s: "%s"\n' "$key" "$value" >> "$lock"
    fi
}

replace radxa_kernel_ref "$RADXA_KERNEL_REF"
replace radxa_kernel_dts_path "vendor/radxa/kernel/sc8280xp-radxa-dragon-q8b.dts"
replace radxa_kernel_dts_sha256 "$RADXA_KERNEL_DTS_SHA256"
replace radxa_firmware_ref "$RADXA_FIRMWARE_REF"
replace radxa_overlays_ref "$RADXA_OVERLAYS_REF"
replace radxa_firmware_archive "vendor/radxa/firmware/radxa-firmware-${RADXA_FIRMWARE_REF}.tar.gz"
replace radxa_firmware_archive_sha256 "$RADXA_FIRMWARE_ARCHIVE_SHA256"
replace radxa_overlays_archive "vendor/radxa/overlays/radxa-overlays-${RADXA_OVERLAYS_REF}.tar.gz"
replace radxa_overlays_archive_sha256 "$RADXA_OVERLAYS_ARCHIVE_SHA256"
replace alsa_ucm_version "$ALSA_UCM_VERSION"
replace alsa_ucm_archive "vendor/radxa/alsa/${ALSA_UCM_ARCHIVE:-alsa-ucm-conf-${ALSA_UCM_VERSION}.tar.gz}"
replace alsa_ucm_archive_sha256 "$ALSA_UCM_ARCHIVE_SHA256"
replace armbian_ref "$ARMBIAN_REF"
replace patch_manifest_sha256 "$PATCH_MANIFEST_SHA256"
replace fastrpc_ref "${FASTRPC_REF}"
replace fastrpc_tag "${FASTRPC_TAG:-v${FASTRPC_VERSION}}"
replace fastrpc_version "${FASTRPC_VERSION}"
replace fastrpc_archive "${FASTRPC_ARCHIVE:-vendor/qualcomm/fastrpc/fastrpc-${FASTRPC_VERSION}.tar.gz}"
replace fastrpc_archive_sha256 "${FASTRPC_ARCHIVE_SHA256}"
replace qairt_version "$QAIRT_VERSION"
replace qairt_download_url "$QAIRT_DOWNLOAD_URL"
replace qairt_archive_sha256 "$QAIRT_ARCHIVE_SHA256"
replace qairt_license_sha256 "$QAIRT_LICENSE_SHA256"
replace qairt_target "$QAIRT_TARGET"
replace qairt_dsp_arch "$QAIRT_DSP_ARCH"
