%{!?package_release:%global package_release 1}
%{!?_unitdir:%global _unitdir %{_prefix}/lib/systemd/system}

Name:           dragon-q8b-qnn
Version:        0.3.0
Release:        %{package_release}%{?dist}
Summary:        Qualcomm QAIRT/QNN installer and validator for Radxa Dragon Q8B
License:        MIT
URL:            https://github.com/gjpin/fedora-dragon-q8b
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       bash
Requires:       coreutils
Requires:       curl
Requires:       glibc
Requires:       unzip
Requires:       systemd
Requires:       dragon-q8b-fastrpc
Requires:       dragon-q8b-firmware
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

Source0:        dragon-q8b-qnn-sync
Source1:        dragon-q8b-qnn.sh
Source2:        dragon-q8b-qnn.conf
Source3:        dragon-q8b-qnn-ld.so.conf
Source4:        dragon-q8b-qnn-local.conf
Source5:        dragon-q8b-qnn-upgrade.service

%description
Provides Fedora integration that downloads the official Qualcomm AI Runtime
(QAIRT/QNN) Community Edition directly from Qualcomm after explicit license
acceptance, verifies its pinned checksum, installs the SC8280XP HTP v68 runtime,
and validates NPU access. The proprietary SDK is not contained in this RPM.
Packaged pins follow Qualcomm Software Center; after the first license accept,
later pin updates install silently when LICENSE.pdf is unchanged.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_libexecdir}/dragon-q8b-qnn-sync
install -d %{buildroot}%{_bindir}
ln -s ../libexec/dragon-q8b-qnn-sync %{buildroot}%{_bindir}/dragon-q8b-qnn
install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/profile.d/dragon-q8b-qnn.sh
install -Dpm0644 %{SOURCE2} %{buildroot}%{_prefix}/lib/dragon-q8b/qnn.conf
install -Dpm0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/ld.so.conf.d/dragon-q8b-qnn.conf
install -Dpm0644 %{SOURCE4} %{buildroot}%{_sysconfdir}/dragon-q8b/qnn.conf
install -Dpm0644 %{SOURCE5} %{buildroot}%{_unitdir}/dragon-q8b-qnn-upgrade.service

%post
%systemd_post dragon-q8b-qnn-upgrade.service
if [ "$1" -ge 1 ] && [ -e /var/lib/dragon-q8b-qnn/accepted-license-sha256 ]; then
    /usr/bin/systemctl start --no-block dragon-q8b-qnn-upgrade.service >/dev/null 2>&1 || :
fi

%preun
%systemd_preun dragon-q8b-qnn-upgrade.service

%postun
%systemd_postun dragon-q8b-qnn-upgrade.service

%files
%dir %{_prefix}/lib/dragon-q8b
%{_prefix}/lib/dragon-q8b/qnn.conf
%config(noreplace) %{_sysconfdir}/dragon-q8b/qnn.conf
%{_sysconfdir}/profile.d/dragon-q8b-qnn.sh
%{_sysconfdir}/ld.so.conf.d/dragon-q8b-qnn.conf
%{_bindir}/dragon-q8b-qnn
%{_libexecdir}/dragon-q8b-qnn-sync
%{_unitdir}/dragon-q8b-qnn-upgrade.service

%changelog
* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.3.0-1
- Follow Software Center Community Edition pins; silent refresh after first license accept.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.2.0-1
- Install the pinned official QAIRT SDK after explicit license acceptance.

* Sat Aug 29 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Initial QNN runtime synchronization service and timer.
