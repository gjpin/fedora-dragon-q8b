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
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        engine=docker
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        engine=podman
    else
        echo "no usable Docker or Podman engine found" >&2
        echo "start Docker Desktop or run 'podman machine start'" >&2
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
dnf -y --disablerepo='*openh264*' install \
    bash coreutils git git-lfs findutils grep sed awk \
    fedpkg fedora-packager \
    rpm-build rpmdevtools kernel-rpm-macros systemd-rpm-macros python3-devel \
    make gcc flex bison dtc binutils openssl tar gzip xz ShellCheck \
    autoconf automake libtool libyaml-devel libbsd-devel

mkdir -p "$GITHUB_WORKSPACE"
cp -a /src/. "$GITHUB_WORKSPACE/"
chown -R 1001:1001 "$GITHUB_WORKSPACE"
repo_root="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is unset}"
git config --global --add safe.directory "$repo_root"
git -C "$repo_root" rev-parse --show-toplevel
if [[ "$skip_lfs" -eq 0 ]]; then
    git -C "$repo_root" lfs install --local
    git -C "$repo_root" lfs pull
fi

cd "$repo_root"
bash -n scripts/*.sh \
    packaging/boot/dragon-q8b-bt-address \
    packaging/boot/dragon-q8b-refresh-boot \
    packaging/boot/dragon-q8b-cmdline \
    packaging/boot/dragon-q8b-thermal \
    packaging/boot/50-dragon-q8b.install \
    packaging/boot/91-dragon-q8b.install \
    packaging/overlays/dragon-q8b-overlay \
    packaging/qnn/dragon-q8b-qnn-sync \
    packaging/qnn/dragon-q8b-qnn.sh
shellcheck scripts/*.sh \
    packaging/boot/dragon-q8b-bt-address \
    packaging/boot/dragon-q8b-refresh-boot \
    packaging/boot/dragon-q8b-cmdline \
    packaging/boot/dragon-q8b-thermal \
    packaging/boot/50-dragon-q8b.install \
    packaging/boot/91-dragon-q8b.install \
    packaging/overlays/dragon-q8b-overlay \
    packaging/qnn/dragon-q8b-qnn-sync \
    packaging/qnn/dragon-q8b-qnn.sh
bash scripts/validate-vendor.sh
for spec in packaging/*/*.spec; do
    rpmspec --parse "$spec" >/dev/null
done

# Test detect-affected-packages functionality
test "$(bash scripts/detect-affected-packages.sh --packages "boot,fastrpc")" = "dragon-q8b-boot fastrpc"
test "$(bash scripts/detect-affected-packages.sh --packages dragon-q8b-fastrpc)" = "fastrpc"
test -z "$(bash scripts/detect-affected-packages.sh --packages "none")"
test "$(bash scripts/detect-affected-packages.sh --files packaging/boot/dragon-q8b-boot.spec)" = "dragon-q8b-boot"
test "$(bash scripts/detect-affected-packages.sh --files vendor/armbian/sc8280xp-edge-patches/0001.patch)" = "kernel dragon-q8b-kernel"
test "$(bash scripts/detect-affected-packages.sh --files config/firmware.files)" = "dragon-q8b-firmware"
test "$(bash scripts/detect-affected-packages.sh --files config/kernel-local)" = "kernel dragon-q8b-kernel"
test "$(bash scripts/detect-affected-packages.sh --files config/overlays.list)" = "dragon-q8b-overlays"
test "$(bash scripts/detect-affected-packages.sh --files config/cmdline.tokens)" = "dragon-q8b-boot"
test "$(bash scripts/detect-affected-packages.sh --files packaging/kernel-meta/dragon-q8b-kernel.spec)" = "kernel dragon-q8b-kernel"
test "$(bash scripts/detect-affected-packages.sh --packages dragon-q8b-kernel)" = "kernel dragon-q8b-kernel"
test "$(bash scripts/detect-affected-packages.sh --packages non-kernel)" = "dragon-q8b-firmware dragon-q8b-boot dragon-q8b-overlays dragon-q8b-alsa-ucm fastrpc dragon-q8b-qnn dragon-q8b-support"
test "$(bash scripts/detect-affected-packages.sh --files scripts/qairt-catalog.sh)" = "dragon-q8b-qnn"

