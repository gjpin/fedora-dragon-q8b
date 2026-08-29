#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: submit-copr-builds.sh --project OWNER/PROJECT --chroot CHROOT --srpm-dir DIR

Submit the custom kernel and Q8B SRPMs to COPR. Kernel/firmware/boot
packages are watched to completion before the dependency meta-packages are
submitted.
EOF
}

project=
chroot=
srpm_dir=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project=${2:?missing OWNER/PROJECT}; shift 2 ;;
        --chroot) chroot=${2:?missing COPR chroot}; shift 2 ;;
        --srpm-dir) srpm_dir=${2:?missing SRPM directory}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$project" == */* ]] || { echo "--project must be OWNER/PROJECT" >&2; exit 2; }
[[ -d "$srpm_dir" ]] || { echo "missing SRPM directory: $srpm_dir" >&2; exit 1; }
command -v copr >/dev/null || command -v copr-cli >/dev/null || {
    echo "copr-cli is required" >&2
    exit 1
}
copr_cmd=$(command -v copr-cli || command -v copr)
command -v rpm >/dev/null || { echo "rpm is required" >&2; exit 1; }

declare -A srpms
while IFS= read -r -d '' srpm; do
    name=$(rpm -qp --qf '%{NAME}' "$srpm")
    srpms["$name"]=$srpm
done < <(find "$srpm_dir" -maxdepth 1 -type f -name '*.src.rpm' -print0)

[[ ${#srpms[@]} -gt 0 ]] || { echo "no SRPMs found" >&2; exit 1; }

submit() {
    local name=$1
    local output build_id
    [[ -n "${srpms[$name]:-}" ]] || { echo "missing SRPM for $name" >&2; exit 1; }
    echo "Submitting $name to $project ($chroot)" >&2
    output=$($copr_cmd build --nowait --chroot "$chroot" "$project" "${srpms[$name]}")
    printf '%s\n' "$output" >&2
    build_id=$(printf '%s\n' "$output" | awk '/Created builds:/ {print $NF; exit}')
    [[ "$build_id" =~ ^[0-9]+$ ]] || {
        echo "could not parse COPR build id for $name" >&2
        exit 1
    }
    printf '%s=%s\n' "$name" "$build_id" >> "$srpm_dir/copr-builds.env"
    printf '%s\n' "$build_id"
}

: > "$srpm_dir/copr-builds.env"
core_ids=()
for name in kernel dragon-q8b-firmware dragon-q8b-boot dragon-q8b-overlays dragon-q8b-alsa-ucm; do
    if [[ -n "${srpms[$name]:-}" ]]; then
        core_ids+=("$(submit "$name")")
    fi
done

if [[ ${#core_ids[@]} -gt 0 ]]; then
    echo "Waiting for core COPR builds: ${core_ids[*]}"
    $copr_cmd watch-build "${core_ids[@]}"
fi

if [[ -n "${srpms[dragon-q8b-kernel]:-}" ]]; then
    kernel_meta_id=$(submit dragon-q8b-kernel)
    echo "Waiting for dragon-q8b-kernel COPR build: $kernel_meta_id"
    $copr_cmd watch-build "$kernel_meta_id"
fi

if [[ -n "${srpms[dragon-q8b-support]:-}" ]]; then
    support_meta_id=$(submit dragon-q8b-support)
    echo "Waiting for dragon-q8b-support COPR build: $support_meta_id"
    $copr_cmd watch-build "$support_meta_id"
fi
