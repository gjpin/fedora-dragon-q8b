# Dragon Q8B porting basis

This project treats Radxa OS as the compatibility authority and Armbian as a
secondary source for portable kernel changes.

## What is taken from Radxa OS

Radxa documents the Dragon Q8B as a Qualcomm SC8280XP / Snapdragon 8cx Gen 3
board. Its relevant platform contract is:

| Area | Radxa OS basis | Fedora implementation |
| --- | --- | --- |
| Boot | UEFI/systemd-boot flow and board-specific DTB | Fedora kernel DTB plus `dragon-q8b-boot` (append-only `clk_ignore_unused` via grubby/BLS, kernel-install `fdtoverlay` merge, BLS `devicetree`) |
| Base DT | `sc8280xp-radxa-dragon-q8b.dts` from Radxa's kernel | The pinned Radxa DTS is inserted verbatim into Fedora's ARM64 DTB build; Armbian never supplies the board DTS |
| Remote processors | SC8280XP ADSP/CDSP/SLPI/VSS/TrustZone hand-off | Radxa firmware package plus Fedora `qcom-firmware`, with the required files copied into initramfs |
| Audio | WCD9385 SoundWire codec and Radxa UCM profiles | Fedora kernel SoundWire/SC8280XP support, Q8B UCM files under `/etc/alsa/ucm2`, and a conf.d DMI match. Fedora's SoC `sc8280xp.conf` is not replaced. |
| Display/media | Adreno display pipeline, DP/HDMI bridge, Iris/VPU firmware | DRM/MSM, DP, bridge, Iris/Venus configuration and firmware |
| Storage | UFS, NVMe, and microSD | Fedora UFS, PCIe, MMC, and storage drivers built into or shipped by the kernel |
| Ethernet | QPS615/TC9564 PCIe switch and two 2.5GbE ports | Q8B DT plus TC956X, XPCS, stmmac, and QCA808x changes from the pinned queue |
| Expansion | Q8B GPIO/I²C/SPI/UART muxes and optional 6845B fan | Radxa overlays plus local `pwm-fan` overlay (schematic GPIO119 `pwm-gpio`; Q20 inversion compensated; pulled-high fail-safe intent modeled; period/RPM response still unvalidated); enable with `dragon-q8b-overlay` |
| Wi-Fi/Bluetooth | Qualcomm radio firmware and M.2 E-key controller setup (no modem/`rmtfs`) | Fedora firmware, `bluez`, and a deterministic locally-administered BT address via `dragon-q8b-bt.service` |
| NPU / FastRPC | Hexagon DSP FastRPC runtime | Qualcomm FastRPC 1.0.6 (`fastrpc`) plus `dragon-q8b-fastrpc` DSP search paths; upstream udev 0640 + group `fastrpc` |
| AI Acceleration | Qualcomm QAIRT/QNN SDK | `dragon-q8b-qnn` (Recommends) downloads the checksum-pinned Software Center Community Edition after explicit license acceptance and validates the SC8280XP HTP v68 backend |
| Thermal & Cooling | `rsetup` thermal governor modes (`step_wise`, `power_allocator`) | Default `power_allocator` (fanless). Optional Heatsink 6845B overlay uses schematic GPIO119; `step_wise` only on zones that list a `pwm-fan` cooling device. Packaged `/usr/lib/tmpfiles.d/dragon-q8b-thermal.conf` plus a oneshot apply after sysfs bind. |

Radxa's OS build is product/SoC oriented: it combines a board kernel, a
firmware package, overlays, ALSA UCM, FastRPC runtime, and a UEFI boot configuration. Fedora
therefore keeps those concerns in separate RPMs and uses a meta-package to
install the tested set together. Ubuntu `.deb` packages are not installed on
Fedora; Radxa ALSA UCM is vendored from the git tag tarball (with submodule)
and only the Q8B profiles plus conf.d DMI files are packaged.

## Kernel refresh flow

1. `refresh-vendor.sh` resolves the latest Radxa kernel, firmware, overlay,
   ALSA UCM, FastRPC, Armbian, and Fedora `f44` kernel dist-git refs. It
   downloads the project-specific inputs, verifies them, pins
   `FEDORA_KERNEL_COMMIT` / `FEDORA_KERNEL_VERSION`, commits to `main`, and
   starts the publishing workflow (SRPM build, QEMU E2E, then COPR if the
   tests pass).
2. `prepare-kernel-source.sh` checks out the pinned Fedora kernel dist-git
   commit, inserts the vendored Radxa DTS verbatim, verifies the local Armbian
   SC8280XP driver/SoC queue, and declares the result as Fedora `Patch3003`.
   The Armbian board-DTS patch is neither listed nor downloaded.
3. `check-patch-redundancy.sh` prepares an unmodified Fedora source tree,
   applies Fedora's own kernel patch, and checks each Armbian patch in both
   directions. It stops on patches that are partially upstream or otherwise
   require semantic review.
4. The Fedora kernel config fragment enables the board's Qualcomm remoteproc,
   PCIe/UFS/MMC, SoundWire/audio, DRM/display, Iris/VPU, networking, GPIO,
   serial, I²C, and SPI paths.
5. Pull-request CI builds source RPMs in Fedora 44 from the pinned Fedora
   kernel source plus the vendored Radxa/Armbian/Qualcomm inputs. Path-filtered
   pushes to `main` also run QEMU E2E. COPR publish is a manual
   `workflow_dispatch` or the vendor refresh workflow, after the SRPM gate
   succeeds. The kernel build ID and support-package release include the
   workflow run and attempt numbers, so rebuilt content cannot collide with an
   older COPR NVR.
6. A maintainer must still validate the physical board. Board-owned kernel
   arguments such as `clk_ignore_unused` are appended to Fedora's existing
   command line.

The queue is deliberately applied after Fedora's own kernel patch. A Fedora
kernel refresh that conflicts with the Q8B queue fails the build for review;
it is not silently rebased or partially applied.

## QAIRT/QNN licensing

QAIRT Community Edition is the original Qualcomm distribution containing QNN,
SNPE, and Genie. Its AI Stack license permits application-incorporated object
code but prohibits standalone SDK redistribution. Consequently COPR ships only
the MIT-licensed `dragon-q8b-qnn` integration. The user reviews the license once
and downloads the checksum-pinned SDK from Qualcomm Software Center with
`dragon-q8b-qnn install --accept-license`. Vendor refresh follows the Software
Center catalog (not Yocto or Radxa docs, which can lag). After that first
accept, RPM pin updates install silently while `LICENSE.pdf` is unchanged.

## References

- [Radxa Dragon Q8B documentation](https://docs.radxa.com/en/dragon/q8b)
- [Radxa OS build system](https://docs.radxa.com/en/dragon/q6a/low-level-dev/build-system/radxa-os)
- [Radxa kernel package](https://github.com/radxa-pkg/linux-qcom)
- [Radxa firmware package](https://github.com/radxa-pkg/radxa-firmware)
- [Radxa overlays package](https://github.com/radxa-pkg/radxa-overlays)
- [Radxa QAIRT installation](https://docs.radxa.com/en/dragon/q8b/app-dev/npu-dev/qairt-install)
- [Radxa FastRPC setup](https://docs.radxa.com/en/dragon/q8b/app-dev/npu-dev/fastrpc-setup)
- [Qualcomm AI Engine Direct SDK](https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct-sdk)
- [Armbian Dragon Q8B board configuration](https://github.com/armbian/build/blob/main/config/boards/radxa-dragon-q8b.conf)