# The Q8B schematic drives the fan-control input through an inverting Q20
# open-drain stage. Keep the GPIO active-high at Q20's gate, compensate at the
# PWM consumer, and favor Q20-off/pulled-high while idle or shutting down.
fan_overlay=packaging/overlays/sc8280xp-radxa-dragon-q8b-pwm-fan.dtso
grep -q '#include <dt-bindings/pwm/pwm.h>' "$fan_overlay"
grep -Eq 'bias-pull-down;' "$fan_overlay"
grep -Eq 'gpios = <&tlmm 119 GPIO_ACTIVE_HIGH>;' "$fan_overlay"
grep -Eq 'pwms = <&fan_pwm 0 40000 PWM_POLARITY_INVERTED>;' "$fan_overlay"
grep -Eq 'fan-shutdown-percent = <100>;' "$fan_overlay"

cmdline_tokens=$(mktemp)
cmdline_file=$(mktemp)
cmdline_owned=$(mktemp -u)
printf 'clk_ignore_unused\n' > "$cmdline_tokens"
printf 'root=UUID=test quiet' > "$cmdline_file"
test "$(wc -c < "$cmdline_file")" -eq 20
DRAGON_Q8B_TOKENS_FILE="$cmdline_tokens" \
DRAGON_Q8B_CMDLINE_FILE="$cmdline_file" \
DRAGON_Q8B_OWNED_FILE="$cmdline_owned" \
    bash packaging/boot/dragon-q8b-cmdline apply
test "$(cat "$cmdline_file")" = "root=UUID=test quiet clk_ignore_unused"
test "$(cat "$cmdline_owned")" = "clk_ignore_unused"
DRAGON_Q8B_TOKENS_FILE="$cmdline_tokens" \
DRAGON_Q8B_CMDLINE_FILE="$cmdline_file" \
DRAGON_Q8B_OWNED_FILE="$cmdline_owned" \
    bash packaging/boot/dragon-q8b-cmdline remove
test "$(cat "$cmdline_file")" = "root=UUID=test quiet"
test ! -e "$cmdline_owned"
printf 'root=UUID=test clk_ignore_unused\n' > "$cmdline_file"
DRAGON_Q8B_TOKENS_FILE="$cmdline_tokens" \
DRAGON_Q8B_CMDLINE_FILE="$cmdline_file" \
DRAGON_Q8B_OWNED_FILE="$cmdline_owned" \
    bash packaging/boot/dragon-q8b-cmdline apply
test "$(cat "$cmdline_file")" = "root=UUID=test clk_ignore_unused"
test ! -e "$cmdline_owned"
DRAGON_Q8B_TOKENS_FILE="$cmdline_tokens" \
DRAGON_Q8B_CMDLINE_FILE="$cmdline_file" \
DRAGON_Q8B_OWNED_FILE="$cmdline_owned" \
    bash packaging/boot/dragon-q8b-cmdline remove
test "$(cat "$cmdline_file")" = "root=UUID=test clk_ignore_unused"
rm -f "$cmdline_tokens" "$cmdline_file" "$cmdline_owned"

qnn_pkg_conf=$(mktemp)
qnn_local_conf=$(mktemp)
printf 'QAIRT_VERSION=9.9.9.999999\n' > "$qnn_pkg_conf"
test "$(QNN_PACKAGED_CONF="$qnn_pkg_conf" QNN_CONFIG_FILE=/dev/null \
    packaging/qnn/dragon-q8b-qnn-sync status | awk -F' : ' '/Configured QAIRT version/{print $2}')" = "9.9.9.999999"
