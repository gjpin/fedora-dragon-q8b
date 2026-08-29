#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ci-smoke.sh [--engine podman|docker] [--image IMAGE] [--skip-lfs]

Run the fast, containerized portion of the GitHub Actions build locally.
This checks the Fedora tool installation, Git checkout/LFS setup, shell,
vendored inputs, and RPM spec validation without preparing or building the
kernel.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
engine=
image=fedora:44
skip_lfs=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) engine=${2:?missing container engine}; shift 2 ;;
        --image) image=${2:?missing container image}; shift 2 ;;
        --skip-lfs) skip_lfs=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$engine" ]]; then
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        engine=podman
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        engine=docker
    else
        echo "no usable Podman or Docker engine found" >&2
        echo "start Podman with 'podman machine start' or start Docker Desktop" >&2
        exit 1
    fi
fi

case "$engine" in
    podman|docker) command -v "$engine" >/dev/null || {
        echo "container engine not found: $engine" >&2
        exit 1
    } ;;
    *) echo "unsupported container engine: $engine" >&2; exit 2 ;;
esac

echo "Running CI smoke test with $engine and $image"

"$engine" run --rm --interactive \
    --env GITHUB_WORKSPACE=/tmp/dragon-q8b-workspace \
    --volume "$repo_root:/src:ro" \
    "$image" bash -s -- "$skip_lfs" <<'EOF'
set -Eeuo pipefail

skip_lfs=${1:?missing LFS mode}
dnf -y install \
    bash coreutils git git-lfs findutils grep sed awk \
    fedpkg fedora-packager \
    rpm-build rpmdevtools kernel-rpm-macros python3-devel \
    make gcc flex bison dtc binutils openssl tar gzip xz ShellCheck

mkdir -p "$GITHUB_WORKSPACE"
cp -a /src/. "$GITHUB_WORKSPACE/"
repo_root="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is unset}"
git -C "$repo_root" rev-parse --show-toplevel
if [[ "$skip_lfs" -eq 0 ]]; then
    git -C "$repo_root" lfs install --local
    git -C "$repo_root" lfs pull
fi

bash -n "$repo_root"/scripts/*.sh
shellcheck "$repo_root"/scripts/*.sh \
    "$repo_root"/packaging/boot/dragon-q8b-bt-address \
    "$repo_root"/packaging/boot/dragon-q8b-refresh-boot
bash "$repo_root/scripts/validate-vendor.sh"
for spec in "$repo_root"/packaging/*/*.spec; do
    rpmspec --parse "$spec" >/dev/null
done
bash "$repo_root/scripts/prepare-kernel-source.sh" --help >/dev/null
bash "$repo_root/scripts/build-srpms.sh" --help >/dev/null
test "$(wc -l < "$repo_root/config/armbian-sc8280xp-edge-patches.list")" -eq 35
echo "CI smoke test passed"
EOF
