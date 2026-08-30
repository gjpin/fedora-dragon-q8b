#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: bootstrap-fedora-dragon-q8b.sh [options]

Install Fedora and COPR support for a Radxa Dragon Q8B.

Options:
  --copr OWNER/PROJECT       Override the production COPR repository
  --force                    Continue past board/release detection failures
  --skip-dracut              Skip full initramfs regeneration (recommended for test VMs)
  --allow-unsigned-secure-boot
                             Continue when Secure Boot is enabled
  -h, --help                Show this help

The script never flashes SPI/UEFI firmware, removes old kernels, upgrades the
whole system, or reboots automatically.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

force=0
skip_dracut=0
allow_unsigned_secure_boot=0
copr_owner=${COPR_OWNER:-}
copr_project=${COPR_PROJECT:-dragon-q8b}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copr)
            copr=${2:?missing OWNER/PROJECT after --copr}
            [[ "$copr" == */* ]] || { echo "COPR must be OWNER/PROJECT" >&2; exit 2; }
            copr_owner=${copr%%/*}
            copr_project=${copr#*/}
            shift 2
            ;;
        --force) force=1; shift ;;
        --skip-dracut) skip_dracut=1; shift ;;
        --allow-unsigned-secure-boot) allow_unsigned_secure_boot=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "bootstrap: $*" >&2; exit 1; }
warn() { echo "bootstrap: warning: $*" >&2; }

[[ $EUID -eq 0 ]] || die "run as root"
command -v rpm >/dev/null || die "rpm is required"
command -v systemctl >/dev/null || warn "systemctl is unavailable; service enablement will be skipped"

machine_arch=$(uname -m)
if [[ "$machine_arch" != aarch64 && $force -eq 0 ]]; then
    die "Dragon Q8B Fedora support requires aarch64 (detected $machine_arch); use --force only for packaging tests"
fi

compatible=
if [[ -r /proc/device-tree/compatible ]]; then
    compatible=$(tr '\0' '\n' < /proc/device-tree/compatible | paste -sd, -)
fi
if [[ "$compatible" != *"${Q8B_COMPATIBLE:-radxa,dragon-q8b}"* && $force -eq 0 ]]; then
    die "device tree does not identify Radxa Dragon Q8B (compatible: ${compatible:-unavailable})"
fi

fedora_release=$(rpm -E '%{fedora}' 2>/dev/null || true)
expected_release=${FEDORA_RELEASE:-44}
if [[ "$expected_release" != auto && -n "$fedora_release" && "$fedora_release" != "$expected_release" && $force -eq 0 ]]; then
    die "this repository is configured for Fedora $expected_release, detected Fedora $fedora_release"
fi

if [[ -r /sys/firmware/efi/mok_variables/SecureBoot ]]; then
    secure_boot=$(od -An -tu1 /sys/firmware/efi/mok_variables/SecureBoot | awk '{print $1}')
    if [[ "$secure_boot" == 1 && $allow_unsigned_secure_boot -eq 0 ]]; then
        die "Secure Boot is enabled; configure and enroll a kernel signing key before installing the unsigned COPR kernel"
    fi
fi

[[ -n "$copr_owner" ]] || die "set COPR_OWNER or pass --copr OWNER/PROJECT"

dnf_cmd=$(command -v dnf5 || command -v dnf || true)
[[ -n "$dnf_cmd" ]] || die "dnf or dnf5 is required"

echo "Installing COPR integration for $copr_owner/$copr_project"
copr_repo_url="https://copr.fedorainfracloud.org/coprs/${copr_owner}/${copr_project}/repo/fedora-${fedora_release:-44}/${copr_owner}-${copr_project}-fedora-${fedora_release:-44}.repo"
mkdir -p /etc/yum.repos.d
if curl -fsSL --retry 3 --connect-timeout 10 "$copr_repo_url" -o "/etc/yum.repos.d/_copr:${copr_owner}:${copr_project}.repo" 2>/dev/null; then
    echo "Configured COPR repository via direct repo configuration"
