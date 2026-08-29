#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: validate-vendor.sh [--root DIR]" >&2; }
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) repo_root=$(cd "${2:?missing repository root}" && pwd); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

for command in ar awk find grep sha256sum tar; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

die() { echo "vendor validation: $*" >&2; exit 1; }

lock_value() {
    local key=$1
    awk -v key="$key" '$1 == key ":" {gsub(/"/, "", $2); print $2; exit}' \
        "$repo_root/packaging/inputs.lock"
}

check_lock_hash() {
    local key=$1 file=$2 expected actual
    expected=$(lock_value "$key")
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die "invalid or missing lock hash: $key"
    actual=$(sha256sum "$repo_root/$file" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || \
        die "lock hash mismatch for $file: $actual != $expected"
}

archive_has_license() {
    tar -tzf "$1" | awk -F/ '
        tolower($NF) ~ /^(license|copying)(\..*)?$/ {found=1}
        END {exit !found}
    '
}

list_deb_data() {
    local deb=$1 member=$2
    case "$member" in
        data.tar.xz) ar p "$deb" "$member" | tar -tJf - ;;
        data.tar.gz) ar p "$deb" "$member" | tar -tzf - ;;
        data.tar.bz2) ar p "$deb" "$member" | tar -tjf - ;;
        data.tar.zst) ar p "$deb" "$member" | tar --zstd -tf - ;;
        data.tar.lzma) ar p "$deb" "$member" | tar --lzma -tf - ;;
        *) ar p "$deb" "$member" | tar -tf - ;;
    esac
}

manifest="$repo_root/vendor/SHA256SUMS"
[[ -r "$manifest" ]] || die "missing vendor manifest: $manifest"
(cd "$repo_root" && sha256sum --check vendor/SHA256SUMS) || die "vendor checksum validation failed"

radxa_dts="$repo_root/vendor/radxa/kernel/sc8280xp-radxa-dragon-q8b.dts"
[[ -r "$radxa_dts" ]] || die "missing Radxa Q8B DTS"
check_lock_hash radxa_kernel_dts_sha256 vendor/radxa/kernel/sc8280xp-radxa-dragon-q8b.dts
for marker in \
    'compatible = "radxa,dragon-q8b", "qcom,sc8280xp"' \
    'qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn' \
    'qcom/vpu/vpu20_p4_gen2_s6.mbn' \
    'QPS615' \
    'qcom,wcd9385-codec'; do
    grep -Fq "$marker" "$radxa_dts" || die "DTS is missing expected marker: $marker"
done

patch_dir="$repo_root/vendor/armbian/sc8280xp-edge-patches"
patch_manifest="$repo_root/config/armbian-sc8280xp-edge-patches.sha256"
[[ -d "$patch_dir" ]] || die "missing Armbian patch directory"
(cd "$patch_dir" && sha256sum --check "$patch_manifest") || \
    die "Armbian patch checksum validation failed"
while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    [[ -r "$patch_dir/$patch_name" ]] || die "patch listed but not vendored: $patch_name"
done < "$repo_root/config/armbian-sc8280xp-edge-patches.list"

firmware_archive="$repo_root/vendor/radxa/firmware/radxa-firmware-${RADXA_FIRMWARE_REF}.tar.gz"
overlays_archive="$repo_root/vendor/radxa/overlays/radxa-overlays-${RADXA_OVERLAYS_REF}.tar.gz"
alsa_deb="$repo_root/vendor/radxa/alsa/alsa-ucm-conf_${ALSA_UCM_VERSION}_all.deb"
[[ -r "$firmware_archive" ]] || die "missing Radxa firmware archive"
[[ -r "$overlays_archive" ]] || die "missing Radxa overlays archive"
[[ -r "$alsa_deb" ]] || die "missing ALSA UCM package"
tar -tzf "$firmware_archive" >/dev/null || die "invalid Radxa firmware archive"
tar -tzf "$overlays_archive" >/dev/null || die "invalid Radxa overlays archive"
archive_has_license "$firmware_archive" || die "Radxa firmware archive has no license file"
archive_has_license "$overlays_archive" || die "Radxa overlays archive has no license file"
check_lock_hash radxa_firmware_archive_sha256 \
    "vendor/radxa/firmware/radxa-firmware-${RADXA_FIRMWARE_REF}.tar.gz"
check_lock_hash radxa_overlays_archive_sha256 \
    "vendor/radxa/overlays/radxa-overlays-${RADXA_OVERLAYS_REF}.tar.gz"
alsa_data_member=$(ar t "$alsa_deb" | awk '
    /^data\.tar\./ && !found {print; found=1}
    END {if (!found) exit 1}
') || die "ALSA UCM package lacks a data archive"
list_deb_data "$alsa_deb" "$alsa_data_member" >/dev/null || \
    die "ALSA UCM data archive is unreadable"
list_deb_data "$alsa_deb" "$alsa_data_member" | awk -F/ '
    tolower($NF) ~ /^(copyright|license|copying)(\..*)?$/ {found=1}
    END {exit !found}
' || die "ALSA UCM package has no license or copyright file"
check_lock_hash alsa_ucm_deb_sha256 \
    "vendor/radxa/alsa/alsa-ucm-conf_${ALSA_UCM_VERSION}_all.deb"
check_lock_hash patch_manifest_sha256 config/armbian-sc8280xp-edge-patches.sha256

for spec in "$repo_root"/packaging/*/*.spec; do
    if grep -Eq '^Source[0-9]*:[[:space:]]+https?://' "$spec"; then
        die "remote Source URL remains in $spec"
    fi
done
for build_script in prepare-kernel-source.sh build-srpms.sh check-patch-redundancy.sh; do
    script="$repo_root/scripts/$build_script"
    if grep -Eq 'curl|raw\.githubusercontent\.com|github\.com/(radxa|armbian)' "$script"; then
        die "Radxa/Armbian source acquisition remains in $script"
    fi
done

echo "vendored source inputs are complete and checksummed"
