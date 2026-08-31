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
: "${FASTRPC_TAG:?missing FASTRPC_TAG in config/dragon-q8b.env}"
: "${QAIRT_VERSION:?missing QAIRT_VERSION in config/dragon-q8b.env}"
: "${QAIRT_DOWNLOAD_URL:?missing QAIRT_DOWNLOAD_URL in config/dragon-q8b.env}"
: "${QAIRT_ARCHIVE_SHA256:?missing QAIRT_ARCHIVE_SHA256 in config/dragon-q8b.env}"
: "${QAIRT_LICENSE_SHA256:?missing QAIRT_LICENSE_SHA256 in config/dragon-q8b.env}"
: "${QAIRT_TARGET:?missing QAIRT_TARGET in config/dragon-q8b.env}"
: "${QAIRT_DSP_ARCH:?missing QAIRT_DSP_ARCH in config/dragon-q8b.env}"

output=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output=${2:?missing output file}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for command in awk cp curl find git grep jq mktemp rm rsync sha256sum sort tar unzip; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done
# shellcheck disable=SC1091
source "$repo_root/scripts/qairt-catalog.sh"

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

ensure_qcom_no_battery() {
    local dts=$1
    grep -Fq 'qcom,no-battery' "$dts" && return 0
    awk '
        /compatible = "radxa,batteryless-pmic-glink"/ && !done {
            print
            print "\t\tqcom,no-battery;"
            done=1
            next
        }
        {print}
    ' "$dts" > "$dts.tmp"
    mv "$dts.tmp" "$dts"
    grep -Fq 'qcom,no-battery' "$dts" || {
        echo "failed to insert qcom,no-battery into $dts" >&2
        exit 1
    }
}

github_json() {
    local url=$1 dest=$2
    local -a curl_args=(--fail --silent --show-error --location --retry 4 --retry-all-errors)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl "${curl_args[@]}" -H "Accept: application/vnd.github+json" \
        "$url" --output "$dest"
}

radxa_kernel_ref=$(resolve_ref "$RADXA_KERNEL_REPO" "refs/heads/$RADXA_KERNEL_BRANCH")
radxa_firmware_ref=$(resolve_ref "$RADXA_FIRMWARE_REPO" refs/heads/main)
radxa_overlays_ref=$(resolve_ref "$RADXA_OVERLAYS_REPO" refs/heads/main)
armbian_ref=$(resolve_ref "$ARMBIAN_BUILD_REPO" refs/heads/main)
fastrpc_ref=$(resolve_ref "$FASTRPC_REPO" "refs/tags/${FASTRPC_TAG}")
[[ -n "$fastrpc_ref" ]] || fastrpc_ref=$(resolve_ref "$FASTRPC_REPO" "refs/tags/${FASTRPC_TAG}^{}")
for value_name in radxa_kernel_ref radxa_firmware_ref radxa_overlays_ref armbian_ref fastrpc_ref; do
    [[ -n "${!value_name}" ]] || {
        echo "could not resolve $value_name" >&2
        exit 1
    }
done

fedora_kernel_repo=https://src.fedoraproject.org/rpms/kernel.git
fedora_kernel_branch="f${FEDORA_RELEASE}"
fedora_kernel_commit=$(resolve_ref "$fedora_kernel_repo" "refs/heads/${fedora_kernel_branch}")
[[ -n "$fedora_kernel_commit" ]] || {
    echo "could not resolve Fedora kernel ${fedora_kernel_branch}" >&2
    exit 1
}
download \
    "https://src.fedoraproject.org/rpms/kernel/raw/${fedora_kernel_commit}/f/kernel.spec" \
    "$work_dir/kernel.spec"
fedora_kernel_version=$(awk '/^%define specrpmversion / && !seen {print $3; seen=1}' \
    "$work_dir/kernel.spec")
[[ -n "$fedora_kernel_version" ]] || {
    echo "could not parse Fedora kernel version from ${fedora_kernel_commit}" >&2
    exit 1
}
echo "Fedora ${fedora_kernel_branch} kernel ${fedora_kernel_version} at ${fedora_kernel_commit}"

radxa_dts="$stage/vendor/radxa/kernel/sc8280xp-radxa-dragon-q8b.dts"
download \
    "https://raw.githubusercontent.com/radxa/kernel/${radxa_kernel_ref}/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts" \
    "$radxa_dts"
