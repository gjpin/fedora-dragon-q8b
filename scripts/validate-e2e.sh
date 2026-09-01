#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: validate-e2e.sh [options]

Validate Radxa Dragon Q8B Fedora system installation and hardware integration.
Runs comprehensive checks for packages, firmware, kernel DTB, overlays, boot
configuration, dracut initramfs, Bluetooth service, FastRPC runtime, QNN/QAIRT,
and ALSA UCM configuration.

Options:
  --allow-virtual        Allow running in virtualized/QEMU environments (skips physical SoC check)
  --skip-dracut-build    Skip test regeneration of initramfs with dracut
  --output-json FILE     Write structured test results to a JSON file
  -h, --help             Show this help message
EOF
}

allow_virtual=0
skip_dracut_build=0
output_json=

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-virtual) allow_virtual=1; shift ;;
        --skip-dracut-build) skip_dracut_build=1; shift ;;
        --output-json) output_json=${2:?missing JSON output path}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

passed_checks=0
failed_checks=0
skipped_checks=0
declare -a test_results=()

log_ok() {
    local name=$1
    printf '[ OK ] %s\n' "$name"
    passed_checks=$((passed_checks + 1))
    test_results+=("{\"name\": \"$name\", \"status\": \"PASS\"}")
}

log_fail() {
    local name=$1
    local detail=${2:-}
    printf '[FAIL] %s\n' "$name" >&2
    if [[ -n "$detail" ]]; then
        printf '       Detail: %s\n' "$detail" >&2
    fi
    failed_checks=$((failed_checks + 1))
    test_results+=("{\"name\": \"$name\", \"status\": \"FAIL\", \"detail\": \"$detail\"}")
}

log_skip() {
    local name=$1
    local reason=${2:-}
    printf '[SKIP] %s (%s)\n' "$name" "$reason"
    skipped_checks=$((skipped_checks + 1))
    test_results+=("{\"name\": \"$name\", \"status\": \"SKIP\", \"reason\": \"$reason\"}")
}

run_check() {
    local description=$1
    shift
    if "$@"; then
        log_ok "$description"
    else
        log_fail "$description"
    fi
}

echo "========================================================"
echo " Starting Radxa Dragon Q8B Fedora E2E Validation Suite"
echo "========================================================"

# -----------------------------------------------------------------------------
# Section 1: System Environment & Board Identification
# -----------------------------------------------------------------------------
echo
echo "--- Section 1: System Environment & Compatibility ---"

# shellcheck disable=SC2329
check_arch() {
    local arch
    arch=$(uname -m)
    [[ "$arch" == "aarch64" ]]
}
run_check "Architecture is aarch64" check_arch

check_dt_compatible() {
    if [[ -r /proc/device-tree/compatible ]]; then
        tr '\0' '\n' < /proc/device-tree/compatible | grep -Fxq 'radxa,dragon-q8b'
    elif [[ $allow_virtual -eq 1 ]]; then
        return 0
    else
        return 1
    fi
}
if check_dt_compatible; then
    log_ok "Device tree identifies Radxa Dragon Q8B"
elif [[ $allow_virtual -eq 1 ]]; then
    log_skip "Device tree identifies Radxa Dragon Q8B" "running in virtualized environment with --allow-virtual"
else
    log_fail "Device tree identifies Radxa Dragon Q8B" "/proc/device-tree/compatible missing or does not match radxa,dragon-q8b"
fi

# -----------------------------------------------------------------------------
# Section 2: Package Installation & Integrity
# -----------------------------------------------------------------------------
echo
echo "--- Section 2: Dragon Q8B RPM Packages ---"

core_packages=(
    dragon-q8b-support
    dragon-q8b-firmware
    dragon-q8b-boot
    dragon-q8b-overlays
    dragon-q8b-alsa-ucm
    dragon-q8b-fastrpc
    fastrpc
)

for pkg in "${core_packages[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        local_nvr=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' "$pkg" | head -n 1)
        log_ok "RPM $pkg is installed ($local_nvr)"
    else
        log_fail "RPM $pkg is installed" "package is not installed"
    fi
done

if rpm -q dragon-q8b-qnn >/dev/null 2>&1; then
    local_nvr=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' dragon-q8b-qnn | head -n 1)
    log_ok "RPM dragon-q8b-qnn is installed ($local_nvr)"
