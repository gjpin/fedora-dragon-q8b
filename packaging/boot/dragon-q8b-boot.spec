%{!?package_release:%global package_release 1}
%{!?_presetdir:%global _presetdir %{_prefix}/lib/systemd/system-preset}
%{!?_tmpfilesdir:%global _tmpfilesdir %{_prefix}/lib/tmpfiles.d}

Name:           dragon-q8b-boot
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Fedora boot and initramfs integration for Radxa Dragon Q8B
License:        MIT
URL:            https://github.com/gjpin/fedora-dragon-q8b
BuildArch:      noarch
Requires:       dracut
Requires:       dtc
Requires:       systemd
Requires:       grubby
BuildRequires:  systemd-rpm-macros
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

Source0:        dragon-q8b-bt-address
Source1:        dragon-q8b-bt.conf
Source2:        40-dragon-q8b.conf
Source3:        dragon-q8b-refresh-boot
Source4:        dragon-q8b-bt.service
Source5:        dragon-q8b-thermal
Source6:        dragon-q8b-thermal.conf
Source7:        50-dragon-q8b.install
Source8:        91-dragon-q8b.install
Source9:        cmdline.tokens
Source10:       dragon-q8b-thermal.service
Source11:       dragon-q8b-thermal.tmpfiles
Source12:       50-dragon-q8b.preset
Source13:       dragon-q8b-cmdline

%description
Installs Dragon Q8B kernel-install hooks, append-only kernel command-line
tokens, Qualcomm firmware initramfs policy, Bluetooth address setup, and
thermal governor defaults. Kernel packages rebuild initramfs; this RPM
does not call dracut.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_libexecdir}/dragon-q8b-bt-address
install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/dragon-q8b/bluetooth.conf
install -Dpm0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/dracut.conf.d/40-dragon-q8b.conf
install -Dpm0755 %{SOURCE3} %{buildroot}%{_libexecdir}/dragon-q8b-refresh-boot
install -Dpm0644 %{SOURCE4} %{buildroot}%{_unitdir}/dragon-q8b-bt.service
install -Dpm0755 %{SOURCE5} %{buildroot}%{_libexecdir}/dragon-q8b-thermal
install -d %{buildroot}%{_bindir}
ln -s ../libexec/dragon-q8b-thermal %{buildroot}%{_bindir}/dragon-q8b-thermal
install -Dpm0644 %{SOURCE6} %{buildroot}%{_sysconfdir}/dragon-q8b/thermal.conf
install -Dpm0755 %{SOURCE7} %{buildroot}%{_prefix}/lib/kernel/install.d/50-dragon-q8b.install
install -Dpm0755 %{SOURCE8} %{buildroot}%{_prefix}/lib/kernel/install.d/91-dragon-q8b.install
install -Dpm0644 %{SOURCE9} %{buildroot}%{_prefix}/lib/dragon-q8b/cmdline.tokens
install -Dpm0644 %{SOURCE10} %{buildroot}%{_unitdir}/dragon-q8b-thermal.service
install -Dpm0644 %{SOURCE11} %{buildroot}%{_tmpfilesdir}/dragon-q8b-thermal.conf
install -Dpm0644 %{SOURCE12} %{buildroot}%{_presetdir}/50-dragon-q8b.preset
install -Dpm0755 %{SOURCE13} %{buildroot}%{_libexecdir}/dragon-q8b-cmdline

%post
%systemd_post dragon-q8b-bt.service dragon-q8b-thermal.service
if [ -x %{_libexecdir}/dragon-q8b-cmdline ]; then
    %{_libexecdir}/dragon-q8b-cmdline apply || :
fi
if [ -x %{_libexecdir}/dragon-q8b-refresh-boot ]; then
    %{_libexecdir}/dragon-q8b-refresh-boot --best-effort || :
fi

%preun
%systemd_preun dragon-q8b-bt.service dragon-q8b-thermal.service
if [ "$1" -eq 0 ] && [ -x %{_libexecdir}/dragon-q8b-cmdline ]; then
    %{_libexecdir}/dragon-q8b-cmdline remove || :
fi

%postun
%systemd_postun_with_restart dragon-q8b-bt.service dragon-q8b-thermal.service

%files
%config(noreplace) %{_sysconfdir}/dragon-q8b/bluetooth.conf
%config(noreplace) %{_sysconfdir}/dragon-q8b/thermal.conf
%config(noreplace) %{_sysconfdir}/dracut.conf.d/40-dragon-q8b.conf
%{_bindir}/dragon-q8b-thermal
%{_unitdir}/dragon-q8b-bt.service
%{_unitdir}/dragon-q8b-thermal.service
%{_libexecdir}/dragon-q8b-bt-address
%{_libexecdir}/dragon-q8b-refresh-boot
%{_libexecdir}/dragon-q8b-thermal
%{_libexecdir}/dragon-q8b-cmdline
%{_prefix}/lib/kernel/install.d/50-dragon-q8b.install
%{_prefix}/lib/kernel/install.d/91-dragon-q8b.install
%{_prefix}/lib/dragon-q8b/cmdline.tokens
%{_tmpfilesdir}/dragon-q8b-thermal.conf
%{_presetdir}/50-dragon-q8b.preset

%changelog
* Tue Sep 01 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-5
- Clean up thermal management to reflect autonomous ADSP firmware fan control.

* Mon Aug 31 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-4
- Rewrite /etc/kernel/cmdline atomically and remove only tokens this package added.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-3
- Append clk_ignore_unused with grubby/BLS instead of a cmdline.d drop-in.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-2
- Replace posttrans dracut with kernel-install, cmdline.d, and thermal oneshot.

* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Initial Fedora boot and initramfs integration with thermal management.
