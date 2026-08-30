#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: build-srpms.sh --output DIR [--source-dir DIR] [--release N] [--packages "PKG..."]

Build the prepared Fedora kernel SRPM and/or the Dragon Q8B support SRPMs.
This script is intended for Fedora/COPR builders.

Options:
  --output DIR          Destination directory for generated .src.rpm files (required)
  --source-dir DIR      Fedora kernel source tree directory (required if building kernel)
  --release N           Fedora release number (default: 44)
  --packages "PKG..."   Space/comma-separated list of packages to build (default: "all")
  -h, --help            Show this help message
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

RADXA_FIRMWARE_REF=${RADXA_FIRMWARE_REF_OVERRIDE:-$RADXA_FIRMWARE_REF}
RADXA_FIRMWARE_VERSION=${RADXA_FIRMWARE_VERSION_OVERRIDE:-$RADXA_FIRMWARE_VERSION}
RADXA_OVERLAYS_REF=${RADXA_OVERLAYS_REF_OVERRIDE:-$RADXA_OVERLAYS_REF}
ALSA_UCM_VERSION=${ALSA_UCM_VERSION_OVERRIDE:-$ALSA_UCM_VERSION}
FASTRPC_REF=${FASTRPC_REF_OVERRIDE:-$FASTRPC_REF}
QAIRT_VERSION=${QAIRT_VERSION_OVERRIDE:-$QAIRT_VERSION}
QAIRT_DOWNLOAD_URL=${QAIRT_DOWNLOAD_URL_OVERRIDE:-$QAIRT_DOWNLOAD_URL}
QAIRT_ARCHIVE_SHA256=${QAIRT_ARCHIVE_SHA256_OVERRIDE:-$QAIRT_ARCHIVE_SHA256}
QAIRT_LICENSE_SHA256=${QAIRT_LICENSE_SHA256_OVERRIDE:-$QAIRT_LICENSE_SHA256}
QAIRT_TARGET=${QAIRT_TARGET_OVERRIDE:-$QAIRT_TARGET}
QAIRT_DSP_ARCH=${QAIRT_DSP_ARCH_OVERRIDE:-$QAIRT_DSP_ARCH}
default_package_release=1.local
if git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
    commit_time=$(git -C "$repo_root" show -s --format=%ct HEAD)
    commit_id=$(git -C "$repo_root" rev-parse --short=12 HEAD)
    default_package_release="1.${commit_time}.${commit_id}"
fi
PACKAGE_RELEASE=${PACKAGE_RELEASE_OVERRIDE:-$default_package_release}
[[ "$PACKAGE_RELEASE" =~ ^[0-9][A-Za-z0-9._+]*$ ]] || {
    echo "invalid PACKAGE_RELEASE_OVERRIDE: $PACKAGE_RELEASE" >&2
    exit 2
}

source_dir=
output=
release=${FEDORA_RELEASE:-44}
packages_arg="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir) source_dir=${2:?missing source directory}; shift 2 ;;
        --output) output=${2:?missing output directory}; shift 2 ;;
        --release) release=${2:?missing Fedora release}; shift 2 ;;
        --packages) packages_arg=${2:?missing packages list}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$output" ]] || { usage >&2; exit 2; }

# Normalize requested packages
requested_packages=()
if [[ -x "$repo_root/scripts/detect-affected-packages.sh" ]]; then
    read -r -a requested_packages <<< "$("$repo_root/scripts/detect-affected-packages.sh" --packages "$packages_arg")"
else
    IFS=', ' read -r -a requested_packages <<< "$packages_arg"
fi