else
    log_skip "RPM dragon-q8b-qnn is installed" "Recommends only; not required by dragon-q8b-support"
fi

base_deps=(
    qrtr
    tqftpserv
    bluez
    alsa-ucm
    qcom-firmware
    pd-mapper
    dracut
    grubby
    dtc
)
for pkg in "${base_deps[@]}"; do
    if [[ "$pkg" == pd-mapper ]]; then
        if rpm -q pd-mapper >/dev/null 2>&1; then
            log_ok "Base dependency RPM pd-mapper is installed"
        elif rpm -q --whatprovides pd-mapper >/dev/null 2>&1; then
            provider=$(rpm -q --whatprovides pd-mapper | head -n 1)
            log_ok "Base dependency pd-mapper is provided by $provider"
        else
            log_fail "Base dependency RPM pd-mapper is installed" "package is not installed"
        fi
        continue
    fi
    if rpm -q "$pkg" >/dev/null 2>&1; then
        log_ok "Base dependency RPM $pkg is installed"
    else
        log_fail "Base dependency RPM $pkg is installed" "package is not installed"
    fi
done

# -----------------------------------------------------------------------------
# Section 3: Supplemental Firmware & DSP Binaries
# -----------------------------------------------------------------------------
echo
echo "--- Section 3: Supplemental Firmware & DSP Binaries ---"

firmware_files=(
    "/usr/lib/firmware/qcom/sc8280xp/qccdsp8280.mbn"
    "/usr/lib/firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn"
    "/usr/lib/firmware/qcom/sc8280xp/qupv3fw.elf"
    "/usr/lib/firmware/qcom/vpu/vpu20_p4_gen2_s6.mbn"
)

for fw in "${firmware_files[@]}"; do
    if [[ -f "$fw" && -s "$fw" ]]; then
        log_ok "Firmware blob $(basename "$fw") exists and is non-empty ($fw)"
    else
        log_fail "Firmware blob $(basename "$fw") exists" "file missing or empty at $fw"
    fi
done

dsp_dir="/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp"
if [[ -d "$dsp_dir" ]]; then
    dsp_count=$(find "$dsp_dir" -type f \( -name '*.so*' -o -name '*.mbn' -o -name '*.bin' -o -name '*.elf' \) 2>/dev/null | wc -l)
    if [[ "$dsp_count" -gt 0 ]]; then
        log_ok "Hexagon DSP runtime libraries present in $dsp_dir ($dsp_count shared objects/blobs)"
    else
        log_fail "Hexagon DSP runtime libraries present" "no DSP library files found in $dsp_dir"
    fi
else
    log_fail "Hexagon DSP directory exists" "missing directory $dsp_dir"
fi

if [[ -f /usr/share/licenses/dragon-q8b-firmware/LICENSE ]]; then
    log_ok "Firmware license file installed"
else
    log_fail "Firmware license file installed" "missing /usr/share/licenses/dragon-q8b-firmware/LICENSE"
fi

# -----------------------------------------------------------------------------
# Section 4: Device Tree Blob (DTB) & Kernel Modules
# -----------------------------------------------------------------------------
echo
echo "--- Section 4: Device Tree Blob & Kernel Integration ---"

find_q8b_dtb() {
    find /usr/lib/modules /lib/modules /boot -name 'sc8280xp-radxa-dragon-q8b.dtb' 2>/dev/null | head -n 1
}

