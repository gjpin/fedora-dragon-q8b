# Dragon Q8B porting basis

This project treats Radxa OS as the compatibility authority and Armbian as a
secondary source for portable kernel changes.

## What is taken from Radxa OS

Radxa documents the Dragon Q8B as a Qualcomm SC8280XP / Snapdragon 8cx Gen 3
board. Its relevant platform contract is:

| Area | Radxa OS basis | Fedora implementation |
| --- | --- | --- |
| Boot | UEFI/systemd-boot flow and board-specific DTB | Fedora kernel DTB plus `dragon-q8b-boot`; boot entries are updated with `grubby` |
| Base DT | `sc8280xp-radxa-dragon-q8b.dts` from Radxa's kernel | The pinned Q8B patch adds the DTB to Fedora's ARM64 DTB build |
| Remote processors | SC8280XP ADSP/CDSP/SLPI/VSS/TrustZone hand-off | Radxa firmware package plus Fedora `qcom-firmware`, with the required files copied into initramfs |
| Audio | WCD9385 SoundWire codec and Radxa UCM profiles | Fedora kernel SoundWire/SC8280XP support and a small `/etc/alsa/ucm2` overlay |
| Display/media | Adreno display pipeline, DP/HDMI bridge, Iris/VPU firmware | DRM/MSM, DP, bridge, Iris/Venus configuration and firmware |
| Storage | UFS, NVMe, and microSD | Fedora UFS, PCIe, MMC, and storage drivers built into or shipped by the kernel |
| Ethernet | QPS615/TC9564 PCIe switch and two 2.5GbE ports | Q8B DT plus TC956X, XPCS, stmmac, and QCA808x changes from the pinned queue |
| Expansion | Q8B GPIO/I²C/SPI/UART muxes | Radxa overlays compiled and shipped as `.dtbo` files |
| Wi-Fi/Bluetooth | Qualcomm radio firmware and controller setup | Fedora firmware, `bluez`, and a deterministic locally-administered BT address |

Radxa's OS build is product/SoC oriented: it combines a board kernel, a
firmware package, overlays, ALSA UCM, and a UEFI boot configuration. Fedora
therefore keeps those concerns in separate RPMs and uses a meta-package to
install the tested set together. Ubuntu `.deb` packages are not installed on
Fedora; only the Radxa ALSA UCM data is repackaged because it is configuration
data rather than an Ubuntu runtime.

## Kernel refresh flow

1. `check-updates.sh` resolves the current Fedora kernel branch and the latest
   Radxa kernel, firmware, overlay, and Armbian refs.
2. `prepare-kernel-source.sh` checks the pinned Radxa DTS for Q8B-specific
   firmware, codec, VPU, and QPS615 markers. It then starts with Fedora's
   `kernel.spec`, downloads the pinned Armbian SC8280XP queue, verifies every
   digest, and declares the result as a Fedora `Patch3003`.
3. `check-patch-redundancy.sh` prepares an unmodified Fedora source tree,
   applies Fedora's own kernel patch, and checks each Armbian patch in both
   directions. It stops on patches that are partially upstream or otherwise
   require semantic review.
4. The Fedora kernel config fragment enables the board's Qualcomm remoteproc,
   PCIe/UFS/MMC, SoundWire/audio, DRM/display, Iris/VPU, networking, GPIO,
   serial, I²C, and SPI paths.
5. The workflow builds source RPMs in Fedora 44 and submits them to the
   staging COPR. The kernel build ID includes the workflow run number, so a
   rebuilt kernel cannot collide with an older COPR build that has the same
   upstream Fedora version.
6. The source pins are updated only after source RPM generation succeeds. A
   maintainer must validate the physical board before promoting staging to the
   production COPR project.

The queue is deliberately applied after Fedora's own kernel patch. A Fedora
kernel refresh that conflicts with the Q8B queue fails the build for review;
it is not silently rebased or partially applied.

## Deliberately deferred

The proprietary QAI/NPU userspace stack is not included. It has a different
licensing and userspace ABI surface from the kernel/firmware/board support
needed for a Fedora server. It can be added later as a separately reviewed
COPR package set.

## References

- [Radxa Dragon Q8B documentation](https://docs.radxa.com/en/dragon/q8b)
- [Radxa OS build system](https://docs.radxa.com/en/dragon/q6a/low-level-dev/build-system/radxa-os)
- [Radxa kernel package](https://github.com/radxa-pkg/linux-qcom)
- [Radxa firmware package](https://github.com/radxa-pkg/radxa-firmware)
- [Radxa overlays package](https://github.com/radxa-pkg/radxa-overlays)
- [Armbian Dragon Q8B board configuration](https://github.com/armbian/build/blob/main/config/boards/radxa-dragon-q8b.conf)
