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

Automatic builds target `dragon-q8b-staging`. Use workflow dispatch with
`dragon-q8b` only after physical-board validation.

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
kernel repackaging. The custom release identifier is `.dragonq8b.<run>`, so
stock Fedora kernels remain available as rollback entries.

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

The proprietary QAI/NPU userspace stack is intentionally not included in the
initial scope.

The source-to-package mapping and Radxa OS compatibility basis are documented
in [docs/radxa-os-porting.md](docs/radxa-os-porting.md).