if [[ ${#requested_packages[@]} -eq 0 ]]; then
    echo "No packages selected to build."
    exit 0
fi

declare -A pkg_map=()
for p in "${requested_packages[@]}"; do
    pkg_map["$p"]=1
done

echo "Building source RPMs for Fedora $release: ${requested_packages[*]}"

# Command prerequisites
required_commands=(rpmbuild rpmspec)
if [[ -n "${pkg_map[kernel]:-}" ]]; then
    required_commands+=(fedpkg)
fi

for command in "${required_commands[@]}"; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

mkdir -p "$output" "$output/rpmbuild" "$output/sources"
topdir=$(cd "$output/rpmbuild" && pwd)
mkdir -p "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" "$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS"

# Build kernel SRPM if requested
if [[ -n "${pkg_map[kernel]:-}" ]]; then
    [[ -d "$source_dir" ]] || { echo "missing source directory: $source_dir" >&2; exit 1; }
    cp "$source_dir/kernel.spec" "$topdir/SPECS/kernel.spec"
    cp "$source_dir/dragon-q8b-kernel.patch" "$topdir/SOURCES/dragon-q8b-kernel.patch"
    cp "$source_dir/kernel-local" "$topdir/SOURCES/kernel-local"

    echo "Fetching Fedora kernel sources listed by the dist-git spec"
    (cd "$source_dir" && fedpkg sources)
    find "$source_dir" -maxdepth 1 -type f \
        ! -name 'kernel.spec' \
        ! -name 'kernel-local' \
        ! -name 'dragon-q8b-kernel.patch' \
        -exec cp -n {} "$topdir/SOURCES/" \;

    # Run Fedora's %prep first so the SRPM-producing job catches conflicts between
    # Fedora's own patch and the Q8B queue instead of deferring that failure to
    # the COPR binary build.
    rpmbuild -bp --nodeps --define "_topdir $topdir" "$topdir/SPECS/kernel.spec"
    rpmbuild -bs --define "_topdir $topdir" "$topdir/SPECS/kernel.spec"
    cp "$topdir"/SRPMS/*.src.rpm "$output/"
fi

# Build non-kernel SRPMs
package_dirs=(
    "firmware:dragon-q8b-firmware"
    "boot:dragon-q8b-boot"
    "overlays:dragon-q8b-overlays"
    "alsa:dragon-q8b-alsa-ucm"
    "fastrpc:dragon-q8b-fastrpc"
    "qnn:dragon-q8b-qnn"
    "kernel-meta:dragon-q8b-kernel"
    "meta:dragon-q8b-support"
)

for entry in "${package_dirs[@]}"; do
    package_dir="${entry%%:*}"
    package_name="${entry##*:}"

    [[ -n "${pkg_map[$package_name]:-}" ]] || continue

    spec_dir="$repo_root/packaging/$package_dir"
    [[ -d "$spec_dir" ]] || continue
    spec=$(find "$spec_dir" -maxdepth 1 -name '*.spec' -print -quit)
    [[ -n "$spec" ]] || continue
    spec_name=$(basename "$spec")
    cp "$spec" "$topdir/SPECS/$spec_name"
    find "$spec_dir" -maxdepth 1 -type f ! -name '*.spec' -exec cp {} "$topdir/SOURCES/" \;
    sed -i "s/^Release:        1%{?dist}$/Release:        %{package_release}%{?dist}/" "$topdir/SPECS/$spec_name"
    sed -i "s#^%{!?package_release:%global package_release 1}\$#%global package_release $PACKAGE_RELEASE#" "$topdir/SPECS/$spec_name"
    if [[ "$package_dir" == firmware ]]; then
        sed -i "s/^%global _source_firmware_ref .*/%global _source_firmware_ref $RADXA_FIRMWARE_REF/" "$topdir/SPECS/$spec_name"
        sed -i "s/^%global _source_firmware_version .*/%global _source_firmware_version $RADXA_FIRMWARE_VERSION/" "$topdir/SPECS/$spec_name"
    fi
    if [[ "$package_dir" == overlays ]]; then
        sed -i "s/^%global overlays_ref .*/%global overlays_ref $RADXA_OVERLAYS_REF/" "$topdir/SPECS/$spec_name"
    fi
    if [[ "$package_dir" == fastrpc ]]; then
        sed -i "s/^%global fastrpc_ref .*/%global fastrpc_ref $FASTRPC_REF/" "$topdir/SPECS/$spec_name"
    fi
    if [[ "$package_dir" == firmware ]]; then
        cp "$repo_root/vendor/radxa/firmware/radxa-firmware-${RADXA_FIRMWARE_REF}.tar.gz" \
            "$topdir/SOURCES/"
    fi
    if [[ "$package_dir" == overlays ]]; then
        cp "$repo_root/vendor/radxa/overlays/radxa-overlays-${RADXA_OVERLAYS_REF}.tar.gz" \
            "$topdir/SOURCES/"
    fi
    if [[ "$package_dir" == alsa ]]; then
        cp "$repo_root/vendor/radxa/alsa/alsa-ucm-conf_${ALSA_UCM_VERSION}_all.deb" \
            "$topdir/SOURCES/"
        sed -i "s/^%global alsa_ucm_version .*/%global alsa_ucm_version $ALSA_UCM_VERSION/" \
            "$topdir/SPECS/$spec_name"
    fi
    if [[ "$package_dir" == fastrpc ]]; then
        cp "$repo_root/vendor/qualcomm/fastrpc/fastrpc-${FASTRPC_REF}.tar.gz" \
            "$topdir/SOURCES/"
    fi
    if [[ "$package_dir" == qnn ]]; then
        for qnn_source in dragon-q8b-qnn-sync dragon-q8b-qnn.conf; do
            sed -i \
                -e "s#^QAIRT_VERSION=.*#QAIRT_VERSION=$QAIRT_VERSION#" \
                -e "s#^QAIRT_DOWNLOAD_URL=.*#QAIRT_DOWNLOAD_URL=$QAIRT_DOWNLOAD_URL#" \
                -e "s#^QAIRT_ARCHIVE_SHA256=.*#QAIRT_ARCHIVE_SHA256=$QAIRT_ARCHIVE_SHA256#" \
                -e "s#^QAIRT_LICENSE_SHA256=.*#QAIRT_LICENSE_SHA256=$QAIRT_LICENSE_SHA256#" \
                -e "s#^QAIRT_TARGET=.*#QAIRT_TARGET=$QAIRT_TARGET#" \
                -e "s#^QAIRT_DSP_ARCH=.*#QAIRT_DSP_ARCH=$QAIRT_DSP_ARCH#" \
                "$topdir/SOURCES/$qnn_source"
        done
        sed -i \
            -e "s#^    export QNN_TARGET=.*#    export QNN_TARGET=$QAIRT_TARGET#" \
            -e "s#^    export QNN_DSP_ARCH=.*#    export QNN_DSP_ARCH=$QAIRT_DSP_ARCH#" \
            "$topdir/SOURCES/dragon-q8b-qnn.sh"
        printf '/opt/qualcomm/qairt/current/lib/%s\n' "$QAIRT_TARGET" \
            > "$topdir/SOURCES/dragon-q8b-qnn-ld.so.conf"
    fi
    if [[ "$package_dir" == kernel-meta ]]; then
        kernel_spec_target=""
        if [[ -f "$topdir/SPECS/kernel.spec" ]]; then
            kernel_spec_target="$topdir/SPECS/kernel.spec"
        elif [[ -n "$source_dir" && -f "$source_dir/kernel.spec" ]]; then
            kernel_spec_target="$source_dir/kernel.spec"
        fi

        if [[ -n "$kernel_spec_target" ]]; then
            kernel_version=$(rpmspec --query --queryformat '%{VERSION}\n' "$kernel_spec_target" | awk 'NR == 1 {value=$0} END {print value}')
            kernel_release=$(rpmspec --query --queryformat '%{RELEASE}\n' "$kernel_spec_target" | awk 'NR == 1 {value=$0} END {print value}')
            sed -i "s/^%global kernel_need_version .*/%global kernel_need_version $kernel_version/" "$topdir/SPECS/$spec_name"
            sed -i "s/^%global kernel_need_release .*/%global kernel_need_release $kernel_release/" "$topdir/SPECS/$spec_name"
        fi
    fi
    rpmbuild -bs --define "_topdir $topdir" "$topdir/SPECS/$spec_name"
    cp "$topdir"/SRPMS/*.src.rpm "$output/"
done

echo "SRPMs written to $output"
