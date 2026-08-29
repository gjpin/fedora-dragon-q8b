%{!?package_release:%global package_release 1}

Name:           dragon-q8b-support
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Full Fedora support bundle for Radxa Dragon Q8B
License:        MIT
URL:            https://docs.radxa.com/en/dragon/q8b
BuildArch:      noarch

Requires:       qrtr
Requires:       tqftpserv
Requires:       bluez
Requires:       alsa-ucm
Requires:       qcom-firmware
Requires:       dracut
Requires:       grubby
Requires:       pciutils
Requires:       usbutils
Requires:       ethtool
Requires:       iw
Requires:       i2c-tools
Requires:       libgpiod-utils
Requires:       alsa-utils
Requires:       dragon-q8b-kernel
Requires:       dragon-q8b-firmware
Requires:       dragon-q8b-boot
Requires:       dragon-q8b-overlays
Requires:       dragon-q8b-alsa-ucm
Requires:       dragon-q8b-fastrpc
Requires:       dragon-q8b-qnn

%description
Meta-package that installs the Fedora and COPR components required for the
Radxa Dragon Q8B board. It does not flash boot firmware or remove stock
kernels.

%files

%changelog
* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Initial Dragon Q8B support bundle.
