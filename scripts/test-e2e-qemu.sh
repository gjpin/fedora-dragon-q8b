#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: test-e2e-qemu.sh [options]

Execute full End-to-End (E2E) validation of Fedora Dragon Q8B setup in a QEMU
aarch64 virtual machine.

Options:
  --copr OWNER/PROJECT     COPR repository to test (e.g. user/dragon-q8b-staging)
  --rpm-dir DIR            Local directory containing RPM packages to install and test
  --release N              Fedora release version (default: 44)
  --image FILE             Path to an existing base Fedora aarch64 cloud image (.qcow2)
  --image-url URL          URL to download base Fedora aarch64 cloud image
  --firmware FILE          Path to UEFI firmware code (QEMU_EFI.fd / edk2-aarch64-code.fd)
  --accel ACCEL            QEMU accelerator (hvf, kvm, tcg, or auto; default: auto)
  --cpu CPU                QEMU CPU model (default: auto: host for KVM/HVF, max for TCG)
  --memory MB              VM memory in megabytes (default: 4096)
  --smp N                  Number of virtual CPUs (default: 4)
  --timeout SEC            Execution timeout in seconds (default: 1200)
  --output DIR             Directory to save console logs and test reports
  --dry-run                Print QEMU launch command and exit without starting VM
  -h, --help               Show this help message
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/config/dragon-q8b.env"

copr_repo=""
rpm_dir=""
image_file=""
target_release="${FEDORA_RELEASE:-44}"
image_url=""
firmware_code=""
accel="auto"
cpu_type="auto"
memory="4096"
smp="4"
timeout_sec=3000
output_dir=""
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copr) copr_repo=${2:?missing OWNER/PROJECT}; shift 2 ;;
        --rpm-dir) rpm_dir=${2:?missing RPM directory}; shift 2 ;;
        --release)
            target_release=${2:?missing release number}
            shift 2
            ;;
        --image) image_file=${2:?missing image file}; shift 2 ;;
        --image-url) image_url=${2:?missing image URL}; shift 2 ;;
        --firmware) firmware_code=${2:?missing firmware file}; shift 2 ;;
        --accel) accel=${2:?missing accelerator}; shift 2 ;;
        --cpu) cpu_type=${2:?missing CPU model}; shift 2 ;;
        --memory) memory=${2:?missing memory size}; shift 2 ;;
        --smp) smp=${2:?missing CPU count}; shift 2 ;;
        --timeout) timeout_sec=${2:?missing timeout in seconds}; shift 2 ;;
        --output) output_dir=${2:?missing output directory}; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$output_dir" ]]; then
    output_dir=$(mktemp -d -t dragon-q8b-e2e-output.XXXXXX)
else
    mkdir -p "$output_dir"
fi

console_log="$output_dir/qemu-console.log"

find_qemu() {
    local qemu_bin
    qemu_bin=$(command -v qemu-system-aarch64 || true)
    if [[ -z "$qemu_bin" ]]; then
        if [[ $dry_run -eq 1 ]]; then
            printf 'qemu-system-aarch64'
            return 0
        fi
        echo "qemu-system-aarch64 is required but was not found in PATH" >&2
        exit 1
    fi
    printf '%s' "$qemu_bin"
}