printf 'QAIRT_VERSION=8.8.8.888888\n' > "$qnn_local_conf"
test "$(QNN_PACKAGED_CONF="$qnn_pkg_conf" QNN_CONFIG_FILE="$qnn_local_conf" \
    packaging/qnn/dragon-q8b-qnn-sync status | awk -F' : ' '/Configured QAIRT version/{print $2}')" = "8.8.8.888888"
rm -f "$qnn_pkg_conf" "$qnn_local_conf"
if packaging/qnn/dragon-q8b-qnn-sync install >/dev/null 2>&1; then
    echo "QNN installer accepted installation without explicit license acceptance" >&2
    exit 1
fi
install_err=$(packaging/qnn/dragon-q8b-qnn-sync install 2>&1 || true)
printf '%s\n' "$install_err" | grep -Fq -- '--accept-license'

smoke_rpm_topdir=$(mktemp -d)
mkdir -p "$smoke_rpm_topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
# shellcheck disable=SC1091
source config/dragon-q8b.env
cp packaging/firmware/dragon-q8b-firmware.spec "$smoke_rpm_topdir/SPECS/"
cp "vendor/radxa/firmware/radxa-firmware-${RADXA_FIRMWARE_REF}.tar.gz" "$smoke_rpm_topdir/SOURCES/"
cp config/firmware.files "$smoke_rpm_topdir/SOURCES/"
rpmbuild -bb --define "_topdir $smoke_rpm_topdir" "$smoke_rpm_topdir/SPECS/dragon-q8b-firmware.spec" >/dev/null
fw_rpm=$(find "$smoke_rpm_topdir/RPMS" -type f -name 'dragon-q8b-firmware-*.rpm' ! -name '*.src.rpm' -print -quit)
[[ -n "$fw_rpm" ]]
rpm -qpl "$fw_rpm" | grep -Fxq '/usr/lib/firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn'
rpm -qpl "$fw_rpm" | grep -Fxq '/usr/lib/firmware/qcom/sc8280xp/qccdsp8280.mbn'
rpm -qpl "$fw_rpm" | grep -q '/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp'
if rpm -qpl "$fw_rpm" | grep -Eq 'qcdxkmsuc8280\.mbn|LENOVO/21BX'; then
    echo "firmware RPM must not own Fedora qcom-firmware GPU ZAP paths" >&2
    exit 1
fi

cp packaging/boot/dragon-q8b-boot.spec "$smoke_rpm_topdir/SPECS/"
find packaging/boot -maxdepth 1 -type f ! -name '*.spec' -exec cp {} "$smoke_rpm_topdir/SOURCES/" \;
cp config/cmdline.tokens "$smoke_rpm_topdir/SOURCES/cmdline.tokens"
rpmbuild -bb --define "_topdir $smoke_rpm_topdir" "$smoke_rpm_topdir/SPECS/dragon-q8b-boot.spec" >/dev/null
boot_rpm=$(find "$smoke_rpm_topdir/RPMS" -type f -name 'dragon-q8b-boot-*.rpm' ! -name '*.src.rpm' -print -quit)
[[ -n "$boot_rpm" ]]
rpm -qpl "$boot_rpm" | grep -Fxq '/usr/lib/dragon-q8b/cmdline.tokens'
rpm -qpl "$boot_rpm" | grep -Fxq '/usr/libexec/dragon-q8b-cmdline'
if rpm -qpl "$boot_rpm" | grep -Eq 'kernel/cmdline(\.d)?'; then
    echo "boot RPM must not ship /usr/lib/kernel/cmdline or cmdline.d" >&2
    exit 1
fi

