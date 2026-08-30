%global alsa_ucm_version 1.2.16.1-radxa-1
%{!?package_release:%global package_release 1}

Name:           dragon-q8b-alsa-ucm
Version:        1.0.0
Release:        %{package_release}%{?dist}
Summary:        Radxa Dragon Q8B ALSA UCM overlay
License:        BSD-3-Clause
URL:            https://github.com/gjpin/fedora-dragon-q8b
BuildArch:      noarch
Requires:       alsa-ucm
BuildRequires:  patch
BuildRequires:  tar

Source0:        alsa-ucm-conf-%{alsa_ucm_version}.tar.gz
Source1:        RadxaComputerCo.Ltd.-RadxaDragonQ8B.conf

%description
Installs the Radxa Dragon Q8B Qualcomm SC8280XP UCM profiles as an /etc
overlay plus a conf.d DMI match. Fedora's SoC sc8280xp.conf is not replaced.

%prep
%setup -q -n alsa-ucm-conf-%{alsa_ucm_version}
# Q8B profiles live as debian-quilt patches on top of the alsa-project submodule.
patch -p1 < debian/patches/radxa/0004-ucm2-Qualcomm-add-Radxa-Dragon-Q8B.patch
patch -p1 < debian/patches/radxa/0007-ucm2-Qualcomm-radxa-dragon-q8b-Use-the-CLS_AB_HIFI-w.patch

%install
ucm_root=src/ucm2/Qualcomm/sc8280xp
test -f "$ucm_root/Dragon-Q8B-HiFi.conf"
test -f "$ucm_root/Radxa-Dragon-Q8B.conf"
install -Dpm0644 "$ucm_root/Dragon-Q8B-HiFi.conf" \
    %{buildroot}%{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf
install -Dpm0644 "$ucm_root/Radxa-Dragon-Q8B.conf" \
    %{buildroot}%{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/Radxa-Dragon-Q8B.conf
# Compact DMI filename used by ALSA conf.d lookup (RadxaComputerCo.Ltd.-RadxaDragonQ8B*).
install -Dpm0644 %{SOURCE1} \
    %{buildroot}%{_sysconfdir}/alsa/ucm2/conf.d/sc8280xp/RadxaComputerCo.Ltd.-RadxaDragonQ8B.conf
install -Dpm0644 %{SOURCE1} \
    %{buildroot}%{_sysconfdir}/alsa/ucm2/conf.d/sc8280xp/RadxaComputerCo.Ltd.-RadxaDragonQ8B-1.0.conf

%files
%license LICENSE
%config(noreplace) %{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf
%config(noreplace) %{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/Radxa-Dragon-Q8B.conf
%config(noreplace) %{_sysconfdir}/alsa/ucm2/conf.d/sc8280xp/RadxaComputerCo.Ltd.-RadxaDragonQ8B.conf
%config(noreplace) %{_sysconfdir}/alsa/ucm2/conf.d/sc8280xp/RadxaComputerCo.Ltd.-RadxaDragonQ8B-1.0.conf

%changelog
* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 1.0.0-2
- Vendor ALSA UCM from the Radxa git tag and install a conf.d DMI match.

* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 1.0.0-1
- Add Radxa Dragon Q8B ALSA UCM overlay.
