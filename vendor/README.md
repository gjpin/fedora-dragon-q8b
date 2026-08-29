# Vendored build inputs

This directory contains the exact Radxa and Armbian source inputs used by the
Dragon Q8B packages. The Radxa archives are large files tracked with Git LFS;
patches, metadata, and manifests remain ordinary Git files.

`scripts/refresh-vendor.sh` is the only intended writer. It checks Radxa,
Armbian, and ALSA upstream revisions, downloads a staged snapshot, and updates
`packaging/inputs.lock` only after all inputs pass validation.

Builds consume this directory for project-specific inputs. Fedora's kernel
dist-git source, base RPM repositories, build container, and GitHub Actions
runner remain external infrastructure dependencies.

## Original sources

The revisions below are the sources used for the files currently in this
directory. SHA-256 values are recorded in [`../packaging/inputs.lock`](../packaging/inputs.lock)
and [`SHA256SUMS`](SHA256SUMS).

| Vendored files | Original source |
| --- | --- |
| `radxa/kernel/sc8280xp-radxa-dragon-q8b.dts` | [`radxa/kernel`](https://github.com/radxa/kernel/blob/4a7a039590c7185ed9c53453b163806311799eed/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts), branch `linux-7.0.11`, commit `4a7a039590c7185ed9c53453b163806311799eed` |
| `radxa/firmware/radxa-firmware-*.tar.gz` | [`radxa-pkg/radxa-firmware`](https://github.com/radxa-pkg/radxa-firmware/archive/e1761009df008adfd62c77f2c5584e3067449013.tar.gz), commit `e1761009df008adfd62c77f2c5584e3067449013` |
| `radxa/overlays/radxa-overlays-*.tar.gz` | [`radxa-pkg/radxa-overlays`](https://github.com/radxa-pkg/radxa-overlays/archive/be64705364a8f131da018e322e04f3232e56d9a9.tar.gz), commit `be64705364a8f131da018e322e04f3232e56d9a9` |
| `radxa/alsa/alsa-ucm-conf_*.deb` | [`radxa-pkg/alsa-ucm-conf` release `1.2.16.1-radxa-1`](https://github.com/radxa-pkg/alsa-ucm-conf/releases/tag/1.2.16.1-radxa-1), asset `alsa-ucm-conf_1.2.16.1-radxa-1_all.deb` |
| `armbian/sc8280xp-edge-patches/*.patch` | [`armbian/build`](https://github.com/armbian/build/tree/1f33ee9db0063ec281d3c273ac5df5dcd6f84450/patch/kernel/archive/sc8280xp-edge), commit `1f33ee9db0063ec281d3c273ac5df5dcd6f84450` |

The Armbian patch filenames are listed in
[`../config/armbian-sc8280xp-edge-patches.list`](../config/armbian-sc8280xp-edge-patches.list);
each file was taken from the `patch/kernel/archive/sc8280xp-edge/` directory
at that exact commit. `SHA256SUMS` and the Armbian checksum manifest are
repository-generated provenance and integrity files, not upstream source
files.
