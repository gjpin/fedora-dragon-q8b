#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: validate-srpms.sh [--rebuild-firmware] SRPM-DIR

Validate SRPMs in DIR. With --rebuild-firmware, also rpmbuild --rebuild any
dragon-q8b-firmware SRPM so %install/file-list errors fail before COPR.
EOF
}

rebuild_firmware=0
directory=

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild-firmware) rebuild_firmware=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            if [[ -n "$directory" ]]; then
                echo "unexpected argument: $1" >&2
                usage >&2
                exit 2
            fi
            directory=$1
            shift
            ;;
    esac
done

[[ -n "$directory" ]] || { usage >&2; exit 2; }
command -v rpm >/dev/null || { echo "rpm is required" >&2; exit 1; }
count=0
firmware_srpm=
while IFS= read -r -d '' srpm; do
    count=$((count + 1))
    name=$(rpm -qp --qf '%{NAME}' "$srpm")
    version=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$srpm")
    printf 'validated SRPM %s-%s\n' "$name" "$version"
    rpm -qpl "$srpm" >/dev/null
    if [[ "$name" == dragon-q8b-firmware ]]; then
        firmware_srpm=$srpm
    fi
done < <(find "$directory" -maxdepth 1 -type f -name '*.src.rpm' -print0)
if [[ $count -eq 0 ]]; then
    echo "no SRPMs found in $directory"
fi

if [[ "$rebuild_firmware" -eq 1 && -n "$firmware_srpm" ]]; then
    command -v rpmbuild >/dev/null || { echo "rpmbuild is required to rebuild firmware" >&2; exit 1; }
    topdir=$(mktemp -d)
    trap 'rm -rf "$topdir"' EXIT
    echo "Rebuilding $(basename "$firmware_srpm") locally"
    rpmbuild --rebuild --define "_topdir $topdir" "$firmware_srpm"
    fw_rpm=$(find "$topdir/RPMS" -type f -name 'dragon-q8b-firmware-*.rpm' ! -name '*.src.rpm' -print -quit)
    [[ -n "$fw_rpm" ]] || { echo "firmware rebuild produced no binary RPM" >&2; exit 1; }
    rpm -qpl "$fw_rpm" | grep -Fxq '/usr/lib/firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn'
    rpm -qpl "$fw_rpm" | grep -Fxq '/usr/lib/firmware/qcom/sc8280xp/qccdsp8280.mbn'
    rpm -qpl "$fw_rpm" | grep -Fxq '/usr/lib/firmware/qcom/sc8280xp/qupv3fw.elf'
    rpm -qpl "$fw_rpm" | grep -Fxq '/usr/lib/firmware/qcom/vpu/vpu20_p4_gen2_s6.mbn'
    rpm -qpl "$fw_rpm" | grep -q '/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp'
    if rpm -qpl "$fw_rpm" | grep -Eq 'qcdxkmsuc8280\.mbn|LENOVO/21BX'; then
        echo "firmware RPM must not own Fedora qcom-firmware GPU ZAP paths" >&2
        exit 1
    fi
    echo "validated rebuilt firmware RPM $(basename "$fw_rpm")"
fi