ensure_qcom_no_battery "$radxa_dts"
for marker in \
    'compatible = "radxa,dragon-q8b", "qcom,sc8280xp"' \
    'qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn' \
    'qcom/vpu/vpu20_p4_gen2_s6.mbn' \
    'QPS615' \
    'qcom,wcd9385-codec' \
    'qcom,no-battery'; do
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

fastrpc_version=${FASTRPC_TAG#v}
fastrpc_archive="$stage/vendor/qualcomm/fastrpc/fastrpc-${fastrpc_version}.tar.gz"
download "${FASTRPC_REPO%.git}/archive/refs/tags/${FASTRPC_TAG}.tar.gz" \
    "$fastrpc_archive"
tar -tzf "$fastrpc_archive" >/dev/null
archive_has_license "$fastrpc_archive" || {
    echo "Qualcomm FastRPC archive has no license file" >&2
    exit 1
}

# Compare Armbian's sc8280xp-edge directory to the pinned list. Extra patches
# (0036+) must not be ignored; the Armbian Q8B DTS patch is a known exclusion.
armbian_dir_json="$work_dir/armbian-dir.json"
github_json \
    "https://api.github.com/repos/armbian/build/contents/${ARMBIAN_PATCH_DIR}?ref=${armbian_ref}" \
    "$armbian_dir_json"
armbian_dts_patch=0005-arm64-dts-sc8280xp-add-radxa-dragon-q8b.patch
mapfile -t upstream_patches < <(jq -r --arg skip "$armbian_dts_patch" '
    .[] | select(.type == "file" and (.name | endswith(".patch")) and .name != $skip) | .name
' "$armbian_dir_json" | LC_ALL=C sort)
mapfile -t listed_patches < <(awk 'NF && $1 !~ /^#/ {print}' \
    "$repo_root/config/armbian-sc8280xp-edge-patches.list" | LC_ALL=C sort)
upstream_joined=$(printf '%s\n' "${upstream_patches[@]}")
listed_joined=$(printf '%s\n' "${listed_patches[@]}")
extra=$(comm -13 <(printf '%s\n' "$listed_joined") <(printf '%s\n' "$upstream_joined") || true)
missing=$(comm -23 <(printf '%s\n' "$listed_joined") <(printf '%s\n' "$upstream_joined") || true)
if [[ -n "$extra" || -n "$missing" ]]; then
    echo "Armbian ${ARMBIAN_PATCH_DIR} at ${armbian_ref} does not match config/armbian-sc8280xp-edge-patches.list" >&2
    [[ -n "$extra" ]] && printf 'added in Armbian (update the list or drop):\n%s\n' "$extra" >&2
    [[ -n "$missing" ]] && printf 'listed but removed upstream:\n%s\n' "$missing" >&2
    exit 1
fi

patch_dir="$stage/vendor/armbian/sc8280xp-edge-patches"
mkdir -p "$patch_dir"
patch_manifest="$stage/config/armbian-sc8280xp-edge-patches.sha256"
mkdir -p "$(dirname "$patch_manifest")"
: > "$patch_manifest"
patch_base_url="https://raw.githubusercontent.com/armbian/build/${armbian_ref}/${ARMBIAN_PATCH_DIR}"
while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    [[ "$patch_name" != "$armbian_dts_patch" ]] || {
        echo "refusing to download the Armbian Q8B DTS patch; Radxa is authoritative" >&2
        exit 1
    }
    patch_file="$patch_dir/$patch_name"
    echo "Downloading Armbian patch $patch_name"
    download "${patch_base_url}/${patch_name}" "$patch_file"
    printf '%s  %s\n' "$(sha256_file "$patch_file")" "$patch_name" >> "$patch_manifest"
done < "$repo_root/config/armbian-sc8280xp-edge-patches.list"

alsa_release_json="$work_dir/alsa-release.json"
download "${ALSA_UCM_API}/releases/latest" "$alsa_release_json"
alsa_version=$(jq -er '.tag_name | select(type == "string" and length > 0)' "$alsa_release_json")
alsa_clone="$work_dir/alsa-ucm-conf"
echo "Cloning Radxa ALSA UCM ${alsa_version} with submodule"
git clone --depth=1 --branch "$alsa_version" --recurse-submodules \
    "$ALSA_UCM_REPO" "$alsa_clone"
[[ -d "$alsa_clone/src/ucm2" ]] || {
    echo "ALSA UCM git checkout is missing src/ucm2 (submodule)" >&2
    exit 1
}
alsa_export="$work_dir/alsa-export/alsa-ucm-conf-${alsa_version}"
mkdir -p "$alsa_export"
rsync -a --exclude '.git' "$alsa_clone/" "$alsa_export/"
alsa_archive="$stage/vendor/radxa/alsa/alsa-ucm-conf-${alsa_version}.tar.gz"
tar -C "$work_dir/alsa-export" -czf "$alsa_archive" "alsa-ucm-conf-${alsa_version}"
archive_has_license "$alsa_archive" || {
    echo "ALSA UCM git archive has no license file" >&2
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
replace_config "$config_file" FASTRPC_TAG "$FASTRPC_TAG"
replace_config "$config_file" FASTRPC_VERSION "$fastrpc_version"
replace_config "$config_file" FEDORA_KERNEL_COMMIT "$fedora_kernel_commit"
replace_config "$config_file" FEDORA_KERNEL_VERSION "$fedora_kernel_version"

echo "Resolving latest QAIRT Community Edition from Qualcomm Software Center"
qairt_version=$(qairt_catalog_latest)
qairt_url=$(qairt_zip_url "$qairt_version")
qairt_target=$QAIRT_TARGET
qairt_dsp_arch=${QAIRT_DSP_ARCH:-68}
qairt_archive_sha256=$QAIRT_ARCHIVE_SHA256
qairt_license_sha256=$QAIRT_LICENSE_SHA256
if [[ "$qairt_version" != "$QAIRT_VERSION" || ! "$qairt_archive_sha256" =~ ^[0-9a-f]{64}$ || "$qairt_archive_sha256" =~ ^0{64}$ ]]; then
    echo "Downloading QAIRT $qairt_version to verify HTP v68 runtime and checksums"
    qairt_zip="$work_dir/v${qairt_version}.zip"
    download "$qairt_url" "$qairt_zip"
    qairt_archive_sha256=$(sha256_file "$qairt_zip")
    qairt_target=$(qairt_pick_target "$qairt_zip" "$qairt_version") || {
        echo "QAIRT $qairt_version is missing Hexagon v68 or an aarch64-oe-linux-gcc* runtime" >&2
        exit 1
    }
    qairt_license_sha256=$(unzip -p "$qairt_zip" "qairt/${qairt_version}/LICENSE.pdf" | sha256sum | awk '{print $1}')
    rm -f "$qairt_zip"
fi
replace_config "$config_file" QAIRT_VERSION "$qairt_version"
replace_config "$config_file" QAIRT_DOWNLOAD_URL "$qairt_url"
replace_config "$config_file" QAIRT_ARCHIVE_SHA256 "$qairt_archive_sha256"
replace_config "$config_file" QAIRT_LICENSE_SHA256 "$qairt_license_sha256"
replace_config "$config_file" QAIRT_TARGET "$qairt_target"
replace_config "$config_file" QAIRT_DSP_ARCH "$qairt_dsp_arch"

# SHA256SUMS covers staged source inputs only. vendor/README.md is human
# documentation and must not be mixed into the integrity manifest.
manifest="$stage/vendor/SHA256SUMS"
(cd "$stage" && find vendor -type f ! -path vendor/SHA256SUMS ! -name README.md -print | LC_ALL=C sort | \
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
ALSA_UCM_ARCHIVE=$(basename "$alsa_archive")
ALSA_UCM_ARCHIVE_SHA256=$(sha256_file "$alsa_archive")
ARMBIAN_REF=$armbian_ref
PATCH_MANIFEST_SHA256=$(sha256_file "$patch_manifest")
FASTRPC_REF=$fastrpc_ref
FASTRPC_TAG=$FASTRPC_TAG
FASTRPC_VERSION=$fastrpc_version
FASTRPC_ARCHIVE=vendor/qualcomm/fastrpc/fastrpc-${fastrpc_version}.tar.gz
FASTRPC_ARCHIVE_SHA256=$(sha256_file "$fastrpc_archive")
QAIRT_VERSION=$qairt_version
QAIRT_DOWNLOAD_URL=$qairt_url
QAIRT_ARCHIVE_SHA256=$qairt_archive_sha256
QAIRT_LICENSE_SHA256=$qairt_license_sha256
QAIRT_TARGET=$qairt_target
QAIRT_DSP_ARCH=$qairt_dsp_arch
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
