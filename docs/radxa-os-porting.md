# Dragon Q8B porting basis

This project treats Radxa OS as the compatibility authority and Armbian as a
secondary source for portable kernel changes.

## What is taken from Radxa OS

Radxa documents the Dragon Q8B as a Qualcomm SC8280XP / Snapdragon 8cx Gen 3
board. Its relevant platform contract is:

| Area | Radxa OS basis | Fedora implementation |
| --- | --- | --- |
| Boot | UEFI/systemd-boot flow and board-specific DTB | Fedora kernel DTB plus `dragon-q8b-boot`; boot entries are updated with `grubby` |
| Base DT | `sc8280xp-radxa-dragon-q8b.dts` from Radxa's kernel | The pinned Radxa DTS is inserted verbatim into Fedora's ARM64 DTB build; Armbian never supplies the board DTS |
| Remote processors | SC8280XP ADSP/CDSP/SLPI/VSS/TrustZone hand-off | Radxa firmware package plus Fedora `qcom-firmware`, with the required files copied into initramfs |
| Audio | WCD9385 SoundWire codec and Radxa UCM profiles | Fedora kernel SoundWire/SC8280XP support and a small `/etc/alsa/ucm2` overlay |
| Display/media | Adreno display pipeline, DP/HDMI bridge, Iris/VPU firmware | DRM/MSM, DP, bridge, Iris/Venus configuration and firmware |
| Storage | UFS, NVMe, and microSD | Fedora UFS, PCIe, MMC, and storage drivers built into or shipped by the kernel |
| Ethernet | QPS615/TC9564 PCIe switch and two 2.5GbE ports | Q8B DT plus TC956X, XPCS, stmmac, and QCA808x changes from the pinned queue |
| Expansion | Q8B GPIO/I²C/SPI/UART muxes | Radxa overlays compiled and shipped as `.dtbo` files |
| Wi-Fi/Bluetooth | Qualcomm radio firmware and controller setup | Fedora firmware, `bluez`, and a deterministic locally-administered BT address via `dragon-q8b-bt.service` |
| NPU / FastRPC | Hexagon DSP FastRPC runtime | Qualcomm open-source FastRPC libraries (`libcdsprpc`, `libadsprpc`), udev rules, and DSP library environment paths (`dragon-q8b-fastrpc`) |
| AI Acceleration | Qualcomm QAIRT/QNN SDK | `dragon-q8b-qnn` downloads the checksum-pinned official SDK after explicit license acceptance and validates the SC8280XP HTP v68 backend |
| Thermal & Cooling | `rsetup` thermal governor modes (`step_wise`, `power_allocator`) | `dragon-q8b-thermal` utility (defaulting to `step_wise` for PWM fan cooling), `/etc/dragon-q8b/thermal.conf`, and persistent tmpfiles policy |

Radxa's OS build is product/SoC oriented: it combines a board kernel, a
firmware package, overlays, ALSA UCM, FastRPC runtime, and a UEFI boot configuration. Fedora
therefore keeps those concerns in separate RPMs and uses a meta-package to
install the tested set together. Ubuntu `.deb` packages are not installed on
Fedora; only the Radxa ALSA UCM data is repackaged because it is configuration
data rather than an Ubuntu runtime.

## Kernel refresh flow

1. `refresh-vendor.sh` resolves the latest Radxa kernel, firmware, overlay,
   ALSA UCM, FastRPC, and Armbian refs. It downloads those project-specific inputs,
   verifies them, and opens a pull request.
2. `prepare-kernel-source.sh` starts with Fedora's current kernel dist-git
   source, inserts the vendored Radxa DTS verbatim, verifies the local Armbian
   SC8280XP driver/SoC queue, and declares the result as Fedora `Patch3003`.
   The Armbian board-DTS patch is neither listed nor downloaded.
3. `check-patch-redundancy.sh` prepares an unmodified Fedora source tree,
   applies Fedora's own kernel patch, and checks each Armbian patch in both
   directions. It stops on patches that are partially upstream or otherwise
   require semantic review.
4. The Fedora kernel config fragment enables the board's Qualcomm remoteproc,
   PCIe/UFS/MMC, SoundWire/audio, DRM/display, Iris/VPU, networking, GPIO,
   serial, I²C, and SPI paths.
5. Pull-request CI builds source RPMs in Fedora 44 from Fedora's kernel source
   plus the vendored Radxa/Armbian/Qualcomm inputs. After merge, the publishing workflow
   submits the same repository contents to the staging COPR. The kernel build
   ID and support-package release include the workflow run and attempt numbers,
   so rebuilt content cannot collide with an older COPR NVR.
6. A maintainer must validate the physical board before promoting staging to
   the production COPR project.

The queue is deliberately applied after Fedora's own kernel patch. A Fedora
kernel refresh that conflicts with the Q8B queue fails the build for review;
it is not silently rebased or partially applied.

## QAIRT/QNN licensing

QAIRT Community Edition is the original Qualcomm distribution containing QNN,
SNPE, and Genie. Its AI Stack license permits application-incorporated object
code but prohibits standalone SDK redistribution. Consequently COPR ships only
the MIT-licensed `dragon-q8b-qnn` integration. The user reviews the license and
explicitly downloads the pinned SDK from Qualcomm Software Center with
`dragon-q8b-qnn install --accept-license`.

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
