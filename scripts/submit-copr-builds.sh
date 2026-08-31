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

# Print a COPR build id for this NVR/chroot if one exists in a non-failure
# state. Used to skip duplicates and to recover when copr-cli created a build
# but returned a non-JSON error page.
existing_copr_build_id() {
    local name=$1
    local srpm_path=${srpms[$name]}
    local want_state=${2:-any}

    python3 - "$project" "$chroot" "$srpm_path" "$want_state" <<'PYEOF' 2>/dev/null || true
import sys
import rpm

owner, proj = sys.argv[1].split("/", 1)
chroot = sys.argv[2]
srpm_path = sys.argv[3]
want_state = sys.argv[4]
failure = {"failed", "canceled"}

ts = rpm.TransactionSet()
with open(srpm_path, "rb") as f:
    hdr = ts.hdrFromFdno(f.fileno())

name = hdr[rpm.RPMTAG_NAME]
target_vr = f"{hdr[rpm.RPMTAG_VERSION]}-{hdr[rpm.RPMTAG_RELEASE]}"

try:
    from copr.v3 import Client
    client = Client.create_from_config_file()
    builds = client.build_proxy.get_list(ownername=owner, projectname=proj, packagename=name)
except Exception:
    sys.exit(1)

for b in builds:
    b_vr = getattr(b, "pkg_version", None)
    if not b_vr and getattr(b, "source_package", None):
        source = b.source_package
        b_vr = source.get("version") if isinstance(source, dict) else getattr(source, "version", None)
    if b_vr != target_vr:
        continue
    if getattr(b, "chroots", None) and chroot not in b.chroots:
        continue
    if want_state == "succeeded":
        if b.state == "succeeded":
            print(b.id)
            sys.exit(0)
        continue
    if b.state not in failure:
        print(b.id)
        sys.exit(0)
sys.exit(1)
PYEOF
}

is_built_in_copr() {
    local name=$1
    local build_id
    if [[ "$force" -eq 1 ]]; then
        return 1
    fi
    build_id=$(existing_copr_build_id "$name" succeeded)
    [[ "$build_id" =~ ^[0-9]+$ ]]
}

record_build_id() {
    local name=$1 build_id=$2
    printf '%s=%s\n' "$name" "$build_id" >> "$srpm_dir/copr-builds.env"
    printf '%s\n' "$build_id"
}

submit() {
    local name=$1
    local output build_id status
    local attempt=1 max_attempts=6 delay=5
    [[ -n "${srpms[$name]:-}" ]] || { echo "missing SRPM for $name" >&2; exit 1; }

    if is_built_in_copr "$name"; then
        echo "Package ${srpm_nvrs[$name]} is already built and succeeded in $project ($chroot). Skipping." >&2
        return 0
    fi

    build_id=$(existing_copr_build_id "$name")
    if [[ "$build_id" =~ ^[0-9]+$ ]]; then
        echo "Package ${srpm_nvrs[$name]} already has COPR build $build_id in $project ($chroot). Reusing." >&2
        record_build_id "$name" "$build_id"
        return 0
    fi

    echo "Submitting $name (${srpm_nvrs[$name]}) to $project ($chroot)" >&2
    while (( attempt <= max_attempts )); do
        set +e
        output=$($copr_cmd build --nowait --chroot "$chroot" "$project" "${srpms[$name]}" 2>&1)
        status=$?
        set -e
        printf '%s\n' "$output" >&2
        build_id=$(printf '%s\n' "$output" | awk '/Created builds:/ {print $NF; exit}')
        if [[ "$status" -eq 0 && "$build_id" =~ ^[0-9]+$ ]]; then
            record_build_id "$name" "$build_id"
            return 0
        fi

        build_id=$(existing_copr_build_id "$name")
        if [[ "$build_id" =~ ^[0-9]+$ ]]; then
            echo "COPR accepted ${srpm_nvrs[$name]} as build $build_id after a non-JSON response." >&2
            record_build_id "$name" "$build_id"
            return 0
        fi

        echo "COPR submit failed for $name (attempt $attempt/$max_attempts, status ${status}). Retrying in ${delay}s." >&2
        sleep "$delay"
        delay=$(( delay * 2 ))
        if (( delay > 60 )); then
            delay=60
        fi
        attempt=$((attempt + 1))
    done
    echo "could not submit $name to COPR after $max_attempts attempts" >&2
    exit 1
}

# Watch COPR builds until they finish. Fail as soon as one fails so a broken
# firmware package does not sit behind a long kernel build. Retry transient
# non-JSON API responses from copr-cli/python-copr.
watch_copr_builds() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi
    echo "Waiting for COPR builds: $*"
    python3 - "$@" <<'PYEOF'
import sys
import time

from copr.v3 import Client
from copr.v3.exceptions import CoprException

try:
    from requests.exceptions import RequestException
except ImportError:
    RequestException = OSError

SUCCESS = {"succeeded", "skipped", "forked"}
FAILURE = {"failed", "canceled"}
POLL_SECONDS = 30
MAX_BACKOFF = 60

build_ids = [int(x) for x in sys.argv[1:]]
client = Client.create_from_config_file()
last_state = {}
finished = {}
backoff = 5

print("Watching build(s): (this may be safely interrupted)", flush=True)
while len(finished) < len(build_ids):
    try:
        now = time.strftime("%H:%M:%S", time.gmtime())
        for build_id in build_ids:
            if build_id in finished:
                continue
            build = client.build_proxy.get(build_id)
            state = build.state
            if last_state.get(build_id) != state:
                print(f"  {now} Build {build_id}: {state}", flush=True)
                last_state[build_id] = state
            if state in SUCCESS:
                finished[build_id] = state
            elif state in FAILURE:
                url = f"https://copr.fedorainfracloud.org/coprs/build/{build_id}"
                pkg = ""
                source = getattr(build, "source_package", None) or {}
                if isinstance(source, dict):
                    pkg = source.get("name") or ""
                elif source is not None:
                    pkg = getattr(source, "name", "") or ""
                label = f"{pkg} " if pkg else ""
                print(
                    f"COPR build {build_id} {label}{state}: {url}",
                    file=sys.stderr,
                )
                sys.exit(1)
        backoff = 5
        if len(finished) < len(build_ids):
            time.sleep(POLL_SECONDS)
    except (CoprException, RequestException, OSError, TimeoutError) as exc:
        print(f"COPR API error (retrying in {backoff}s): {exc}", file=sys.stderr)
        time.sleep(backoff)
        backoff = min(MAX_BACKOFF, backoff * 2)
PYEOF
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
    watch_copr_builds "${core_ids[@]}"
fi

if [[ -n "${srpms[dragon-q8b-kernel]:-}" ]]; then
    kernel_meta_id=$(submit dragon-q8b-kernel)
    if [[ -n "$kernel_meta_id" ]]; then
        echo "Waiting for dragon-q8b-kernel COPR build: $kernel_meta_id"
        watch_copr_builds "$kernel_meta_id"
    fi
fi

if [[ -n "${srpms[dragon-q8b-support]:-}" ]]; then
    support_meta_id=$(submit dragon-q8b-support)
    if [[ -n "$support_meta_id" ]]; then
        echo "Waiting for dragon-q8b-support COPR build: $support_meta_id"
        watch_copr_builds "$support_meta_id"
    fi
fi

echo "COPR submission complete."
