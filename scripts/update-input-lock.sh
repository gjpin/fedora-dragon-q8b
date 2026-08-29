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
    sed -i "s#^${key}:.*#${key}: \"${value}\"#" "$lock"
}

replace fedora_release "$FEDORA_RELEASE"
replace fedora_kernel_branch "$FEDORA_KERNEL_BRANCH"
replace fedora_kernel_commit "$FEDORA_KERNEL_COMMIT"
replace fedora_kernel_version "$FEDORA_KERNEL_VERSION"
replace radxa_kernel_ref "$RADXA_KERNEL_REF"
replace radxa_firmware_ref "$RADXA_FIRMWARE_REF"
replace radxa_overlays_ref "$RADXA_OVERLAYS_REF"
replace armbian_ref "$ARMBIAN_REF"
replace patch_manifest_sha256 "$PATCH_MANIFEST_SHA256"
