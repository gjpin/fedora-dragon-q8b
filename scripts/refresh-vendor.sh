#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: refresh-vendor.sh [--output FILE]

Resolve current upstream revisions, stage all project-specific source inputs,
and update the repository vendor tree and source lock.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"
: "${ALSA_UCM_API:?missing ALSA_UCM_API in config/dragon-q8b.env}"

output=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output=${2:?missing output file}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for command in ar awk cp curl find git grep jq mktemp rm sha256sum sort tar; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

work_dir=$(mktemp -d -t dragon-q8b-vendor.XXXXXX)
stage="$work_dir/stage"
mkdir -p "$stage/vendor"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

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

resolve_ref() {
    local repo=$1 ref=$2
    git ls-remote "$repo" "$ref" | awk 'NR == 1 {print $1}'
}

download() {
    local url=$1 destination=$2
    mkdir -p "$(dirname "$destination")"
    curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
        "$url" --output "$destination"
}

replace_config() {
    local file=$1 key=$2 value=$3 temp
    temp="$file.tmp"
    awk -v key="$key" -v value="$value" '
        $0 ~ "^" key "=" {print key "=" value; found=1; next}
        {print}
        END {if (!found) print key "=" value}
    ' "$file" > "$temp"
    mv "$temp" "$file"
}

radxa_kernel_ref=$(resolve_ref "$RADXA_KERNEL_REPO" "refs/heads/$RADXA_KERNEL_BRANCH")
radxa_firmware_ref=$(resolve_ref "$RADXA_FIRMWARE_REPO" refs/heads/main)
radxa_overlays_ref=$(resolve_ref "$RADXA_OVERLAYS_REPO" refs/heads/main)
armbian_ref=$(resolve_ref "$ARMBIAN_BUILD_REPO" refs/heads/main)
fastrpc_ref=$(resolve_ref "$FASTRPC_REPO" refs/heads/main)
for value_name in radxa_kernel_ref radxa_firmware_ref radxa_overlays_ref armbian_ref fastrpc_ref; do
    [[ -n "${!value_name}" ]] || {
        echo "could not resolve $value_name" >&2
        exit 1
    }
done

radxa_dts="$stage/vendor/radxa/kernel/sc8280xp-radxa-dragon-q8b.dts"
download \
    "https://raw.githubusercontent.com/radxa/kernel/${radxa_kernel_ref}/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts" \
    "$radxa_dts"
for marker in \
    'compatible = "radxa,dragon-q8b", "qcom,sc8280xp"' \
    'qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn' \
    'qcom/vpu/vpu20_p4_gen2_s6.mbn' \
    'QPS615' \
    'qcom,wcd9385-codec'; do
    grep -Fq "$marker" "$radxa_dts" || {
        echo "Radxa Q8B DTS is missing expected marker: $marker" >&2
        exit 1
    }
done

firmware_archive="$stage/vendor/radxa/firmware/radxa-firmware-${radxa_firmware_ref}.tar.gz"
download "${RADXA_FIRMWARE_REPO%.git}/archive/${radxa_firmware_ref}.tar.gz" \
    "$firmware_archive"
tar -tzf "$firmware_archive" >/dev/null
archive_has_license "$firmware_archive" || {
    echo "Radxa firmware archive has no license file" >&2
    exit 1
}

overlays_archive="$stage/vendor/radxa/overlays/radxa-overlays-${radxa_overlays_ref}.tar.gz"
download "${RADXA_OVERLAYS_REPO%.git}/archive/${radxa_overlays_ref}.tar.gz" \
    "$overlays_archive"
tar -tzf "$overlays_archive" >/dev/null
archive_has_license "$overlays_archive" || {
    echo "Radxa overlays archive has no license file" >&2
    exit 1
}

fastrpc_archive="$stage/vendor/qualcomm/fastrpc/fastrpc-${fastrpc_ref}.tar.gz"
download "${FASTRPC_REPO%.git}/archive/${fastrpc_ref}.tar.gz" \
    "$fastrpc_archive"
tar -tzf "$fastrpc_archive" >/dev/null
archive_has_license "$fastrpc_archive" || {
    echo "Qualcomm FastRPC archive has no license file" >&2
    exit 1
}

patch_dir="$stage/vendor/armbian/sc8280xp-edge-patches"
mkdir -p "$patch_dir"
patch_manifest="$stage/config/armbian-sc8280xp-edge-patches.sha256"
mkdir -p "$(dirname "$patch_manifest")"
: > "$patch_manifest"
patch_base_url="https://raw.githubusercontent.com/armbian/build/${armbian_ref}/${ARMBIAN_PATCH_DIR}"
while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    patch_file="$patch_dir/$patch_name"
    echo "Downloading Armbian patch $patch_name"
    download "${patch_base_url}/${patch_name}" "$patch_file"
    printf '%s  %s\n' "$(sha256_file "$patch_file")" "$patch_name" >> "$patch_manifest"