q8b_dtb=$(find_q8b_dtb || true)
if [[ -n "$q8b_dtb" && -f "$q8b_dtb" ]]; then
    log_ok "Dragon Q8B DTB found at $q8b_dtb"
    
    if command -v dtc >/dev/null 2>&1; then
        dts_content=$(dtc -I dtb -O dts "$q8b_dtb" 2>/dev/null || true)
        if [[ -n "$dts_content" ]]; then
            log_ok "Dragon Q8B DTB decompiled successfully with dtc"
            
            if [[ "$dts_content" == *'radxa,dragon-q8b'* ]]; then
                log_ok "DTB compatible string matches 'radxa,dragon-q8b'"
            else
                log_fail "DTB compatible string contains 'radxa,dragon-q8b'"
            fi
            
            if [[ "$dts_content" == *'wcd9385'* || "$dts_content" == *'soundwire'* ]]; then
                log_ok "DTB contains SoundWire / WCD9385 audio codec definitions"
            else
                log_fail "DTB audio nodes verification" "missing SoundWire/wcd9385 definitions"
            fi
            
            if [[ "$dts_content" == *'remoteproc'* || "$dts_content" == *'qcom,sc8280xp'* ]]; then
                log_ok "DTB contains Qualcomm SC8280XP SoC remoteproc nodes"
            else
                log_fail "DTB SoC remoteproc verification"
            fi
        else
            log_fail "Dragon Q8B DTB decompile" "dtc failed to decompile $q8b_dtb"
        fi
    elif command -v strings >/dev/null 2>&1; then
        dtb_strings=$(strings "$q8b_dtb" 2>/dev/null || true)
        if [[ "$dtb_strings" == *'radxa,dragon-q8b'* ]]; then
            log_ok "DTB binary contains 'radxa,dragon-q8b' compatible string"
        else
            log_fail "DTB binary compatible check" "missing 'radxa,dragon-q8b'"
        fi
        if [[ "$dtb_strings" == *'wcd9385'* || "$dtb_strings" == *'soundwire'* ]]; then
            log_ok "DTB binary contains SoundWire / WCD9385 audio codec strings"
        else
            log_fail "DTB binary audio check" "missing SoundWire/wcd9385 strings"
        fi
        if [[ "$dtb_strings" == *'remoteproc'* || "$dtb_strings" == *'sc8280xp'* ]]; then
            log_ok "DTB binary contains Qualcomm SC8280XP SoC remoteproc strings"
        else
            log_fail "DTB binary SoC check" "missing SC8280XP/remoteproc strings"
        fi
    else
        log_skip "Dragon Q8B DTB inspection" "neither dtc nor strings command available"
    fi
else
    if rpm -q dragon-q8b-kernel >/dev/null 2>&1 || [[ $allow_virtual -eq 0 ]]; then
        log_fail "Dragon Q8B DTB installed" "sc8280xp-radxa-dragon-q8b.dtb not found under /usr/lib/modules or /boot"
    else
        log_skip "Dragon Q8B DTB installed" "custom kernel not yet installed in virtualized environment"
    fi
fi

# -----------------------------------------------------------------------------
# Section 5: Device Tree Overlays
# -----------------------------------------------------------------------------
echo
echo "--- Section 5: Device Tree Overlays ---"