cp packaging/alsa/dragon-q8b-alsa-ucm.spec "$smoke_rpm_topdir/SPECS/"
find packaging/alsa -maxdepth 1 -type f ! -name '*.spec' -exec cp {} "$smoke_rpm_topdir/SOURCES/" \;
cp "vendor/radxa/alsa/alsa-ucm-conf-${ALSA_UCM_VERSION}.tar.gz" "$smoke_rpm_topdir/SOURCES/"
rpmbuild -bb --define "_topdir $smoke_rpm_topdir" "$smoke_rpm_topdir/SPECS/dragon-q8b-alsa-ucm.spec" >/dev/null

cp packaging/fastrpc/fastrpc.spec "$smoke_rpm_topdir/SPECS/"
find packaging/fastrpc -maxdepth 1 -type f ! -name '*.spec' -exec cp {} "$smoke_rpm_topdir/SOURCES/" \;
cp "vendor/qualcomm/fastrpc/fastrpc-${FASTRPC_VERSION}.tar.gz" "$smoke_rpm_topdir/SOURCES/"
rpmbuild -bb --define "_topdir $smoke_rpm_topdir" "$smoke_rpm_topdir/SPECS/fastrpc.spec" >/dev/null

cp packaging/qnn/dragon-q8b-qnn.spec "$smoke_rpm_topdir/SPECS/"
find packaging/qnn -maxdepth 1 -type f ! -name '*.spec' -exec cp {} "$smoke_rpm_topdir/SOURCES/" \;
rpmbuild -bb --define "_topdir $smoke_rpm_topdir" "$smoke_rpm_topdir/SPECS/dragon-q8b-qnn.spec" >/dev/null
packaging/qnn/dragon-q8b-qnn-sync --help >/dev/null
packaging/qnn/dragon-q8b-qnn-sync license | grep -Fq "$QAIRT_DOWNLOAD_URL"
packaging/qnn/dragon-q8b-qnn-sync status | grep -Fq "Configured QAIRT version : $QAIRT_VERSION"
qnn_rpm=$(find "$smoke_rpm_topdir/RPMS" -name 'dragon-q8b-qnn-*.rpm' | head -n 1)
rpm -qpl "$qnn_rpm" | grep -Fxq '/usr/lib/dragon-q8b/qnn.conf'
rpm -qpc "$qnn_rpm" | grep -Fq '/etc/dragon-q8b/qnn.conf'
if rpm -qpc "$qnn_rpm" | grep -Fq '/usr/lib/dragon-q8b/qnn.conf'; then
    echo "packaged QAIRT pin must not be %config" >&2
    exit 1
fi

cp packaging/meta/dragon-q8b-support.spec "$smoke_rpm_topdir/SPECS/"
find packaging/meta -maxdepth 1 -type f ! -name '*.spec' -exec cp {} "$smoke_rpm_topdir/SOURCES/" \;
rpmbuild -bb --define "_topdir $smoke_rpm_topdir" "$smoke_rpm_topdir/SPECS/dragon-q8b-support.spec" >/dev/null

rm -rf "$smoke_rpm_topdir"

# Test selective build-srpms
smoke_srpm_dir=$(mktemp -d)
bash scripts/build-srpms.sh --packages "dragon-q8b-boot fastrpc" --output "$smoke_srpm_dir"
bash scripts/validate-srpms.sh "$smoke_srpm_dir"
test -f "$smoke_srpm_dir"/dragon-q8b-boot-*.src.rpm
test -f "$smoke_srpm_dir"/fastrpc-*.src.rpm
test ! -f "$smoke_srpm_dir"/dragon-q8b-firmware-*.src.rpm
rm -rf "$smoke_srpm_dir"

bash scripts/prepare-kernel-source.sh --help >/dev/null
bash scripts/build-srpms.sh --help >/dev/null
bash scripts/validate-e2e.sh --help >/dev/null
bash scripts/test-e2e-qemu.sh --help >/dev/null
test "$(wc -l < config/armbian-sc8280xp-edge-patches.list)" -eq \
    "$(wc -l < config/armbian-sc8280xp-edge-patches.sha256)"
echo "CI smoke test passed"
EOF
