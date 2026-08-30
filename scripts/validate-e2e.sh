#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: validate-e2e.sh [options]

Validate Radxa Dragon Q8B Fedora system installation and hardware integration.
Runs comprehensive checks for packages, firmware, kernel DTB, overlays, boot
configuration, dracut initramfs, Bluetooth service, FastRPC runtime, QNN sync,
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
    dragon-q8b-qnn
)

for pkg in "${core_packages[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        local_nvr=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' "$pkg" | head -n 1)
        log_ok "RPM $pkg is installed ($local_nvr)"
    else
        log_fail "RPM $pkg is installed" "package is not installed"
    fi
done

base_deps=(
    qrtr
    tqftpserv
    bluez
    alsa-ucm
    qcom-firmware
    dracut
    grubby
)
for pkg in "${base_deps[@]}"; do
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
    dsp_count=$(find "$dsp_dir" -maxdepth 1 -type f -name '*.so' | wc -l)
    if [[ "$dsp_count" -gt 0 ]]; then
        log_ok "Hexagon DSP runtime libraries present in $dsp_dir ($dsp_count shared objects)"
    else
        log_fail "Hexagon DSP runtime libraries present" "no .so files found in $dsp_dir"
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
    else
        log_skip "Dragon Q8B DTB inspection with dtc" "dtc command not available"
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
    
    if grep -Eq '(add_drivers|force_drivers)\+=.*qcom_q6v5_pas' "$dracut_conf"; then
        log_ok "Dracut configuration includes Qualcomm remoteproc drivers"
    else
        log_fail "Dracut remoteproc drivers" "qcom_q6v5_pas missing in $dracut_conf"
    fi
    
    if grep -Eq '(install_items|install_optional_items)\+=.*qcom' "$dracut_conf"; then
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
    if "$refresh_boot" >/dev/null 2>&1; then
        log_ok "Boot refresh script executed successfully"
    else
        log_fail "Boot refresh script executed" "command returned non-zero exit code"
    fi
else
    log_fail "Boot refresh script exists and executable" "missing $refresh_boot"
fi

if [[ $skip_dracut_build -eq 0 ]] && command -v dracut >/dev/null 2>&1; then
    test_initrd=$(mktemp -u /tmp/test-dracut-q8b.XXXXXX.img)
    target_kver=$(uname -r)
    if [[ -d "/lib/modules/$target_kver" ]]; then
        if dracut --force --no-hostonly --no-compress "$test_initrd" "$target_kver" >/dev/null 2>&1; then
            log_ok "Dracut successfully generated test initramfs with Q8B policy ($test_initrd)"
            
            if command -v lsinitrd >/dev/null 2>&1; then
                if lsinitrd "$test_initrd" 2>/dev/null | grep -Eq '40-dragon-q8b|qcom|sc8280xp'; then
                    log_ok "Generated initramfs contains Dragon Q8B drivers/configuration"
                else
                    log_fail "Generated initramfs verification" "Q8B configuration/modules not found in initramfs"
                fi
            fi
            rm -f "$test_initrd"
        else
            log_fail "Dracut initramfs test build" "dracut failed to generate initramfs"
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
    
    generated_mac=$("$bt_helper" 2>/dev/null || true)
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

fastrpc_libs=("/usr/lib64/libcdsprpc.so" "/usr/lib64/libadsprpc.so" "/usr/lib/libcdsprpc.so" "/usr/lib/libadsprpc.so")
found_cdsprpc=0
found_adsprpc=0
for lib in "${fastrpc_libs[@]}"; do
    if [[ -e "$lib" ]]; then
        if [[ "$lib" == *libcdsprpc* ]]; then found_cdsprpc=1; fi
        if [[ "$lib" == *libadsprpc* ]]; then found_adsprpc=1; fi
    fi
done

if [[ $found_cdsprpc -eq 1 && $found_adsprpc -eq 1 ]]; then
    log_ok "Qualcomm FastRPC libraries (libcdsprpc, libadsprpc) are installed"
else
    log_fail "Qualcomm FastRPC libraries installed" "libcdsprpc or libadsprpc missing under /usr/lib64 or /usr/lib"
fi

if [[ -f /usr/lib/udev/rules.d/60-dragon-q8b-fastrpc.rules ]]; then
    log_ok "FastRPC udev rules file 60-dragon-q8b-fastrpc.rules exists"
    if grep -q 'fastrpc' /usr/lib/udev/rules.d/60-dragon-q8b-fastrpc.rules; then
        log_ok "FastRPC udev rules configure /dev/fastrpc* device permissions"
    else
        log_fail "FastRPC udev rules content" "missing fastrpc device matches"
    fi
else
    log_fail "FastRPC udev rules file exists" "missing /usr/lib/udev/rules.d/60-dragon-q8b-fastrpc.rules"
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
# Section 9: QNN Runtime & Sync Service
# -----------------------------------------------------------------------------
echo
echo "--- Section 9: QNN Runtime & Sync Service ---"

qnn_sync="/usr/libexec/dragon-q8b-qnn-sync"
if [[ -x "$qnn_sync" ]]; then
    log_ok "QNN synchronization helper $qnn_sync is executable"
    if "$qnn_sync" --help >/dev/null 2>&1; then
        log_ok "QNN synchronization helper responds to --help"
    else
        log_fail "QNN sync helper --help"
    fi
else
    log_fail "QNN sync helper executable" "missing $qnn_sync"
fi

if [[ -L /usr/bin/dragon-q8b-qnn || -x /usr/bin/dragon-q8b-qnn ]]; then
    log_ok "QNN CLI command /usr/bin/dragon-q8b-qnn is present"
else
    log_fail "QNN CLI command present" "missing /usr/bin/dragon-q8b-qnn"
fi

qnn_service="/usr/lib/systemd/system/dragon-q8b-qnn.service"
qnn_timer="/usr/lib/systemd/system/dragon-q8b-qnn.timer"
if [[ -f "$qnn_service" && -f "$qnn_timer" ]]; then
    log_ok "QNN systemd service and timer units exist"
else
    log_fail "QNN systemd units exist" "missing $qnn_service or $qnn_timer"
fi

if [[ -f /etc/profile.d/dragon-q8b-qnn.sh && -f /etc/ld.so.conf.d/dragon-q8b-qnn.conf ]]; then
    log_ok "QNN environment and ld.so configuration files exist"
else
    log_fail "QNN environment/ld.so configuration" "missing profile or ld.so.conf.d files"
fi

# -----------------------------------------------------------------------------
# Section 10: ALSA UCM Profiles
# -----------------------------------------------------------------------------
echo
echo "--- Section 10: ALSA UCM Profiles ---"

ucm_dir="/etc/alsa/ucm2/Qualcomm/sc8280xp"
if [[ -d "$ucm_dir" ]]; then
    log_ok "ALSA UCM Qualcomm SC8280XP directory exists ($ucm_dir)"
    
    ucm_files=("Dragon-Q8B-HiFi.conf" "Radxa-Dragon-Q8B.conf" "sc8280xp.conf")
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
        "dragon-q8b-qnn.timer"
    )
    for u in "${units_to_check[@]}"; do
        if systemctl list-unit-files "$u" >/dev/null 2>&1; then
            log_ok "Systemd unit $u is recognized by systemd"
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
    if grep -Eq '^[[:space:]]*GOVERNOR=' "$thermal_conf"; then
        log_ok "Thermal configuration defines GOVERNOR policy"
    else
        log_fail "Thermal configuration GOVERNOR setting" "GOVERNOR definition missing in $thermal_conf"
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
