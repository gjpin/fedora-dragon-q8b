#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: prepare-kernel-source.sh --output DIR [--release N]

Prepare a Fedora kernel dist-git checkout for a Dragon Q8B build.
The output directory contains a Fedora kernel source tree with the pinned
SC8280XP/Q8B patch series and kernel-local configuration fragment.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

ARMBIAN_REF=${ARMBIAN_REF_OVERRIDE:-$ARMBIAN_REF}
RADXA_KERNEL_REF=${RADXA_KERNEL_REF_OVERRIDE:-$RADXA_KERNEL_REF}
RADXA_FIRMWARE_REF=${RADXA_FIRMWARE_REF_OVERRIDE:-$RADXA_FIRMWARE_REF}
UPDATE_PATCH_MANIFEST=${UPDATE_PATCH_MANIFEST:-0}
KERNEL_BUILD_ID=${KERNEL_BUILD_ID_OVERRIDE:-dragonq8b}
[[ "$KERNEL_BUILD_ID" =~ ^[A-Za-z0-9._+]+$ ]] || {
    echo "invalid KERNEL_BUILD_ID_OVERRIDE: $KERNEL_BUILD_ID" >&2
    exit 2
}

output=
release=${FEDORA_RELEASE:-44}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output=${2:?missing output directory}; shift 2 ;;
        --release) release=${2:?missing Fedora release}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$output" ]] || { usage >&2; exit 2; }

for command in git curl awk sed grep patch; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

radxa_dts_url="https://raw.githubusercontent.com/radxa/kernel/${RADXA_KERNEL_REF}/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts"
radxa_dts=$(curl --fail --silent --show-error --location --retry 4 --retry-all-errors "$radxa_dts_url")
for marker in \
    'compatible = "radxa,dragon-q8b", "qcom,sc8280xp"' \
    'qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn' \
    'qcom/vpu/vpu20_p4_gen2_s6.mbn' \
    'QPS615' \
    'qcom,wcd9385-codec'; do
    grep -Fq "$marker" <<<"$radxa_dts" || {
        echo "Radxa Q8B DTS is missing expected marker: $marker" >&2
        exit 1
    }
done

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

mkdir -p "$output"
kernel_dir="$output/kernel"
patch_dir="$output/dragon-q8b-patches"
if [[ -e "$kernel_dir" ]]; then
    echo "refusing to overwrite existing kernel source: $kernel_dir" >&2
    exit 1
fi
mkdir -p "$patch_dir"

fedora_repo=https://src.fedoraproject.org/rpms/kernel.git
fedora_branch="f${release}"
echo "Cloning Fedora kernel dist-git ${fedora_branch}"
git clone --depth=1 --branch "$fedora_branch" "$fedora_repo" "$kernel_dir"
fedora_commit=$(git -C "$kernel_dir" rev-parse HEAD)

patch_base_url="https://raw.githubusercontent.com/armbian/build/${ARMBIAN_REF}/${ARMBIAN_PATCH_DIR}"
manifest="$repo_root/config/armbian-sc8280xp-edge-patches.sha256"
manifest_for_build="$output/armbian-sc8280xp-edge-patches.sha256"
cp "$manifest" "$manifest_for_build"
list="$repo_root/config/armbian-sc8280xp-edge-patches.list"

while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    destination="$patch_dir/$patch_name"
    echo "Downloading ${patch_name}"
    curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
        "${patch_base_url}/${patch_name}" --output "$destination"
    expected=$(awk -v name="$patch_name" '$2 == name {print $1}' "$manifest_for_build")
    [[ -n "$expected" ]] || {
        if [[ "$UPDATE_PATCH_MANIFEST" != 1 ]]; then
            echo "no checksum in manifest for $patch_name" >&2
            exit 1
        fi
        actual=$(sha256_file "$destination")
        printf '%s  %s\n' "$actual" "$patch_name" >> "$manifest_for_build"
        expected=$actual
    }
    actual=$(sha256_file "$destination")
    if [[ "$actual" != "$expected" ]]; then
        if [[ "$UPDATE_PATCH_MANIFEST" != 1 ]]; then
            echo "checksum mismatch for $patch_name: ${actual} != ${expected}" >&2
            exit 1
        fi
        echo "updating generated patch checksum for $patch_name"
        awk -v name="$patch_name" -v checksum="$actual" \
            '$2 == name {$1=checksum} {print}' "$manifest_for_build" \
            > "$manifest_for_build.tmp"
        mv "$manifest_for_build.tmp" "$manifest_for_build"
    fi
done < "$list"

combined_patch="$kernel_dir/dragon-q8b-kernel.patch"
: > "$combined_patch"
while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    cat "$patch_dir/$patch_name" >> "$combined_patch"
    printf '\n' >> "$combined_patch"
done < "$list"

# Fedora's kernel spec intentionally uses kernel-local for downstream config
# fragments. Keep the fragment small and let Fedora's config merger validate
# symbols that are not available in a particular release.
cat > "$kernel_dir/kernel-local" <<'EOF'
# Dragon Q8B / Qualcomm SC8280XP support.
CONFIG_OF_OVERLAY=y
CONFIG_EFI=y
CONFIG_EFI_ZBOOT=n
CONFIG_MODULE_COMPRESS_ZSTD=y
CONFIG_MODULE_COMPRESS_XZ=n

