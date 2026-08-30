# Fedora Dragon Q8B

Fedora support and bootstrap tooling for the Radxa Dragon Q8B (Qualcomm
SC8280XP / Snapdragon 8cx Gen 3).

This project builds a Fedora kernel from Fedora's kernel source, carries the
Q8B/SC8280XP board patch series, packages Radxa's supplemental firmware, and
publishes every custom RPM through COPR. Radxa OS is the primary compatibility
reference; Armbian's SC8280XP edge patches are a pinned secondary source for
kernel changes.

## Install on a Dragon Q8B

Create the production COPR project, enable an aarch64 Fedora chroot, and put
the owner name in the `COPR_OWNER` environment variable. Then run:

```shell
sudo COPR_OWNER=your-copr-user \
  ./scripts/bootstrap-fedora-dragon-q8b.sh
```

The script installs these Fedora packages:

```text
qrtr tqftpserv bluez alsa-ucm qcom-firmware
```

It also installs `dragon-q8b-support` from COPR, which pulls in the custom
kernel, firmware, boot/initramfs integration, overlays, and Q8B ALSA UCM
overlay. It does not flash SPI/UEFI firmware, remove old kernels, perform a
full system upgrade, or reboot automatically.

Use `--force` only for packaging tests. A real board should identify itself as
`radxa,dragon-q8b` in the device tree and run aarch64 Fedora.

## COPR and GitHub Actions

The scheduled refresh workflow checks Radxa kernel, firmware, overlays, ALSA
UCM, and Armbian revisions. When one changes, it downloads and checksums the
corresponding vendor inputs and opens a `bot/vendor-refresh` pull request.
Build validation runs on the pull request; publishing runs only after the
vendored inputs are merged.

Large Radxa source archives use Git LFS. After cloning, run `git lfs install`
and `git lfs pull` before building locally. The build uses the vendored
Radxa/Armbian inputs, while Fedora supplies the kernel dist-git source,
toolchain, and base RPM dependencies.

Configure these repository secrets before scheduled publishing:

- `COPR_OWNER`: COPR user or group that owns the projects.
- `COPR_CONFIG`: the complete `~/.config/copr` file contents for `copr-cli`.

Automatic builds submit packages to `dragon-q8b-staging` only. QEMU E2E is a
staging gate, not a substitute for hardware. Production COPR (`dragon-q8b`) is
promoted manually: **Actions → Build and publish Fedora Dragon Q8B packages →
Run workflow** with **promote_to_production** enabled.

There is no modem/`rmtfs` stack. Wi-Fi and Bluetooth use the M.2 E-key slot.
The PWM fan is optional (official Heatsink 6845B): enable it with
`dragon-q8b-overlay enable pwm-fan` and reboot. The default thermal governor is
`power_allocator`; `step_wise` is applied only when a `pwm-fan` cooling device
exists. The default kernel command line is `clk_ignore_unused` only.

## QEMU End-to-End Testing

You can run the full QEMU aarch64 E2E validation test locally against a COPR repository or a local directory of RPM packages:

```shell
# Test against a COPR project
./scripts/test-e2e-qemu.sh --copr your-copr-user/dragon-q8b-staging

# Or test against locally built RPMs
./scripts/test-e2e-qemu.sh --rpm-dir build/rpms
```

To run only the E2E tests against already-published packages in GitHub Actions without rebuilding:
- Go to the **Actions** tab in GitHub, select **Fedora Dragon Q8B QEMU E2E Validation**, and click **Run workflow**.
- Or trigger it from the CLI with GitHub CLI:
  ```shell
  gh workflow run test-e2e.yml -f copr_project=dragon-q8b-staging
  ```

The runner automatically selects native hardware acceleration (`-accel hvf` on macOS Apple Silicon, `-accel kvm` on Linux with KVM, or `-accel tcg` for software emulation). It boots a Fedora aarch64 Cloud VM with UEFI firmware, installs the Dragon Q8B support bundle, and validates:

- **Firmware & DSP runtime**: Radxa supplemental CDSP, ADSP, QUPv3, VPU blobs, and DSP runtime libraries.
- **Kernel & DTB**: Dragon Q8B DTB decompilation, compatible matching, SoundWire/WCD9385 codec, remoteproc SoC definitions.
- **Device Tree Overlays**: Validates syntax and fragments for all expansion and PCIe overlays.
- **Boot & Dracut Initramfs Policy**: Validates Qualcomm drivers and firmware inclusion in dracut initramfs and tests `/usr/libexec/dragon-q8b-refresh-boot`.
- **Bluetooth Service**: Validates deterministic locally-administered MAC generation and systemd service.
- **FastRPC Runtime**: Validates `libcdsprpc.so`, `libadsprpc.so`, upstream `60-fastrpc.rules` (0640 + group `fastrpc`), and DSP search-path environment variables. `dsp_check` is optional (not in FastRPC 1.0.6).
- **QNN / QAIRT Integration**: Optional `dragon-q8b-qnn` Recommends. When installed, validates the checksum-pinned Qualcomm Software Center Community Edition metadata, installer CLI, license disclosure, and ld.so/profile configuration. The first install requires `--accept-license`. Later `dnf update` refreshes the SDK silently when the bundled license PDF is unchanged. Hardware validation runs after the SDK is installed on a physical Q8B.
- **ALSA UCM Profiles**: Validates Dragon Q8B UCM2 profiles and the conf.d DMI match. Fedora's SoC `sc8280xp.conf` is not replaced.
- **Thermal & Fan Cooling**: Validates `dragon-q8b-thermal`, default `power_allocator`, packaged tmpfiles, and overlay-gated `step_wise` when a `pwm-fan` cooling device exists.

## Local Fedora build

Run these commands in Fedora or a Fedora container with `fedpkg`,
`rpm-build`, `rpmdevtools`, `kernel-rpm-macros`, `python3-devel`, `make`,
`gcc`, `flex`, `bison`, `openssl`, `dtc`, and `ShellCheck` installed:

```shell
mkdir -p build/kernel build/srpms
git lfs pull
./scripts/validate-vendor.sh
./scripts/prepare-kernel-source.sh \
  --release 44 \
  --output build/kernel
./scripts/check-patch-redundancy.sh \
  --kernel-dir build/kernel/kernel \
  --patch-dir build/kernel/dragon-q8b-patches \
  --patch-list config/armbian-sc8280xp-edge-patches.list \
  --output build/kernel/patch-status.tsv
./scripts/build-srpms.sh \
  --release 44 \
  --source-dir build/kernel/kernel \
  --output build/srpms
./scripts/validate-srpms.sh build/srpms
```

The kernel build starts from Fedora's `kernel.spec`; it is not a Debian
kernel repackaging. CI uses `.dragonq8b.<run>.<attempt>` for the kernel and a
matching unique release for every support RPM, so repeated builds cannot reuse
an older COPR NVR. Stock Fedora kernels remain available as rollback entries.

The redundancy report tests each patch against the post-Fedora-patch source.
`FEDORA_PRESENT_EXACT` means Fedora already contains that exact change;
`REQUIRED` means the exact change is not present and still applies;
`COVERED_BY_Q8B_QUEUE` means an earlier Q8B patch already provides it; and
`REVIEW_REQUIRED` stops the build for manual semantic review. `REQUIRED` is a
repeatable patch-level result, not a guarantee that no semantically equivalent
code exists, so semantic reworks should be reviewed before promotion.

## Hardware validation

After a kernel or firmware refresh, validate on hardware:

```shell
sudo ./scripts/validate-runtime.sh
```

Also test boot from microSD/NVMe/UFS, both Ethernet ports, USB-C/HDMI/DP,
audio playback/capture, Wi-Fi/Bluetooth, GPIO/I²C/SPI/UART overlays, GPU/VPU,
thermals, reboot, and shutdown. QEMU and installroot checks in CI cannot
prove physical Q8B peripheral support.

The support bundle includes the `dragon-q8b-qnn` Fedora integration package.
Qualcomm's license prohibits standalone redistribution of the QAIRT SDK, so the
RPM does not contain the proprietary archive. Review the license once, then
install the checksum-pinned Community Edition from Qualcomm Software Center.
Later package updates follow the catalog and refresh the SDK when the license
PDF is unchanged. Radxa's docs and Yocto recipes may lag the catalog.

```shell
dragon-q8b-qnn license
sudo dragon-q8b-qnn install --accept-license
sudo dragon-q8b-qnn verify
```

The source-to-package mapping and Radxa OS compatibility basis are documented
in [docs/radxa-os-porting.md](docs/radxa-os-porting.md).