find_uefi_firmware() {
    if [[ -n "$firmware_code" && -f "$firmware_code" ]]; then
        return 0
    fi

    local search_paths=(
        # Fedora / RHEL
        "/usr/share/edk2/aarch64/QEMU_EFI.fd"
        "/usr/share/edk2/aarch64/QEMU_EFI.silent.fd"
        # Debian / Ubuntu
        "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
        "/usr/share/AAVMF/AAVMF_CODE.fd"
        "/usr/share/AAVMF/AAVMF32_CODE.fd"
        # macOS Homebrew (Apple Silicon & Intel)
        "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
        "/usr/local/share/qemu/edk2-aarch64-code.fd"
        # Generic fallback
        "/usr/share/qemu/edk2-aarch64-code.fd"
    )

    for p in "${search_paths[@]}"; do
        if [[ -f "$p" ]]; then
            firmware_code="$p"
            break
        fi
    done

    # Try wildcards for Homebrew versioned directories
    if [[ -z "$firmware_code" ]]; then
        for p in /opt/homebrew/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd /usr/local/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd; do
            if [[ -f "$p" ]]; then
                firmware_code="$p"
                break
            fi
        done
    fi

    if [[ -z "$firmware_code" ]]; then
        if [[ $dry_run -eq 1 ]]; then
            firmware_code="/usr/share/edk2/aarch64/QEMU_EFI.fd"
            return 0
        fi
        echo "UEFI firmware for aarch64 (QEMU_EFI.fd or edk2-aarch64-code.fd) was not found." >&2
        echo "Install edk2-aarch64 (Fedora), qemu-efi-aarch64 (Ubuntu), or qemu via brew (macOS)." >&2
        exit 1
    fi
}

detect_accelerator() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)

    if [[ "$accel" == "auto" ]]; then
        if [[ "$os" == "Darwin" && "$arch" == "arm64" ]]; then
            accel="hvf"
        elif [[ "$os" == "Linux" && -r "/dev/kvm" && -w "/dev/kvm" && "$arch" == "aarch64" ]]; then
            accel="kvm"
        else
            accel="tcg,thread=multi"
        fi
    fi

    if [[ -z "$cpu_type" || "$cpu_type" == "auto" ]]; then
        if [[ "$accel" == "hvf" || "$accel" == "kvm" ]]; then
            cpu_type="host"
        else
            cpu_type="max,pauth=off"
        fi
    fi
}

qemu_cmd=$(find_qemu)
find_uefi_firmware
detect_accelerator

resolve_fedora_cloud_image_url() {
    local images_url name checksum_text listing
    if [[ "$target_release" == "${FEDORA_RELEASE:-44}" && -n "${FEDORA_CLOUD_IMAGES_URL:-}" ]]; then
        images_url=$FEDORA_CLOUD_IMAGES_URL
    else
        images_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${target_release}/Cloud/aarch64/images/"
    fi
    images_url=${images_url%/}/
    checksum_text=$(curl -fsSL "${images_url}CHECKSUM" 2>/dev/null || true)
    name=$(printf '%s\n' "$checksum_text" | awk '
        match($0, /Fedora-Cloud-Base-Generic-[^ )]+[.]aarch64[.]qcow2/) {
            print substr($0, RSTART, RLENGTH)
            exit
        }
    ')
    if [[ -z "$name" ]]; then
        listing=$(curl -fsSL "$images_url" 2>/dev/null || true)
        name=$(printf '%s\n' "$listing" | grep -oE 'Fedora-Cloud-Base-Generic-[^"<> ]+\.aarch64\.qcow2' | sort -u | tail -n1)
    fi
    [[ -n "$name" ]] || {
        echo "could not resolve Fedora Cloud Generic qcow2 from $images_url" >&2
        exit 1
    }
    image_url="${images_url}${name}"
}

if [[ -z "$image_file" && -z "$image_url" ]]; then
    resolve_fedora_cloud_image_url
fi

work_dir=$(mktemp -d -t dragon-q8b-qemu-vm.XXXXXX)
# shellcheck disable=SC2329
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Base Image Preparation
# -----------------------------------------------------------------------------
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dragon-q8b-e2e"
mkdir -p "$cache_dir"

if [[ -z "$image_file" ]]; then
    cached_base="$cache_dir/$(basename "$image_url")"
    if [[ ! -f "$cached_base" ]]; then
        if [[ $dry_run -eq 1 ]]; then
            cached_base="$cache_dir/$(basename "$image_url")"
        else
            echo "Downloading Fedora aarch64 base cloud image from $image_url..."
            curl -fSL --retry 3 --retry-all-errors "$image_url" -o "$cached_base.tmp"
            mv "$cached_base.tmp" "$cached_base"
        fi
    fi
    image_file="$cached_base"
