%{!?package_release:%global package_release 1}

Name:           dragon-q8b-qnn
Version:        0.2.0
Release:        %{package_release}%{?dist}
Summary:        Qualcomm QAIRT/QNN installer and validator for Radxa Dragon Q8B
License:        MIT
URL:            https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct-sdk
BuildArch:      noarch

Source0:        dragon-q8b-qnn-sync
Source1:        dragon-q8b-qnn.sh
Source2:        dragon-q8b-qnn.conf
Source3:        dragon-q8b-qnn-ld.so.conf

Requires:       bash
Requires:       coreutils
Requires:       curl
Requires:       glibc
Requires:       unzip
Requires:       dragon-q8b-fastrpc
Requires:       dragon-q8b-firmware

%description
Provides Fedora integration that downloads the official Qualcomm AI Runtime
(QAIRT/QNN) Community Edition directly from Qualcomm after explicit license
acceptance, verifies its pinned checksum, installs the SC8280XP HTP v68 runtime,
and validates NPU access. The proprietary SDK is not contained in this RPM.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_libexecdir}/dragon-q8b-qnn-sync
install -d %{buildroot}%{_bindir}
ln -s ../libexec/dragon-q8b-qnn-sync %{buildroot}%{_bindir}/dragon-q8b-qnn
install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/profile.d/dragon-q8b-qnn.sh
install -Dpm0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/dragon-q8b/qnn.conf
install -Dpm0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/ld.so.conf.d/dragon-q8b-qnn.conf

%files
%config(noreplace) %{_sysconfdir}/dragon-q8b/qnn.conf
%config(noreplace) %{_sysconfdir}/profile.d/dragon-q8b-qnn.sh
%config(noreplace) %{_sysconfdir}/ld.so.conf.d/dragon-q8b-qnn.conf
%{_bindir}/dragon-q8b-qnn
%{_libexecdir}/dragon-q8b-qnn-sync

%changelog
* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.2.0-1
- Install the pinned official QAIRT SDK after explicit license acceptance.

* Sat Aug 29 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Initial QNN runtime synchronization service and timer.
