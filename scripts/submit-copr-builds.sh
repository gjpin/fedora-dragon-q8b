#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: submit-copr-builds.sh --project OWNER/PROJECT --chroot CHROOT --srpm-dir DIR [--force]

Submit the custom kernel and Q8B SRPMs to COPR.
Skips packages that are already built with the exact NVR in the destination project.
Kernel/firmware/boot packages are watched to completion before the dependency
meta-packages are submitted.

Options:
  --project OWNER/PROJECT  COPR project path (required)
  --chroot CHROOT          Target COPR chroot, e.g. fedora-44-aarch64 (required)
  --srpm-dir DIR           Directory containing .src.rpm files (required)
  --force                  Force submitting builds even if already present in COPR
  -h, --help               Show this help message
EOF
}

project=
chroot=
srpm_dir=
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project=${2:?missing OWNER/PROJECT}; shift 2 ;;
        --chroot) chroot=${2:?missing COPR chroot}; shift 2 ;;
        --srpm-dir) srpm_dir=${2:?missing SRPM directory}; shift 2 ;;
        --force) force=1; shift ;;
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

declare -A srpms=()
declare -A srpm_nvrs=()

while IFS= read -r -d '' srpm; do
    name=$(rpm -qp --qf '%{NAME}' "$srpm")
    nvr=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$srpm")
    srpms["$name"]=$srpm
    srpm_nvrs["$name"]=$nvr
done < <(find "$srpm_dir" -maxdepth 1 -type f -name '*.src.rpm' -print0)

if [[ ${#srpms[@]} -eq 0 ]]; then
    echo "No SRPMs found in $srpm_dir to submit to COPR."
    exit 0
fi

# Check if a package is already built and succeeded in COPR
is_built_in_copr() {
    local name=$1
    local srpm_path=${srpms[$name]}
    if [[ "$force" -eq 1 ]]; then
        return 1
    fi

    python3 - "$project" "$chroot" "$srpm_path" <<'PYEOF' 2>/dev/null || return 1
import sys
import rpm

owner, proj = sys.argv[1].split('/', 1)
chroot = sys.argv[2]
srpm_path = sys.argv[3]

ts = rpm.TransactionSet()
with open(srpm_path, 'rb') as f:
    hdr = ts.hdrFromFdno(f.fileno())

name = hdr[rpm.RPMTAG_NAME]
version = hdr[rpm.RPMTAG_VERSION]
release = hdr[rpm.RPMTAG_RELEASE]
target_vr = f"{version}-{release}"

try:
    from copr.v3 import Client
    client = Client.create_from_config_file()
    builds = client.build_proxy.get_list(ownername=owner, projectname=proj, packagename=name)
    for b in builds:
        b_vr = getattr(b, 'pkg_version', None)
        if not b_vr and hasattr(b, 'source_package') and b.source_package:
            b_vr = b.source_package.get('version')
        if b_vr == target_vr and b.state == 'succeeded':
            if hasattr(b, 'chroots') and b.chroots:
                if chroot in b.chroots:
                    sys.exit(0) # Found existing successful build
            else:
                sys.exit(0)
except Exception:
    pass

sys.exit(1) # Not built or error checking
PYEOF
}

submit() {
    local name=$1
    local output build_id
    [[ -n "${srpms[$name]:-}" ]] || { echo "missing SRPM for $name" >&2; exit 1; }

    if is_built_in_copr "$name"; then
        echo "Package ${srpm_nvrs[$name]} is already built and succeeded in $project ($chroot). Skipping." >&2
        return 0
    fi

    echo "Submitting $name (${srpm_nvrs[$name]}) to $project ($chroot)" >&2
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
for name in kernel dragon-q8b-firmware dragon-q8b-boot dragon-q8b-overlays dragon-q8b-alsa-ucm fastrpc dragon-q8b-qnn; do
    if [[ -n "${srpms[$name]:-}" ]]; then
        id=$(submit "$name")
        if [[ -n "$id" ]]; then
            core_ids+=("$id")
        fi
    fi
done

if [[ ${#core_ids[@]} -gt 0 ]]; then
    echo "Waiting for core COPR builds: ${core_ids[*]}"
    $copr_cmd watch-build "${core_ids[@]}"
fi

if [[ -n "${srpms[dragon-q8b-kernel]:-}" ]]; then
    kernel_meta_id=$(submit dragon-q8b-kernel)
    if [[ -n "$kernel_meta_id" ]]; then
        echo "Waiting for dragon-q8b-kernel COPR build: $kernel_meta_id"
        $copr_cmd watch-build "$kernel_meta_id"
    fi
fi

if [[ -n "${srpms[dragon-q8b-support]:-}" ]]; then
    support_meta_id=$(submit dragon-q8b-support)
    if [[ -n "$support_meta_id" ]]; then
        echo "Waiting for dragon-q8b-support COPR build: $support_meta_id"
        $copr_cmd watch-build "$support_meta_id"
    fi
fi

echo "COPR submission complete."