# Drivers needed before rootfs availability or by Q8B firmware hand-off.
CONFIG_QCOM_Q6V5_PAS=y
CONFIG_QCOM_PDR_HELPERS=y
CONFIG_QCOM_QMI_HELPERS=y
CONFIG_QCOM_GLINK=y
CONFIG_QCOM_GLINK_SMEM=y
CONFIG_QCOM_RPROC_COMMON=y
CONFIG_QCOM_PMIC_GLINK=y
CONFIG_QCOM_QRNG=y
CONFIG_QCOM_SMEM=y
CONFIG_QCOM_SPMI_ADC5=y
CONFIG_QCOM_SPMI_TEMP_ALARM=y
CONFIG_QCOM_SPMI_VADC=y
CONFIG_QCOM_SPMI_VADC5_GEN3=y
CONFIG_QCOM_STATS=y
CONFIG_QCOM_WCNSS_CTRL=y
CONFIG_QCOM_WCNSS_PIL=y
CONFIG_QCOM_FASTRPC=y
CONFIG_QCOM_RPMH=y
CONFIG_QCOM_RPMHPD=y
CONFIG_QCOM_SCM=y
CONFIG_QCOM_COMMAND_DB=y
CONFIG_QCOM_LLCC=y
CONFIG_QCOM_OCMEM=y

CONFIG_PHY_QCOM_QMP=y
CONFIG_PHY_QCOM_QMP_PCIE=y
CONFIG_PHY_QCOM_QMP_USB=y
CONFIG_PHY_QCOM_USB_HS=y
CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2=y
CONFIG_USB_DWC3=y
CONFIG_USB_DWC3_DUAL_ROLE=y
CONFIG_USB_DWC3_QCOM=y
CONFIG_USB_DWC3_OF_SIMPLE=y

CONFIG_PCIE_QCOM=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_MSM=y
CONFIG_SCSI_UFSHCD=y
CONFIG_SCSI_UFSHCD_PLATFORM=y
CONFIG_SCSI_UFS_QCOM=y

CONFIG_SOUNDWIRE=y
CONFIG_SOUNDWIRE_QCOM=y
CONFIG_SND_SOC_QCOM=y
CONFIG_SND_SOC_WCD938X=y
CONFIG_SND_SOC_SC8280XP=y

CONFIG_DRM_MSM=y
CONFIG_DRM_MSM_HDMI=y
CONFIG_DRM_MSM_DPU=y
CONFIG_DRM_DP_AUX_CHARDEV=y
CONFIG_DRM_PANEL_BRIDGE=y

CONFIG_VIDEO_QCOM_IRIS=y
CONFIG_VIDEO_QCOM_VENUS=y
CONFIG_QCOM_TSENS=y
CONFIG_QCOM_SPMI_TEMP_ALARM=y
CONFIG_GPIO_REGMAP=y
CONFIG_GPIO_QCOM=y
CONFIG_GPIO_TC956X=y
CONFIG_TOSHIBA_TC956X_PCI=y
CONFIG_DWMAC_TC956X=y
CONFIG_I2C_QUP=y
CONFIG_SPI_QUP=y
CONFIG_SERIAL_QCOM_GENI=y
CONFIG_SERIAL_QCOM_GENI_CONSOLE=y
EOF

spec="$kernel_dir/kernel.spec"
grep -q '^Patch3003: dragon-q8b-kernel.patch$' "$spec" || \
    sed -i '/^Patch999999: linux-kernel-test.patch$/i Patch3003: dragon-q8b-kernel.patch' "$spec"
grep -q '^ApplyOptionalPatch dragon-q8b-kernel.patch$' "$spec" || \
    sed -i '/^ApplyOptionalPatch linux-kernel-test.patch$/a ApplyOptionalPatch dragon-q8b-kernel.patch' "$spec"

# Fedora's documented buildid mechanism makes the package distinguishable
# from the stock kernel while preserving the normal kernel subpackage names.
sed -i "s/^# define buildid \.local$/%define buildid .$KERNEL_BUILD_ID/" "$spec"
grep -q "^%define buildid \\.${KERNEL_BUILD_ID}$" "$spec" || {
    echo "could not set Fedora kernel buildid" >&2
    exit 1
}

cat > "$output/source-metadata.env" <<EOF
FEDORA_RELEASE=$release
FEDORA_KERNEL_BRANCH=$fedora_branch
FEDORA_KERNEL_COMMIT=$fedora_commit
RADXA_KERNEL_REF=$RADXA_KERNEL_REF
RADXA_KERNEL_DTS_SHA256=$(printf '%s\n' "$radxa_dts" | if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | awk '{print $1}')
RADXA_FIRMWARE_REF=$RADXA_FIRMWARE_REF
ARMBIAN_REF=$ARMBIAN_REF
KERNEL_BUILD_ID=$KERNEL_BUILD_ID
PATCH_MANIFEST=$manifest_for_build
EOF

echo "Prepared Fedora kernel source: $kernel_dir"
echo "Fedora commit: $fedora_commit"
echo "Patch manifest: $manifest"
