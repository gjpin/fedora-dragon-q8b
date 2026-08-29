%{!?package_release:%global package_release 1}

Name:           dragon-q8b-boot
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Fedora boot and initramfs integration for Radxa Dragon Q8B
License:        MIT
URL:            https://github.com/radxa-pkg/linux-qcom
BuildArch:      noarch
Requires:       dracut
Requires:       grubby
Requires(posttrans): dracut

Source0:        dragon-q8b-bt-address
Source1:        dragon-q8b-bt.conf
Source2:        40-dragon-q8b.conf
Source3:        dragon-q8b-refresh-boot
Source4:        dragon-q8b-bt.service

%description
Installs the Dragon Q8B device-tree boot selection, Qualcomm firmware
initramfs policy, and deterministic Bluetooth address setup used by Fedora.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_libexecdir}/dragon-q8b-bt-address
install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/dragon-q8b/bluetooth.conf
install -Dpm0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/dracut.conf.d/40-dragon-q8b.conf
install -Dpm0755 %{SOURCE3} %{buildroot}%{_libexecdir}/dragon-q8b-refresh-boot
install -Dpm0644 %{SOURCE4} %{buildroot}%{_unitdir}/dragon-q8b-bt.service

%posttrans
if [ -x %{_libexecdir}/dragon-q8b-refresh-boot ]; then
    %{_libexecdir}/dragon-q8b-refresh-boot || :
fi
if command -v dracut >/dev/null 2>&1; then
    dracut --regenerate-all --force || :
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || :
fi

%files
%config(noreplace) %{_sysconfdir}/dragon-q8b/bluetooth.conf
%config(noreplace) %{_sysconfdir}/dracut.conf.d/40-dragon-q8b.conf
%{_unitdir}/dragon-q8b-bt.service
%{_libexecdir}/dragon-q8b-bt-address
%{_libexecdir}/dragon-q8b-refresh-boot

%changelog
* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Initial Fedora boot and initramfs integration.