fi

if [[ $dry_run -eq 0 && ! -f "$image_file" ]]; then
    echo "Base image file not found: $image_file" >&2
    exit 1
fi

vm_disk="$work_dir/disk-overlay.qcow2"
if [[ $dry_run -eq 0 ]]; then
    echo "Creating VM disk overlay from $image_file..."
    if command -v qemu-img >/dev/null 2>&1; then
        qemu_img_cmd=$(command -v qemu-img)
        base_format=$(qemu-img info "$image_file" 2>/dev/null | awk '/^file format:/ {print $3}' || true)
        base_format=${base_format:-qcow2}
        "$qemu_img_cmd" create -f qcow2 -b "$image_file" -F "$base_format" "$vm_disk" >/dev/null
    else
        cp "$image_file" "$vm_disk"
    fi
fi

# -----------------------------------------------------------------------------
# Prepare UEFI Firmware Code & VARS (Padded to 64MB for QEMU aarch64 virt pflash)
# -----------------------------------------------------------------------------
vm_code="$work_dir/vm-code.fd"
if [[ $dry_run -eq 0 ]]; then
    cp "$firmware_code" "$vm_code"
    if command -v truncate >/dev/null 2>&1; then
        truncate -s 64M "$vm_code"
    else
        dd if=/dev/null of="$vm_code" bs=1M seek=64 2>/dev/null || true
    fi
fi

vars_template=""
vars_dir=$(dirname "$firmware_code")
for candidate in "$vars_dir/QEMU_VARS.fd" "$vars_dir/edk2-arm-vars.fd" "$vars_dir/AAVMF_VARS.fd" "$vars_dir/edk2-aarch64-vars.fd"; do
    if [[ -f "$candidate" ]]; then
        vars_template="$candidate"
        break
    fi
done

vm_vars="$work_dir/vm-vars.fd"
if [[ $dry_run -eq 0 ]]; then
    if [[ -n "$vars_template" && -f "$vars_template" ]]; then
        cp "$vars_template" "$vm_vars"
    else
        : > "$vm_vars"
    fi
    if command -v truncate >/dev/null 2>&1; then
        truncate -s 64M "$vm_vars"
    else
        dd if=/dev/null of="$vm_vars" bs=1M seek=64 2>/dev/null || true
    fi
fi

# -----------------------------------------------------------------------------
# Cloud-init NoCloud Seed ISO Generation
# -----------------------------------------------------------------------------
cidata_dir="$work_dir/cidata"
mkdir -p "$cidata_dir"

cat > "$cidata_dir/meta-data" <<EOF
instance-id: dragon-q8b-e2e-$(date +%s)
local-hostname: fedora-dragon-q8b-e2e
EOF

guest_script="$cidata_dir/run-e2e-guest.sh"
cat > "$guest_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Direct all output to console and guest log
exec > >(tee -a /dev/console /root/e2e-guest.log) 2>&1

guest_exit() {
    local ec=$?
    set +e
    echo "=== DRAGON-Q8B GUEST EXECUTION FINISHED (exit code: $ec) ==="
    sync
    poweroff -f || shutdown -h now || systemctl poweroff -ff || reboot -f || true
}
trap guest_exit EXIT ERR INT TERM

if [[ -f /root/.e2e-started ]]; then
    exit 0
fi
touch /root/.e2e-started

echo "========================================================"
echo " Starting In-Guest Dragon Q8B E2E Validation"
echo "========================================================"

# Mount 9p repo share if available, otherwise use embedded /root/repo
repo_mount="/root/repo"
mkdir -p /repo
if mount -t 9p -o trans=virtio,version=9p2000.L repo /repo 2>/dev/null; then
    echo "Host repository mounted via 9p virtfs at /repo"
    repo_mount="/repo"