done < "$repo_root/config/armbian-sc8280xp-edge-patches.list"

alsa_release_json="$work_dir/alsa-release.json"
download "${ALSA_UCM_API}/releases/latest" \
    "$alsa_release_json"
alsa_version=$(jq -er '.tag_name | select(type == "string" and length > 0)' "$alsa_release_json")
alsa_file=$(jq -er --arg version "$alsa_version" \
    '.assets[] | select(.name == ("alsa-ucm-conf_" + $version + "_all.deb")) | .name' \
    "$alsa_release_json")
alsa_url=$(jq -er --arg name "$alsa_file" \
    '.assets[] | select(.name == $name) | .browser_download_url' "$alsa_release_json")
alsa_deb="$stage/vendor/radxa/alsa/$alsa_file"
download "$alsa_url" "$alsa_deb"
alsa_data_member=$(ar t "$alsa_deb" | awk '
    /^data\.tar\./ && !found {print; found=1}
    END {if (!found) exit 1}
')
list_deb_data "$alsa_deb" "$alsa_data_member" >/dev/null || {
    echo "ALSA UCM package contains an unreadable data archive: $alsa_file" >&2
    exit 1
}
list_deb_data "$alsa_deb" "$alsa_data_member" | awk -F/ '
    tolower($NF) ~ /^(copyright|license|copying)(\..*)?$/ {found=1}
    END {exit !found}
' || {
    echo "ALSA UCM package has no license or copyright file: $alsa_file" >&2
    exit 1
}

config_file="$stage/dragon-q8b.env"
cp "$repo_root/config/dragon-q8b.env" "$config_file"
replace_config "$config_file" RADXA_KERNEL_REF "$radxa_kernel_ref"
replace_config "$config_file" RADXA_FIRMWARE_REF "$radxa_firmware_ref"
replace_config "$config_file" RADXA_OVERLAYS_REF "$radxa_overlays_ref"
replace_config "$config_file" ARMBIAN_REF "$armbian_ref"
replace_config "$config_file" ALSA_UCM_VERSION "$alsa_version"
replace_config "$config_file" FASTRPC_REF "$fastrpc_ref"

manifest="$stage/vendor/SHA256SUMS"
(cd "$stage" && find vendor -type f ! -path vendor/SHA256SUMS -print | LC_ALL=C sort | \
    while IFS= read -r path; do sha256sum "$path"; done) > "$manifest"

env_file="$work_dir/current-inputs.env"
cat > "$env_file" <<EOF
RADXA_KERNEL_REF=$radxa_kernel_ref
RADXA_KERNEL_DTS_SHA256=$(sha256_file "$radxa_dts")
RADXA_FIRMWARE_REF=$radxa_firmware_ref
RADXA_FIRMWARE_ARCHIVE_SHA256=$(sha256_file "$firmware_archive")
RADXA_OVERLAYS_REF=$radxa_overlays_ref
RADXA_OVERLAYS_ARCHIVE_SHA256=$(sha256_file "$overlays_archive")
ALSA_UCM_VERSION=$alsa_version
ALSA_UCM_DEB=$(basename "$alsa_deb")
ALSA_UCM_DEB_SHA256=$(sha256_file "$alsa_deb")
ARMBIAN_REF=$armbian_ref
PATCH_MANIFEST_SHA256=$(sha256_file "$patch_manifest")
FASTRPC_REF=$fastrpc_ref
FASTRPC_ARCHIVE_SHA256=$(sha256_file "$fastrpc_archive")
EOF

mkdir -p "$repo_root/vendor"
for component in radxa armbian qualcomm; do
    rm -rf "$repo_root/vendor/$component"
    cp -a "$stage/vendor/$component" "$repo_root/vendor/"
done
cp "$stage/vendor/SHA256SUMS" "$repo_root/vendor/SHA256SUMS"
cp "$patch_manifest" "$repo_root/config/armbian-sc8280xp-edge-patches.sha256"
cp "$config_file" "$repo_root/config/dragon-q8b.env"
bash "$repo_root/scripts/update-input-lock.sh" --env "$env_file"

changed=0
if git -C "$repo_root" status --short --untracked-files=all -- \
    vendor config/dragon-q8b.env config/armbian-sc8280xp-edge-patches.sha256 \
    packaging/inputs.lock | grep -q .; then
    changed=1
fi
printf 'REFRESH_CHANGED=%s\n' "$changed" >> "$env_file"
if [[ -n "$output" ]]; then
    cp "$env_file" "$output"
fi

echo "Vendored source refresh complete; changed=$changed"
