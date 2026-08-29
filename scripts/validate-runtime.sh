#!/usr/bin/env bash
set -Eeuo pipefail

failures=0
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok: %s\n' "$description"
    else
        printf 'FAIL: %s\n' "$description" >&2
        failures=$((failures + 1))
    fi
}

check_q8b_compatible() {
    [[ -r /proc/device-tree/compatible ]] || return 1
    tr '\0' '\n' < /proc/device-tree/compatible | grep -Fxq 'radxa,dragon-q8b'
}
check_package() { rpm -q "$1" >/dev/null 2>&1; }
check_firmware() { test -e "$1"; }
check_dtb() {
    local version=$1
    test -e "/usr/lib/modules/$version/dtb/qcom/sc8280xp-radxa-dragon-q8b.dtb" || \
        test -e "/lib/modules/$version/dtb/qcom/sc8280xp-radxa-dragon-q8b.dtb" || \
        test -e "/boot/dtb-$version/qcom/sc8280xp-radxa-dragon-q8b.dtb"
}

check 'device tree identifies Radxa Dragon Q8B' check_q8b_compatible
for package in qrtr tqftpserv bluez alsa-ucm qcom-firmware dragon-q8b-support \
    dragon-q8b-kernel dragon-q8b-firmware dragon-q8b-boot dragon-q8b-overlays \
    dragon-q8b-alsa-ucm; do
    check "RPM $package is installed" check_package "$package"
done

if command -v rpm >/dev/null 2>&1; then
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        check "Q8B DTB installed for kernel $version" check_dtb "$version"
    done < <(rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 'kernel-core*dragonq8b*' 2>/dev/null | awk '$1 == "kernel-core" {print $2}' || true)
fi

for firmware in \
    /lib/firmware/qcom/sc8280xp/qccdsp8280.mbn \
    /lib/firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn \
    /lib/firmware/qcom/sc8280xp/qupv3fw.elf \
    /lib/firmware/qcom/vpu/vpu20_p4_gen2_s6.mbn; do
    check "firmware $firmware exists" check_firmware "$firmware"
done

if command -v bluetoothctl >/dev/null 2>&1; then
    check 'Bluetooth controller is visible' bluetoothctl list
fi
if command -v lspci >/dev/null 2>&1; then
    check 'PCIe devices are enumerated' lspci
fi
if command -v aplay >/dev/null 2>&1; then
    check 'ALSA card is visible' aplay -l
fi

if command -v journalctl >/dev/null 2>&1; then
    if journalctl -k -b --no-pager | grep -Eiq 'firmware: failed to load|Direct firmware load failed'; then
        printf 'FAIL: kernel log contains firmware load failures\n' >&2
        failures=$((failures + 1))
    else
        printf 'ok: kernel log has no firmware load failures\n'
    fi
fi

if [[ $failures -gt 0 ]]; then
    printf '%s runtime checks failed\n' "$failures" >&2
    exit 1
fi
printf 'all runtime checks passed\n'