elif [[ -d "/root/repo" ]]; then
    echo "Using embedded repository scripts from /root/repo"
fi

# Install COPR and/or local packages. QEMU virt cannot boot the custom Q8B
# kernel, so the guest installs the userspace stack and only nodeps-installs
# dragon-q8b-support (it Requires the custom kernel).
copr_target="__COPR_TARGET__"
dnf_cmd=$(command -v dnf5 2>/dev/null || command -v dnf 2>/dev/null || echo "dnf")
dnf_opts=(
    --nodocs
    --setopt=install_weak_deps=False
    --setopt=max_parallel_downloads=1
    --setopt=timeout=120
    --setopt=retries=10
)
userspace_fedora_pkgs=(qrtr tqftpserv bluez alsa-ucm qcom-firmware pd-mapper dracut grubby)
userspace_q8b_pkgs=(
    dragon-q8b-firmware
    dragon-q8b-boot
    dragon-q8b-overlays
    dragon-q8b-alsa-ucm
    fastrpc
    dragon-q8b-fastrpc
    dragon-q8b-qnn
)

mount_rpm_dir() {
    mkdir -p /mnt/rpm-9p /mnt/q8brpms /rpm-packages
    if mount -t 9p -o trans=virtio,version=9p2000.L rpm-packages /mnt/rpm-9p 2>/dev/null \
        && compgen -G "/mnt/rpm-9p/*.rpm" >/dev/null; then
        echo "Host RPM directory mounted via 9p virtfs at /mnt/rpm-9p" >&2
        printf '%s' /mnt/rpm-9p
        return 0
    fi
    local rpms_dev=""
    rpms_dev=$(blkid -L Q8BRPMS 2>/dev/null || true)
    if [[ -z "$rpms_dev" ]]; then
        for cand in /dev/disk/by-label/Q8BRPMS /dev/vdb /dev/vdc /dev/sda /dev/sdb; do
            if [[ -e "$cand" ]] && blkid "$cand" 2>/dev/null | grep -q 'LABEL="Q8BRPMS"'; then
                rpms_dev=$cand
                break
            fi
        done
    fi
    if [[ -n "$rpms_dev" ]] && mount -o ro "$rpms_dev" /mnt/q8brpms 2>/dev/null \
        && compgen -G "/mnt/q8brpms/*.rpm" >/dev/null; then
        echo "RPM ISO mounted from $rpms_dev at /mnt/q8brpms" >&2
        printf '%s' /mnt/q8brpms
        return 0
    fi
    return 1
}