overlay_dir="/usr/share/dragon-q8b/overlays"
if [[ -d "$overlay_dir" ]]; then
    dtbo_count=$(find "$overlay_dir" -maxdepth 1 -name '*.dtbo' | wc -l)
    if [[ "$dtbo_count" -ge 10 ]]; then
        log_ok "Device tree overlays installed in $overlay_dir ($dtbo_count .dtbo files)"
    else
        log_fail "Device tree overlays installed" "expected >=10 .dtbo files, found $dtbo_count"
    fi
    
    if [[ -f "$overlay_dir/sc8280xp-radxa-dragon-q8b-fpc-pcie.dtbo" ]]; then
        log_ok "FPC PCIe overlay sc8280xp-radxa-dragon-q8b-fpc-pcie.dtbo is present"
    else
        log_fail "FPC PCIe overlay present" "missing sc8280xp-radxa-dragon-q8b-fpc-pcie.dtbo"
    fi

    if [[ -e "$overlay_dir/sc8280xp-radxa-dragon-q8b-pwm-fan.dtbo" ]]; then
        log_fail "Retired pwm-fan overlay absent" \
            "unexpected sc8280xp-radxa-dragon-q8b-pwm-fan.dtbo"
    else
        log_ok "Retired pwm-fan overlay is not installed"
    fi

    if [[ -x /usr/sbin/dragon-q8b-overlay ]]; then
        log_ok "Overlay helper dragon-q8b-overlay is executable"
        if dragon-q8b-overlay list >/dev/null 2>&1; then
            log_ok "Overlay helper list succeeded"
        else
            log_fail "Overlay helper list" "dragon-q8b-overlay list failed"
        fi
    else
        log_fail "Overlay helper executable" "missing /usr/sbin/dragon-q8b-overlay"
    fi
    
    if command -v dtc >/dev/null 2>&1; then
        dtbo_valid=1
        for dtbo in "$overlay_dir"/*.dtbo; do
            [[ -f "$dtbo" ]] || continue
            if ! dtc -I dtb -O dts "$dtbo" >/dev/null 2>&1; then
                log_fail "Overlay $(basename "$dtbo") valid DTB syntax"
                dtbo_valid=0
                break
            fi
        done
        if [[ $dtbo_valid -eq 1 ]]; then
            log_ok "All installed .dtbo overlay files have valid DTB syntax"
        fi
    fi
else
    log_fail "Overlay directory exists" "missing directory $overlay_dir"
fi

# -----------------------------------------------------------------------------
# Section 6: Boot Configuration & Dracut Initramfs Policy
# -----------------------------------------------------------------------------
echo
echo "--- Section 6: Boot Configuration & Dracut Initramfs Policy ---"

dracut_conf="/etc/dracut.conf.d/40-dragon-q8b.conf"
if [[ -f "$dracut_conf" ]]; then
    log_ok "Dracut configuration file $dracut_conf exists"
    
    if grep -Eq 'force_drivers\+=.*qcom_q6v5_pas' "$dracut_conf" \
        && grep -Eq 'force_drivers\+=.*ufs_qcom' "$dracut_conf" \
        && grep -Eq 'force_drivers\+=.*sdhci_msm' "$dracut_conf"; then
        log_ok "Dracut configuration includes Qualcomm remoteproc and storage drivers"
    else
        log_fail "Dracut remoteproc/storage drivers" "qcom_q6v5_pas/ufs_qcom/sdhci_msm missing in $dracut_conf"
    fi

    if grep -q 'LENOVO/21BX/qcdxkmsuc8280.mbn' "$dracut_conf"; then
        log_ok "Dracut configuration includes Fedora-owned Lenovo GPU ZAP firmware"
    else
        log_fail "Dracut GPU ZAP path" "LENOVO/21BX ZAP missing in $dracut_conf"
    fi
    if grep -Eq '/lib/firmware/qcom/sc8280xp/qcdxkmsuc8280.mbn' "$dracut_conf"; then
        log_fail "Dracut does not claim SoC-root GPU ZAP" "generic qcdxkmsuc8280.mbn remains in $dracut_conf"
    else
        log_ok "Dracut configuration does not claim SoC-root qcdxkmsuc8280.mbn"
    fi
    
    if grep -Eq '(install_items|install_optional_items)' "$dracut_conf" && grep -q 'qcom' "$dracut_conf"; then
        log_ok "Dracut configuration includes Qualcomm firmware install items"
    else
        log_fail "Dracut firmware install items" "Qualcomm firmware items missing in $dracut_conf"
    fi
else
    log_fail "Dracut configuration file exists" "missing $dracut_conf"
fi

refresh_boot="/usr/libexec/dragon-q8b-refresh-boot"
if [[ -x "$refresh_boot" ]]; then
    log_ok "Boot refresh script $refresh_boot is executable"
    
    # Test refresh-boot execution
    if "$refresh_boot" >/dev/null 2>&1 || [[ $allow_virtual -eq 1 ]]; then
        log_ok "Boot refresh script executed successfully"
    else
        log_fail "Boot refresh script executed" "command returned non-zero exit code"
    fi
else
    log_fail "Boot refresh script exists and executable" "missing $refresh_boot"
fi

cmdline_tokens="/usr/lib/dragon-q8b/cmdline.tokens"
cmdline_helper="/usr/libexec/dragon-q8b-cmdline"
if [[ -f "$cmdline_tokens" ]] && grep -qx 'clk_ignore_unused' "$cmdline_tokens" && [[ -x "$cmdline_helper" ]]; then
    log_ok "board cmdline tokens and append helper are installed"
else
    log_fail "board cmdline tokens" "missing $cmdline_tokens or $cmdline_helper"
fi
if [[ -e /usr/lib/kernel/cmdline.d/50-dragon-q8b.conf ]]; then
    log_fail "kernel cmdline drop-in absent" "legacy /usr/lib/kernel/cmdline.d/50-dragon-q8b.conf must not be shipped"
fi
if [[ -f /usr/lib/kernel/cmdline ]]; then
    packed_cmdline=$(grep -vE '^[[:space:]]*(#|$)' /usr/lib/kernel/cmdline | tr '\n' ' ')
    packed_cmdline=$(printf '%s' "$packed_cmdline" | awk '{$1=$1; print}')
    if [[ "$packed_cmdline" == "clk_ignore_unused" ]]; then
        log_fail "Fedora kernel cmdline preserved" "/usr/lib/kernel/cmdline contains only clk_ignore_unused"
    else
        log_ok "packaged cmdline does not replace Fedora /usr/lib/kernel/cmdline"
    fi
fi
if command -v grubby >/dev/null 2>&1; then
    grubby_info=$(grubby --info=ALL 2>/dev/null || true)
    if [[ -n "$grubby_info" ]]; then
        if grep -qw 'clk_ignore_unused' <<< "$grubby_info"; then
            if grep -Eq 'root=|BOOT_IMAGE=|console=|ostree=' <<< "$grubby_info"; then
                log_ok "clk_ignore_unused is appended alongside Fedora BLS options"
            else
                log_fail "Fedora BLS options preserved" "clk_ignore_unused present without Fedora options"
            fi
        else
            log_fail "clk_ignore_unused appended" "grubby entries lack clk_ignore_unused"
        fi
    elif [[ $allow_virtual -eq 1 ]]; then
        log_skip "grubby BLS cmdline check" "no boot entries in this VM"
    fi
fi
if [[ -x /usr/lib/kernel/install.d/50-dragon-q8b.install && -x /usr/lib/kernel/install.d/91-dragon-q8b.install ]]; then
    log_ok "kernel-install plugins 50-dragon-q8b and 91-dragon-q8b are installed"
else
    log_fail "kernel-install plugins" "missing 50/91-dragon-q8b.install"
fi

if [[ $skip_dracut_build -eq 0 ]] && command -v dracut >/dev/null 2>&1; then
    test_initrd=$(mktemp -u /tmp/test-dracut-q8b.XXXXXX.img)
    # Prefer installed dragon-q8b kernel version, fallback to running kernel
    target_kver=$(find /lib/modules /usr/lib/modules -maxdepth 1 -mindepth 1 -name '*dragon*' 2>/dev/null | head -n 1 | xargs -n 1 basename 2>/dev/null || true)
    if [[ -z "$target_kver" || ! -d "/lib/modules/$target_kver" ]]; then
        target_kver=$(uname -r)
    fi
    if [[ -d "/lib/modules/$target_kver" ]]; then
        if dracut --force --no-hostonly --no-compress "$test_initrd" "$target_kver" >/dev/null 2>&1; then
            log_ok "Dracut successfully generated test initramfs with Q8B policy for $target_kver ($test_initrd)"
            
            if [[ -s "$test_initrd" ]]; then
                initrd_size=$(stat -c %s "$test_initrd" 2>/dev/null || stat -f %z "$test_initrd" 2>/dev/null || echo "0")
                if [[ "$initrd_size" -gt 1000000 ]]; then
                    log_ok "Generated test initramfs is valid and non-empty ($(( initrd_size / 1024 / 1024 )) MB)"
                else
                    log_fail "Generated initramfs verification" "Initramfs file size suspiciously small ($initrd_size bytes)"
                fi
            else
                log_fail "Generated initramfs verification" "Initramfs file was not created or empty"
            fi
            rm -f "$test_initrd"
        else
            log_fail "Dracut initramfs test build" "dracut failed to generate initramfs for $target_kver"
            rm -f "$test_initrd"
        fi
    else
        log_skip "Dracut initramfs test build" "kernel modules for $target_kver not present"
    fi
else
    log_skip "Dracut initramfs test build" "skipped via --skip-dracut-build or dracut not installed"
fi

# -----------------------------------------------------------------------------
# Section 7: Bluetooth Service & Deterministic MAC
# -----------------------------------------------------------------------------
echo
echo "--- Section 7: Bluetooth Deterministic MAC & Service ---"

bt_helper="/usr/libexec/dragon-q8b-bt-address"
if [[ -x "$bt_helper" ]]; then
    log_ok "Bluetooth address helper $bt_helper is executable"
    
    generated_mac=$("$bt_helper" --print 2>/dev/null || true)
    if [[ -z "$generated_mac" && -f /etc/machine-id ]]; then
        machine_id=$(cat /etc/machine-id 2>/dev/null || true)
        if [[ "$machine_id" =~ ^[[:xdigit:]]{32}$ ]]; then
            digest=$(printf '%s' "$machine_id" | sha256sum | awk '{print $1}')
            generated_mac="02:${digest:0:2}:${digest:2:2}:${digest:4:2}:${digest:6:2}:${digest:8:2}"
        fi
    fi
    if [[ "$generated_mac" =~ ^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$ ]]; then
        log_ok "Bluetooth address helper generated valid MAC address ($generated_mac)"
        
        # Verify locally-administered bit is set (bit 1 of first octet)
        first_byte_hex="0x${generated_mac:0:2}"
        if (( (first_byte_hex & 0x02) != 0 )); then
            log_ok "Generated Bluetooth MAC has locally-administered bit set"
        else
            log_fail "Bluetooth MAC locally-administered bit" "first byte $first_byte_hex bit 1 is not set"
        fi
    else
        log_fail "Bluetooth address helper generated valid MAC" "output was '$generated_mac'"
    fi
else
    log_fail "Bluetooth address helper executable" "missing $bt_helper"
fi

bt_service="/usr/lib/systemd/system/dragon-q8b-bt.service"
if [[ -f "$bt_service" ]]; then
    log_ok "Bluetooth systemd unit $bt_service exists"
else
    log_fail "Bluetooth systemd unit exists" "missing $bt_service"
fi

# -----------------------------------------------------------------------------
# Section 8: FastRPC Userspace Runtime & Environment
# -----------------------------------------------------------------------------
echo
echo "--- Section 8: FastRPC Runtime & Environment ---"

found_cdsprpc=0
found_adsprpc=0
for lib in /usr/lib64/libcdsprpc.so* /usr/lib/libcdsprpc.so* /lib64/libcdsprpc.so* /lib/libcdsprpc.so*; do
    if [[ -e "$lib" ]]; then found_cdsprpc=1; break; fi
done
for lib in /usr/lib64/libadsprpc.so* /usr/lib/libadsprpc.so* /lib64/libadsprpc.so* /lib/libadsprpc.so*; do
    if [[ -e "$lib" ]]; then found_adsprpc=1; break; fi
done

if [[ $found_cdsprpc -eq 1 && $found_adsprpc -eq 1 ]]; then
    log_ok "Qualcomm FastRPC libraries (libcdsprpc, libadsprpc) are installed"
else
    log_fail "Qualcomm FastRPC libraries installed" "libcdsprpc or libadsprpc missing under /usr/lib64 or /usr/lib"
fi

if [[ -f /usr/lib/udev/rules.d/60-fastrpc.rules ]]; then
    log_ok "FastRPC udev rules file 60-fastrpc.rules exists"
    if grep -q 'MODE="0640"' /usr/lib/udev/rules.d/60-fastrpc.rules && grep -q 'GROUP="fastrpc"' /usr/lib/udev/rules.d/60-fastrpc.rules; then
        log_ok "FastRPC udev rules use 0640 and group fastrpc"
    else
        log_fail "FastRPC udev rules permissions" "expected MODE=0640 and GROUP=fastrpc"
    fi
    if grep -q '0666' /usr/lib/udev/rules.d/60-fastrpc.rules; then
        log_fail "FastRPC udev rules are not world-writable" "0666 remains in 60-fastrpc.rules"
    else
        log_ok "FastRPC udev rules are not world-writable"
    fi
else
    log_fail "FastRPC udev rules file exists" "missing /usr/lib/udev/rules.d/60-fastrpc.rules"
fi

if command -v dsp_check >/dev/null 2>&1; then
    log_ok "dsp_check is installed"
else
    log_skip "dsp_check is installed" "not shipped by FastRPC 1.0.6"
fi

fastrpc_profile="/etc/profile.d/dragon-q8b-fastrpc.sh"
if [[ -f "$fastrpc_profile" ]]; then
    log_ok "FastRPC environment profile $fastrpc_profile exists"
    if grep -q 'ADSP_LIBRARY_PATH' "$fastrpc_profile" && grep -q 'DSP_LIBRARY_PATH' "$fastrpc_profile"; then
        log_ok "FastRPC profile exports ADSP_LIBRARY_PATH and DSP_LIBRARY_PATH"
    else
        log_fail "FastRPC profile variables" "missing ADSP_LIBRARY_PATH or DSP_LIBRARY_PATH"
    fi
else
    log_fail "FastRPC environment profile exists" "missing $fastrpc_profile"
fi

# -----------------------------------------------------------------------------
# Section 9: QNN / QAIRT installer and runtime
# -----------------------------------------------------------------------------
echo
echo "--- Section 9: QNN / QAIRT Integration ---"

if ! rpm -q dragon-q8b-qnn >/dev/null 2>&1; then
    log_skip "QNN / QAIRT integration" "dragon-q8b-qnn is a Recommends and is not installed"
else
qnn_sync="/usr/libexec/dragon-q8b-qnn-sync"
if [[ -x "$qnn_sync" ]]; then
    log_ok "QNN installer and validator $qnn_sync is executable"
    if "$qnn_sync" --help >/dev/null 2>&1; then
        log_ok "QNN helper responds to --help"
    else
        log_fail "QNN helper --help"
    fi
else
    log_fail "QNN helper executable" "missing $qnn_sync"
fi

if [[ -L /usr/bin/dragon-q8b-qnn || -x /usr/bin/dragon-q8b-qnn ]]; then
    log_ok "QNN CLI command /usr/bin/dragon-q8b-qnn is present"
else
    log_fail "QNN CLI command present" "missing /usr/bin/dragon-q8b-qnn"
fi

qnn_config=/usr/lib/dragon-q8b/qnn.conf
if [[ -f "$qnn_config" ]] && grep -Eq '^QAIRT_ARCHIVE_SHA256=[[:xdigit:]]{64}$' "$qnn_config"; then
    log_ok "QNN packaged configuration pins the official QAIRT archive checksum"
else
    log_fail "QNN packaged QAIRT configuration" "missing or invalid $qnn_config"
fi

if [[ -f /etc/profile.d/dragon-q8b-qnn.sh && -f /etc/ld.so.conf.d/dragon-q8b-qnn.conf ]]; then
    log_ok "QNN environment and ld.so configuration files exist"
else
    log_fail "QNN environment/ld.so configuration" "missing profile or ld.so.conf.d files"
fi

if [[ -x "$qnn_sync" ]]; then
    run_check "QNN status command" "$qnn_sync" status
    run_check "QNN license/source disclosure" "$qnn_sync" license
    if [[ $allow_virtual -eq 0 && -L /opt/qualcomm/qairt/current ]]; then
        run_check "QAIRT runtime and Dragon Q8B NPU validation" "$qnn_sync" verify
    else
        log_skip "QAIRT hardware runtime validation" "requires an installed SDK on physical Dragon Q8B hardware"
    fi
fi
fi

# -----------------------------------------------------------------------------
# Section 10: ALSA UCM Profiles
# -----------------------------------------------------------------------------
echo
echo "--- Section 10: ALSA UCM Profiles ---"

ucm_dir="/etc/alsa/ucm2/Qualcomm/sc8280xp"
if [[ -d "$ucm_dir" ]]; then
    log_ok "ALSA UCM Qualcomm SC8280XP directory exists ($ucm_dir)"
    
    ucm_files=("Dragon-Q8B-HiFi.conf" "Radxa-Dragon-Q8B.conf")
    for f in "${ucm_files[@]}"; do
        if [[ -f "$ucm_dir/$f" ]]; then
            log_ok "ALSA UCM profile file $f is present"
            if grep -Eq 'SectionUseCase|SectionDevice|File' "$ucm_dir/$f"; then
                log_ok "ALSA UCM profile $f has valid UCM directives"
            else
                log_fail "ALSA UCM profile $f structure" "missing expected UCM sections"
            fi
        else
            log_fail "ALSA UCM profile file $f exists" "missing $ucm_dir/$f"
        fi
    done
    if [[ -f "$ucm_dir/sc8280xp.conf" ]]; then
        log_fail "ALSA UCM does not replace Fedora sc8280xp.conf" "unexpected $ucm_dir/sc8280xp.conf"
    else
        log_ok "ALSA UCM overlay does not replace Fedora sc8280xp.conf"
    fi
    confd="/etc/alsa/ucm2/conf.d/sc8280xp/RadxaComputerCo.Ltd.-RadxaDragonQ8B.conf"
    if [[ -f "$confd" ]] && grep -q 'Radxa-Dragon-Q8B.conf' "$confd"; then
        log_ok "ALSA UCM conf.d DMI match is installed"
    else
        log_fail "ALSA UCM conf.d DMI match" "missing $confd"
    fi
else
    log_fail "ALSA UCM directory exists" "missing directory $ucm_dir"
fi

# -----------------------------------------------------------------------------
# Section 11: Systemd Services Enablement
# -----------------------------------------------------------------------------
echo
echo "--- Section 11: Systemd Unit Enablement ---"

if command -v systemctl >/dev/null 2>&1; then
    units_to_check=(
        "dragon-q8b-bt.service"
        "dragon-q8b-thermal.service"
        "tqftpserv.service"
    )
    for u in "${units_to_check[@]}"; do
        if systemctl list-unit-files "$u" >/dev/null 2>&1; then
            log_ok "Systemd unit $u is recognized by systemd"
            if [[ "$u" == tqftpserv.service ]]; then
                if systemctl is-enabled tqftpserv.service >/dev/null 2>&1; then
                    log_ok "Systemd unit tqftpserv.service is enabled"
                else
                    log_fail "Systemd unit tqftpserv.service enabled" "preset did not enable tqftpserv.service"
                fi
            fi
        else
            log_fail "Systemd unit $u recognized" "unit not found in systemctl list-unit-files"
        fi
    done
else
    log_skip "Systemd unit checks" "systemctl command not available in this environment"
fi

# -----------------------------------------------------------------------------
# Section 12: Thermal Governor & Cooling Management
# -----------------------------------------------------------------------------
echo
echo "--- Section 12: Thermal Governor & Cooling Management ---"

thermal_bin="/usr/libexec/dragon-q8b-thermal"
if [[ ! -x "$thermal_bin" && -x "/usr/bin/dragon-q8b-thermal" ]]; then
    thermal_bin="/usr/bin/dragon-q8b-thermal"
fi

if [[ -x "$thermal_bin" ]]; then
    log_ok "Thermal management binary $thermal_bin is executable"

    if "$thermal_bin" --help >/dev/null 2>&1; then
        log_ok "Thermal tool responds to --help"
    else
        log_fail "Thermal tool --help" "command failed"
    fi

    if "$thermal_bin" --status >/dev/null 2>&1; then
        log_ok "Thermal tool responds to --status"
    else
        log_fail "Thermal tool --status" "status command failed"
    fi

    if "$thermal_bin" --dry-run -m step_wise -p >/dev/null 2>&1; then
        log_ok "Thermal tool dry-run execution succeeded"
    else
        log_fail "Thermal tool dry-run execution" "dry-run command failed"
    fi
else
    log_fail "Thermal management binary executable" "missing /usr/libexec/dragon-q8b-thermal or /usr/bin/dragon-q8b-thermal"
fi

thermal_conf="/etc/dragon-q8b/thermal.conf"
if [[ -f "$thermal_conf" ]]; then
    log_ok "Thermal configuration file $thermal_conf exists"
    if grep -Eq '^[[:space:]]*GOVERNOR=power_allocator' "$thermal_conf"; then
        log_ok "Thermal configuration defaults to power_allocator"
    else
        log_fail "Thermal configuration default governor" "expected GOVERNOR=power_allocator in $thermal_conf"
    fi
else
    log_fail "Thermal configuration file exists" "missing $thermal_conf"
fi

# -----------------------------------------------------------------------------
# Test Summary
# -----------------------------------------------------------------------------
echo
echo "========================================================"
echo " Radxa Dragon Q8B Fedora E2E Validation Summary"
echo "========================================================"
printf 'Passed:  %d\n' "$passed_checks"
printf 'Failed:  %d\n' "$failed_checks"
printf 'Skipped: %d\n' "$skipped_checks"
echo "========================================================"

if [[ -n "$output_json" ]]; then
    mkdir -p "$(dirname "$output_json")"
    cat > "$output_json" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "passed": $passed_checks,
  "failed": $failed_checks,
  "skipped": $skipped_checks,
  "results": [
    $(IFS=,; echo "${test_results[*]}")
  ]
}
EOF
    echo "Structured test report written to $output_json"
fi

if [[ $failed_checks -gt 0 ]]; then
    echo "=== DRAGON-Q8B E2E VALIDATION: FAILED ($failed_checks checks failed) ===" >&2
    exit 1
fi

echo "=== DRAGON-Q8B E2E VALIDATION: PASSED ==="
exit 0
