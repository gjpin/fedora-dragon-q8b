%{!?package_release:%global package_release 1}

Name:           dragon-q8b-qnn
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Qualcomm QNN SDK and AI runtime synchronization service for Radxa Dragon Q8B
License:        MIT
URL:            https://docs.radxa.com/en/dragon/q8b
BuildArch:      noarch

Source0:        dragon-q8b-qnn-sync
Source1:        dragon-q8b-qnn.service
Source2:        dragon-q8b-qnn.timer
Source3:        dragon-q8b-qnn.sh
Source4:        dragon-q8b-qnn.conf

BuildRequires:  systemd-rpm-macros
Requires:       curl
Requires:       jq
Requires:       tar
Requires:       dragon-q8b-fastrpc
Requires:       dragon-q8b-firmware

%description
Provides the background synchronization engine, systemd timer, and environment
configuration to automatically install, update, and manage the Qualcomm AI Engine
Direct (QNN) SDK and runtime libraries for the Radxa Dragon Q8B NPU.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_libexecdir}/dragon-q8b-qnn-sync
install -d %{buildroot}%{_bindir}
ln -s ../libexec/dragon-q8b-qnn-sync %{buildroot}%{_bindir}/dragon-q8b-qnn
install -Dpm0644 %{SOURCE1} %{buildroot}%{_unitdir}/dragon-q8b-qnn.service
install -Dpm0644 %{SOURCE2} %{buildroot}%{_unitdir}/dragon-q8b-qnn.timer
install -Dpm0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/profile.d/dragon-q8b-qnn.sh
install -Dpm0644 %{SOURCE4} %{buildroot}%{_sysconfdir}/ld.so.conf.d/dragon-q8b-qnn.conf

install -d %{buildroot}%{_sysconfdir}/dragon-q8b
cat > %{buildroot}%{_sysconfdir}/dragon-q8b/qnn.conf <<'EOF'
# Configuration for dragon-q8b-qnn-sync
# QNN_RELEASE_API="https://api.github.com/repos/qualcomm/qnn/releases/latest"
EOF

%posttrans
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || :
fi

%files
%config(noreplace) %{_sysconfdir}/dragon-q8b/qnn.conf
%config(noreplace) %{_sysconfdir}/profile.d/dragon-q8b-qnn.sh
%config(noreplace) %{_sysconfdir}/ld.so.conf.d/dragon-q8b-qnn.conf
%{_bindir}/dragon-q8b-qnn
%{_libexecdir}/dragon-q8b-qnn-sync
%{_unitdir}/dragon-q8b-qnn.service
%{_unitdir}/dragon-q8b-qnn.timer

%changelog
* Sat Aug 29 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Initial QNN runtime synchronization service and timer.
