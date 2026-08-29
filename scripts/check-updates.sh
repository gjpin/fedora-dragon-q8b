#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: check-updates.sh --output FILE [--release N]" >&2
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

output=
release=${FEDORA_RELEASE:-44}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output=${2:?missing output file}; shift 2 ;;
        --release) release=${2:?missing Fedora release}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$output" ]] || { usage; exit 2; }

for command in curl git awk grep sed; do
    command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

fedora_repo=https://src.fedoraproject.org/rpms/kernel.git
fedora_branch="f${release}"
fedora_kernel_commit=$(git ls-remote "$fedora_repo" "refs/heads/$fedora_branch" | awk 'NR == 1 {print $1}')
[[ -n "$fedora_kernel_commit" ]] || { echo "could not resolve Fedora kernel branch $fedora_branch" >&2; exit 1; }

kernel_spec_url="https://src.fedoraproject.org/rpms/kernel/raw/${fedora_branch}/f/kernel.spec"
kernel_spec=$(curl --fail --silent --show-error --location --retry 4 --retry-all-errors "$kernel_spec_url")
fedora_kernel_version=$(printf '%s\n' "$kernel_spec" | awk '/^%define specrpmversion / && !seen {print $3; seen=1}')
[[ -n "$fedora_kernel_version" ]] || { echo "could not parse Fedora kernel version" >&2; exit 1; }

radxa_kernel_ref=$(git ls-remote "$RADXA_KERNEL_REPO" "refs/heads/$RADXA_KERNEL_BRANCH" | awk 'NR == 1 {print $1}')
radxa_firmware_ref=$(git ls-remote "$RADXA_FIRMWARE_REPO" refs/heads/main | awk 'NR == 1 {print $1}')
radxa_overlays_ref=$(git ls-remote "$RADXA_OVERLAYS_REPO" refs/heads/main | awk 'NR == 1 {print $1}')
armbian_ref=$(git ls-remote "$ARMBIAN_BUILD_REPO" refs/heads/main | awk 'NR == 1 {print $1}')
for value_name in radxa_kernel_ref radxa_firmware_ref radxa_overlays_ref armbian_ref; do
    [[ -n "${!value_name}" ]] || { echo "could not resolve $value_name" >&2; exit 1; }
done

manifest_hash=$(if command -v sha256sum >/dev/null; then sha256sum "$repo_root/config/armbian-sc8280xp-edge-patches.sha256"; else shasum -a 256 "$repo_root/config/armbian-sc8280xp-edge-patches.sha256"; fi | awk '{print $1}')

cat > "$output" <<EOF
FEDORA_RELEASE=$release
FEDORA_KERNEL_BRANCH=$fedora_branch
FEDORA_KERNEL_COMMIT=$fedora_kernel_commit
FEDORA_KERNEL_VERSION=$fedora_kernel_version
RADXA_KERNEL_REF=$radxa_kernel_ref
RADXA_FIRMWARE_REF=$radxa_firmware_ref
RADXA_OVERLAYS_REF=$radxa_overlays_ref
ARMBIAN_REF=$armbian_ref
PATCH_MANIFEST_SHA256=$manifest_hash
EOF

lock="$repo_root/packaging/inputs.lock"
changed=0
grep -q "fedora_release: \"$release\"" "$lock" || changed=1
grep -q "fedora_kernel_commit: \"$fedora_kernel_commit\"" "$lock" || changed=1
grep -q "fedora_kernel_version: \"$fedora_kernel_version\"" "$lock" || changed=1
grep -q "radxa_kernel_ref: \"$radxa_kernel_ref\"" "$lock" || changed=1
grep -q "radxa_firmware_ref: \"$radxa_firmware_ref\"" "$lock" || changed=1
grep -q "radxa_overlays_ref: \"$radxa_overlays_ref\"" "$lock" || changed=1
grep -q "armbian_ref: \"$armbian_ref\"" "$lock" || changed=1
grep -q "patch_manifest_sha256: \"$manifest_hash\"" "$lock" || changed=1
if grep -q 'unresolved' "$lock"; then changed=1; fi
printf 'CHANGED=%s\n' "$changed" >> "$output"

echo "Fedora $release kernel $fedora_kernel_version at $fedora_kernel_commit"
echo "Source changes detected: $changed"
