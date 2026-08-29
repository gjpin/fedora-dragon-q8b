#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: build-srpms.sh --source-dir DIR --output DIR [--release N]

Build the prepared Fedora kernel SRPM and the Dragon Q8B support SRPMs.
This script is intended for Fedora/COPR builders.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

RADXA_FIRMWARE_REF=${RADXA_FIRMWARE_REF_OVERRIDE:-$RADXA_FIRMWARE_REF}
RADXA_FIRMWARE_VERSION=${RADXA_FIRMWARE_VERSION_OVERRIDE:-$RADXA_FIRMWARE_VERSION}
RADXA_OVERLAYS_REF=${RADXA_OVERLAYS_REF_OVERRIDE:-$RADXA_OVERLAYS_REF}
PACKAGE_RELEASE=${PACKAGE_RELEASE_OVERRIDE:-1}
[[ "$PACKAGE_RELEASE" =~ ^[0-9][A-Za-z0-9._+]*$ ]] || {
    echo "invalid PACKAGE_RELEASE_OVERRIDE: $PACKAGE_RELEASE" >&2
    exit 2
}

source_dir=
output=
release=${FEDORA_RELEASE:-44}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir) source_dir=${2:?missing source directory}; shift 2 ;;
        --output) output=${2:?missing output directory}; shift 2 ;;
        --release) release=${2:?missing Fedora release}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -d "$source_dir" ]] || { echo "missing source directory: $source_dir" >&2; exit 1; }
[[ -n "$output" ]] || { usage >&2; exit 2; }
echo "Building source RPMs for Fedora $release"

for command in rpmbuild rpmspec spectool fedpkg; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

mkdir -p "$output" "$output/rpmbuild" "$output/sources"
topdir=$(cd "$output/rpmbuild" && pwd)
mkdir -p "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" "$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS"

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
rpmbuild -bp --define "_topdir $topdir" "$topdir/SPECS/kernel.spec"
rpmbuild -bs --define "_topdir $topdir" "$topdir/SPECS/kernel.spec"
cp "$topdir"/SRPMS/*.src.rpm "$output/"

for package_dir in firmware boot overlays alsa meta kernel-meta; do
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
    if [[ "$package_dir" == kernel-meta ]]; then
        kernel_version=$(rpmspec --qf '%{VERSION}\n' "$topdir/SPECS/kernel.spec" | awk 'NR == 1 {value=$0} END {print value}')
        kernel_release=$(rpmspec --qf '%{RELEASE}\n' "$topdir/SPECS/kernel.spec" | awk 'NR == 1 {value=$0} END {print value}')
        sed -i "s/^%global kernel_need_version .*/%global kernel_need_version $kernel_version/" "$topdir/SPECS/$spec_name"
        sed -i "s/^%global kernel_need_release .*/%global kernel_need_release $kernel_release/" "$topdir/SPECS/$spec_name"
    fi
    spectool -g -C "$topdir/SOURCES" "$topdir/SPECS/$spec_name"
    rpmbuild -bs --define "_topdir $topdir" "$topdir/SPECS/$spec_name"
    cp "$topdir"/SRPMS/*.src.rpm "$output/"
done

echo "SRPMs written to $output"
