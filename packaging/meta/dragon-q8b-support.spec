%{!?package_release:%global package_release 1}
%{!?_presetdir:%global _presetdir %{_prefix}/lib/systemd/system-preset}

Name:           dragon-q8b-support
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Full Fedora support bundle for Radxa Dragon Q8B
License:        MIT
URL:            https://github.com/gjpin/fedora-dragon-q8b
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

Requires:       qrtr
Requires:       tqftpserv
Requires:       bluez
Requires:       alsa-ucm
Requires:       qcom-firmware
Requires:       pd-mapper
Requires:       dracut
Requires:       grubby
Requires:       dragon-q8b-kernel
Requires:       dragon-q8b-firmware
Requires:       dragon-q8b-boot
Requires:       dragon-q8b-overlays
Requires:       dragon-q8b-alsa-ucm
Requires:       dragon-q8b-fastrpc
Recommends:     dragon-q8b-qnn
Recommends:     pciutils
Recommends:     usbutils
Recommends:     ethtool
Recommends:     iw
Recommends:     i2c-tools
Recommends:     libgpiod-utils
Recommends:     alsa-utils

Source0:        50-dragon-q8b-support.preset

%description
Meta-package that installs the Fedora and COPR components required for the
Radxa Dragon Q8B board. It does not flash boot firmware or remove stock
kernels. There is no modem/rmtfs stack; Wi-Fi/BT is M.2 E-key only.

%prep

%build

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_presetdir}/50-dragon-q8b-support.preset

%post
%systemd_post pd-mapper.service

%preun
%systemd_preun pd-mapper.service

%postun
%systemd_postun_with_restart pd-mapper.service

%files
%{_presetdir}/50-dragon-q8b-support.preset

%changelog
* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-2
- Require pd-mapper, recommend debug tools and QNN, enable pd-mapper.

* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Initial Dragon Q8B support bundle.