elif ! "$dnf_cmd" copr --help >/dev/null 2>&1; then
    "$dnf_cmd" -y install --setopt=install_weak_deps=False --nodocs dnf-plugins-core >/dev/null 2>&1 || \
        "$dnf_cmd" -y install --setopt=install_weak_deps=False --nodocs dnf5-plugins || true
    "$dnf_cmd" -y copr enable "$copr_owner/$copr_project" || true
else
    "$dnf_cmd" -y copr enable "$copr_owner/$copr_project" || true
fi

packages=(
    qrtr
    tqftpserv
    bluez
    alsa-ucm
    qcom-firmware
    dragon-q8b-support
)

echo "Installing Fedora and Dragon Q8B packages"
dnf_opts=(
    --nodocs
    --setopt=install_weak_deps=False
    --setopt=max_parallel_downloads=1
    --setopt=timeout=120
    --setopt=retries=10
)

install_success=0
for attempt in {1..5}; do
    if "$dnf_cmd" -y install "${dnf_opts[@]}" "${packages[@]}"; then
        install_success=1
        break
    else
        echo "Package install attempt $attempt failed, retrying in 5s..."
        sleep 5
    fi
done

[[ $install_success -eq 1 ]] || die "Failed to install required packages after 5 attempts"

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || :
    if systemctl list-unit-files dragon-q8b-bt.service >/dev/null 2>&1; then
        systemctl enable dragon-q8b-bt.service || warn "could not enable dragon-q8b-bt.service"
    fi
    if systemctl list-unit-files dragon-q8b-qnn.timer >/dev/null 2>&1; then
        systemctl enable dragon-q8b-qnn.timer || warn "could not enable dragon-q8b-qnn.timer"
    fi
    if systemctl list-unit-files bluetooth.service >/dev/null 2>&1; then
        systemctl enable bluetooth.service || warn "could not enable bluetooth.service"
    fi
    while read -r unit _; do
        [[ -n "$unit" ]] || continue
        systemctl enable "$unit" || warn "could not enable $unit"
    done < <(systemctl list-unit-files --type=service --no-legend 'qrtr*' 'tqftpserv*' 2>/dev/null || true)
fi

if [[ -x /usr/libexec/dragon-q8b-refresh-boot ]]; then
    /usr/libexec/dragon-q8b-refresh-boot || warn "could not update all Fedora boot entries"
fi
if [[ -x /usr/libexec/dragon-q8b-thermal ]]; then
    /usr/libexec/dragon-q8b-thermal --apply-config || warn "could not apply thermal governor configuration"
fi
if [[ $skip_dracut -eq 0 ]] && command -v dracut >/dev/null 2>&1; then
    dracut --regenerate-all --force
fi

echo
echo "Installed package versions:"
rpm -q "${packages[@]}"
echo
echo "Q8B postflight:"
printf '  architecture: %s\n' "$machine_arch"
printf '  compatible: %s\n' "${compatible:-unavailable}"
printf '  running kernel: %s\n' "$(uname -r)"
printf '  custom kernels: %s\n' "$(rpm -qa 'kernel-core*dragonq8b*' | LC_ALL=C sort | tr '\n' ' ')"

if [[ -e /proc/device-tree/compatible && "$compatible" == *"${Q8B_COMPATIBLE:-radxa,dragon-q8b}"* ]]; then
    command -v lspci >/dev/null 2>&1 && lspci -nn || true
    command -v aplay >/dev/null 2>&1 && aplay -l || true
fi

if [[ "$(uname -r)" != *dragonq8b* ]]; then
    echo
    echo "The custom kernel is installed but not running. Reboot and select the Dragon Q8B kernel from the boot menu."
fi
echo "Bootstrap completed without flashing firmware or removing rollback kernels."

