#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: prepare-kernel-source.sh --output DIR [--release N]

Prepare a Fedora kernel dist-git checkout for a Dragon Q8B build.
The output directory contains a Fedora kernel source tree with the pinned
SC8280XP/Q8B patch series copied aside, kernel-local from config/kernel-local,
and a separate DTS patch. The combined COPR patch is written later by
check-patch-redundancy.sh from REQUIRED patches plus that DTS patch.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

ARMBIAN_REF=${ARMBIAN_REF_OVERRIDE:-$ARMBIAN_REF}
RADXA_KERNEL_REF=${RADXA_KERNEL_REF_OVERRIDE:-$RADXA_KERNEL_REF}
RADXA_FIRMWARE_REF=${RADXA_FIRMWARE_REF_OVERRIDE:-$RADXA_FIRMWARE_REF}
UPDATE_PATCH_MANIFEST=${UPDATE_PATCH_MANIFEST:-0}
default_build_id=dragonq8b.local
if git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
    commit_time=$(git -C "$repo_root" show -s --format=%ct HEAD)
    commit_id=$(git -C "$repo_root" rev-parse --short=12 HEAD)
    default_build_id="dragonq8b.${commit_time}.${commit_id}"
fi
KERNEL_BUILD_ID=${KERNEL_BUILD_ID_OVERRIDE:-$default_build_id}
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

for command in git awk sed grep patch cp find mkdir sha256sum; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

radxa_dts_file="$repo_root/vendor/radxa/kernel/sc8280xp-radxa-dragon-q8b.dts"
kernel_local_file="$repo_root/config/kernel-local"
armbian_patch_dir="$repo_root/vendor/armbian/sc8280xp-edge-patches"
armbian_dts_patch=0005-arm64-dts-sc8280xp-add-radxa-dragon-q8b.patch
[[ -r "$radxa_dts_file" ]] || {
    echo "missing vendored Radxa Q8B DTS: $radxa_dts_file" >&2
    exit 1
}
[[ -r "$kernel_local_file" ]] || {
    echo "missing kernel-local fragment: $kernel_local_file" >&2
    exit 1
}
[[ -d "$armbian_patch_dir" ]] || {
    echo "missing vendored Armbian patch directory: $armbian_patch_dir" >&2
    exit 1
}
if grep -Fxq "$armbian_dts_patch" "$repo_root/config/armbian-sc8280xp-edge-patches.list" || \
        [[ -e "$armbian_patch_dir/$armbian_dts_patch" ]]; then
    echo "the Q8B DTS must come only from Radxa; remove the Armbian DTS patch" >&2
    exit 1
fi

radxa_dts=$(<"$radxa_dts_file")
for marker in \
    'compatible = "radxa,dragon-q8b", "qcom,sc8280xp"' \
    'qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn' \
    'qcom/vpu/vpu20_p4_gen2_s6.mbn' \
    'QPS615' \
    'qcom,wcd9385-codec' \
    'qcom,no-battery'; do
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
fedora_kernel_version=$(awk '/^%define specrpmversion / && !seen {print $3; seen=1}' \
    "$kernel_dir/kernel.spec")
[[ -n "$fedora_kernel_version" ]] || {
    echo "could not parse Fedora kernel version" >&2
    exit 1
}

manifest="$repo_root/config/armbian-sc8280xp-edge-patches.sha256"
manifest_for_build="$output/armbian-sc8280xp-edge-patches.sha256"
cp "$manifest" "$manifest_for_build"
list="$repo_root/config/armbian-sc8280xp-edge-patches.list"

while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    destination="$patch_dir/$patch_name"
    echo "Copying vendored ${patch_name}"
    [[ -r "$armbian_patch_dir/$patch_name" ]] || {
        echo "patch listed but not vendored: $patch_name" >&2
        exit 1
    }
    cp "$armbian_patch_dir/$patch_name" "$destination"
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

# Separate DTS patch: new-file insert of the Radxa board DTS only. The Fedora
# qcom Makefile hunk is generated later from the actual post-%prep Makefile
# in check-patch-redundancy.sh so it is not frozen to a line number.
dts_lines=$(awk 'END {print NR}' "$radxa_dts_file")
dts_patch="$kernel_dir/dragon-q8b-dts.patch"
{
cat <<EOF
diff --git a/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts b/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts
new file mode 100644
--- /dev/null
+++ b/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts
@@ -0,0 +1,${dts_lines} @@
EOF
sed 's/^/+/' "$radxa_dts_file"
printf '\n'
} > "$dts_patch"

cp "$kernel_local_file" "$kernel_dir/kernel-local"

spec="$kernel_dir/kernel.spec"
grep -q '^Patch3003: dragon-q8b-kernel.patch$' "$spec" || \
    sed -i '/^Patch999999: linux-kernel-test.patch$/i Patch3003: dragon-q8b-kernel.patch' "$spec"
# Combined patch is non-empty (REQUIRED + DTS). Use ApplyPatch so Fedora does
# not skip it; ApplyOptionalPatch is only for empty files.
if grep -q '^ApplyOptionalPatch dragon-q8b-kernel.patch$' "$spec"; then
    sed -i 's/^ApplyOptionalPatch dragon-q8b-kernel.patch$/ApplyPatch dragon-q8b-kernel.patch/' "$spec"
fi
grep -q '^ApplyPatch dragon-q8b-kernel.patch$' "$spec" || \
    sed -i '/^ApplyOptionalPatch linux-kernel-test.patch$/a ApplyPatch dragon-q8b-kernel.patch' "$spec"

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
FEDORA_KERNEL_VERSION=$fedora_kernel_version
RADXA_KERNEL_REF=$RADXA_KERNEL_REF
RADXA_KERNEL_DTS_SHA256=$(sha256_file "$radxa_dts_file")
RADXA_FIRMWARE_REF=$RADXA_FIRMWARE_REF
ARMBIAN_REF=$ARMBIAN_REF
KERNEL_BUILD_ID=$KERNEL_BUILD_ID
PATCH_MANIFEST=$manifest_for_build
DTS_PATCH=$dts_patch
EOF

echo "Prepared Fedora kernel source: $kernel_dir"
echo "Fedora commit: $fedora_commit"
echo "DTS patch: $dts_patch"
echo "Patch manifest: $manifest"
echo "Run check-patch-redundancy.sh to write dragon-q8b-kernel.patch (REQUIRED + DTS + Makefile hunk)."