install_local_rpms() {
    local rpm_mount=$1
    local -a installable=() nodeps=()
    local rpm name
    echo "Installing local RPM packages from $rpm_mount..."
    while IFS= read -r -d '' rpm; do
        name=$(rpm -qp --qf '%{NAME}' "$rpm")
        case "$name" in
            kernel|kernel-core|kernel-modules|kernel-modules-core|kernel-devel|dragon-q8b-kernel)
                echo "Skipping kernel package $name (not used in QEMU virt)"
                ;;
            *-debuginfo|*-debugsource|fastrpc-devel)
                echo "Skipping $name"
                ;;
            dragon-q8b-support)
                nodeps+=("$rpm")
                ;;
            *)
                installable+=("$rpm")
                ;;
        esac
    done < <(find "$rpm_mount" -maxdepth 1 -type f -name '*.rpm' ! -name '*.src.rpm' -print0)

    "$dnf_cmd" -y install "${dnf_opts[@]}" "${userspace_fedora_pkgs[@]}"
    if [[ ${#installable[@]} -gt 0 ]]; then
        "$dnf_cmd" -y install "${dnf_opts[@]}" "${installable[@]}"
    fi
    if [[ ${#nodeps[@]} -gt 0 ]]; then
        echo "Installing dragon-q8b-support with --nodeps (custom kernel not present in QEMU)"
        rpm -Uvh --nodeps "${nodeps[@]}"
    fi
}

install_copr_userspace() {
    local copr=$1
    if [[ "$copr" != */* ]]; then
        echo "COPR must be OWNER/PROJECT (got: $copr)" >&2
        exit 1
    fi
    fedora_ver=$(rpm -E '%{fedora}' 2>/dev/null || true)
    [[ -n "$fedora_ver" ]] || {
        echo "could not detect Fedora release for COPR enable" >&2
        exit 1
    }
    if ! "$dnf_cmd" copr --help >/dev/null 2>&1; then
        "$dnf_cmd" -y install --setopt=install_weak_deps=False --nodocs dnf-plugins-core >/dev/null 2>&1 || \
            "$dnf_cmd" -y install --setopt=install_weak_deps=False --nodocs dnf5-plugins || true
    fi
    "$dnf_cmd" -y copr enable "$copr"
    if [[ -x "$repo_mount/scripts/bootstrap-fedora-dragon-q8b.sh" ]]; then
        echo "Running bootstrap-fedora-dragon-q8b.sh from repository..."
        bash "$repo_mount/scripts/bootstrap-fedora-dragon-q8b.sh" --force --skip-dracut --copr "$copr" \
            || echo "bootstrap could not install dragon-q8b-support (expected in QEMU without the custom kernel)"
    fi
    echo "Installing Fedora and Dragon Q8B userspace packages from COPR..."
    "$dnf_cmd" -y install "${dnf_opts[@]}" --skip-unavailable \
        "${userspace_fedora_pkgs[@]}" "${userspace_q8b_pkgs[@]}" || true
    "$dnf_cmd" -y install "${dnf_opts[@]}" dragon-q8b-support \
        || echo "dragon-q8b-support not installed (missing from COPR or requires custom kernel)"
}

rpm_mount=""
if rpm_mount=$(mount_rpm_dir); then
    install_local_rpms "$rpm_mount"
elif [[ -n "$copr_target" && "$copr_target" != "none" ]]; then
    install_copr_userspace "$copr_target"
else
    echo "No local RPMs or COPR target available; validation will fail missing packages" >&2
fi

# Install validation utilities (e.g. dtc for DTB decompile testing)
"$dnf_cmd" -y install --setopt=install_weak_deps=False --nodocs dtc 2>/dev/null || true

# Run the validation suite
if [[ -x "$repo_mount/scripts/validate-e2e.sh" ]]; then
    echo "Executing validate-e2e.sh from repository..."
    bash "$repo_mount/scripts/validate-e2e.sh" --allow-virtual --output-json /root/e2e-results.json
else
    echo "Running fallback validate-runtime..."
    if [[ -x "$repo_mount/scripts/validate-runtime.sh" ]]; then
        bash "$repo_mount/scripts/validate-runtime.sh"
    fi
fi
EOF

# Substitute placeholders
sed "s|__COPR_TARGET__|${copr_repo:-none}|g" "$guest_script" > "$guest_script.tmp" && mv "$guest_script.tmp" "$guest_script"
chmod +x "$guest_script"

cat > "$cidata_dir/user-data" <<EOF
#cloud-config
output:
  all: '| tee -a /dev/console /var/log/cloud-init-output.log'
bootcmd:
  - ssh-keygen -A || true
ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
    root:fedora
  expire: false
write_files:
  - path: /root/run-e2e-guest.sh
    permissions: '0755'
    owner: root:root
    content: |
$(sed 's/^/      /' "$guest_script")
  - path: /root/repo/scripts/bootstrap-fedora-dragon-q8b.sh
    permissions: '0755'
    owner: root:root
    content: |
$(sed 's/^/      /' "$repo_root/scripts/bootstrap-fedora-dragon-q8b.sh")
  - path: /root/repo/scripts/validate-e2e.sh
    permissions: '0755'
    owner: root:root
    content: |
$(sed 's/^/      /' "$repo_root/scripts/validate-e2e.sh")
  - path: /root/repo/scripts/validate-runtime.sh
    permissions: '0755'
    owner: root:root
    content: |
$(sed 's/^/      /' "$repo_root/scripts/validate-runtime.sh")
  - path: /root/repo/config/dragon-q8b.env
    permissions: '0644'
    owner: root:root
    content: |
$(sed 's/^/      /' "$repo_root/config/dragon-q8b.env")
runcmd:
  - [ bash, /root/run-e2e-guest.sh ]
EOF

cidata_iso="$work_dir/cidata.iso"
rpm_iso=""
if [[ $dry_run -eq 0 ]]; then
    echo "Generating cloud-init seed drive ($cidata_iso)..."

    if command -v genisoimage >/dev/null 2>&1; then
        genisoimage -output "$cidata_iso" -volid cidata -joliet -rock "$cidata_dir/user-data" "$cidata_dir/meta-data" >/dev/null 2>&1
    elif command -v mkisofs >/dev/null 2>&1; then
        mkisofs -output "$cidata_iso" -volid cidata -joliet -rock "$cidata_dir/user-data" "$cidata_dir/meta-data" >/dev/null 2>&1
    elif command -v xorrisofs >/dev/null 2>&1; then
        xorrisofs -output "$cidata_iso" -volid cidata -joliet -rock "$cidata_dir/user-data" "$cidata_dir/meta-data" >/dev/null 2>&1
    elif command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$cidata_iso" "$cidata_dir/user-data" "$cidata_dir/meta-data"
    else
        python3 - "$cidata_dir" "$cidata_iso" <<'PYEOF'
import sys
import os
import shutil
import subprocess

src_dir = sys.argv[1]
iso_out = sys.argv[2]

for cmd in ['genisoimage', 'mkisofs', 'xorrisofs']:
    bin_path = shutil.which(cmd)
    if bin_path:
        res = subprocess.call([
            bin_path, '-output', iso_out, '-volid', 'cidata', '-joliet', '-rock',
            os.path.join(src_dir, 'user-data'), os.path.join(src_dir, 'meta-data')
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res == 0:
            sys.exit(0)

sys.exit(1)
PYEOF
    fi
fi

if [[ -n "$rpm_dir" && -d "$rpm_dir" ]]; then
    rpm_iso="$work_dir/rpms.iso"
    if [[ $dry_run -eq 0 ]]; then
        shopt -s nullglob
        rpm_files=("$rpm_dir"/*.rpm)
        shopt -u nullglob
        if [[ ${#rpm_files[@]} -eq 0 ]]; then
            echo "No RPM files found in $rpm_dir" >&2
            rpm_iso=""
        else
            echo "Generating RPM data drive ($rpm_iso)..."
            iso_ok=0
            if command -v xorrisofs >/dev/null 2>&1; then
                xorrisofs -output "$rpm_iso" -volid Q8BRPMS -joliet -rock "${rpm_files[@]}" >/dev/null 2>&1 && iso_ok=1
            fi
            if [[ $iso_ok -eq 0 ]] && command -v genisoimage >/dev/null 2>&1; then
                genisoimage -output "$rpm_iso" -volid Q8BRPMS -joliet -rock "${rpm_files[@]}" >/dev/null 2>&1 && iso_ok=1
            fi
            if [[ $iso_ok -eq 0 ]] && command -v mkisofs >/dev/null 2>&1; then
                mkisofs -output "$rpm_iso" -volid Q8BRPMS -joliet -rock "${rpm_files[@]}" >/dev/null 2>&1 && iso_ok=1
            fi
            if [[ $iso_ok -eq 0 ]]; then
                echo "could not generate RPM ISO from $rpm_dir (install xorriso/genisoimage)" >&2
                exit 1
            fi
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Assemble QEMU Command Line
# -----------------------------------------------------------------------------
qemu_args=(
    "$qemu_cmd"
    -M virt
    -accel "$accel"
    -cpu "$cpu_type"
    -m "$memory"
    -smp "$smp"
    -nographic
    -no-reboot
    -drive "if=pflash,format=raw,unit=0,file=$vm_code,readonly=on"
    -drive "if=pflash,format=raw,unit=1,file=$vm_vars"
    -drive "file=$vm_disk,format=qcow2,if=virtio,cache=unsafe"
    -drive "file=$cidata_iso,format=raw,if=virtio"
    -netdev "user,id=net0"
    -device "virtio-net-pci,netdev=net0"
    -device "virtio-rng-pci"
    -serial "stdio"
    -monitor "none"
)

if "$qemu_cmd" -help 2>/dev/null | grep -q -- '-virtfs'; then
    qemu_args+=(-virtfs "local,path=$repo_root,mount_tag=repo,security_model=none,readonly=on")
fi

if [[ -n "$rpm_dir" && -d "$rpm_dir" ]]; then
    qemu_args+=(-virtfs "local,path=$rpm_dir,mount_tag=rpm-packages,security_model=none,readonly=on")
fi
if [[ -n "$rpm_iso" && ( $dry_run -eq 1 || -f "$rpm_iso" ) ]]; then
    qemu_args+=(-drive "file=$rpm_iso,format=raw,if=virtio,readonly=on")
fi

echo "========================================================"
echo " Fedora Dragon Q8B QEMU E2E Test Runner"
echo "========================================================"
echo " QEMU Binary:    $qemu_cmd"
echo " Accelerator:    $accel"
echo " CPU Model:      $cpu_type ($smp cores)"
echo " Memory:         ${memory} MB"
echo " Firmware:       $firmware_code"
echo " Base Image:     $image_file"
echo " Target COPR:    ${copr_repo:-none (standalone)}"
echo " Local RPMs:     ${rpm_dir:-none}"
echo " Output Log:     $console_log"
echo " Timeout:        ${timeout_sec}s"
echo "========================================================"

if [[ $dry_run -eq 1 ]]; then
    echo "Dry run mode requested. QEMU command:"
    printf '%q ' "${qemu_args[@]}"
    echo
    exit 0
fi

echo "Starting QEMU VM..."
qemu_pid=""
start_time=$(date +%s)

# Execute QEMU with console redirect
"${qemu_args[@]}" > "$console_log" 2>&1 &
qemu_pid=$!

# Stream console output live to workflow stdout
tail_pid=""
if command -v tail >/dev/null 2>&1; then
    tail -n +1 -f "$console_log" 2>/dev/null &
    tail_pid=$!
fi

# Monitor QEMU with timeout watchdog
timed_out=0
while kill -0 "$qemu_pid" 2>/dev/null; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [[ $elapsed -ge $timeout_sec ]]; then
        echo "QEMU VM timed out after ${timeout_sec}s! Terminating VM process ($qemu_pid)..." >&2
        timed_out=1
        kill -9 "$qemu_pid" 2>/dev/null || true
        break
    fi
    sleep 2
done

if [[ -n "$tail_pid" ]]; then
    sleep 1
    kill "$tail_pid" 2>/dev/null || true
fi
wait "$qemu_pid" 2>/dev/null || true

echo
echo "QEMU VM execution ended."

if [[ $timed_out -eq 1 ]]; then
    echo "=== DRAGON-Q8B E2E TEST: TIMED OUT ===" >&2
    exit 1
fi

if grep -q '=== DRAGON-Q8B E2E VALIDATION: PASSED ===' "$console_log"; then
    echo "=== DRAGON-Q8B E2E TEST: PASSED ==="
    exit 0
else
    echo "=== DRAGON-Q8B E2E TEST: FAILED ===" >&2
    exit 1
fi
