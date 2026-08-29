%global alsa_ucm_version 1.2.16.1-radxa-1
%{!?package_release:%global package_release 1}

Name:           dragon-q8b-alsa-ucm
Version:        1.0.0
Release:        %{package_release}%{?dist}
Summary:        Radxa Dragon Q8B ALSA UCM overlay
License:        BSD-3-Clause
URL:            https://github.com/radxa-pkg/alsa-ucm-conf
BuildArch:      noarch
Requires:       alsa-ucm
BuildRequires:  binutils
BuildRequires:  tar

Source0:        alsa-ucm-conf_%{alsa_ucm_version}_all.deb

%description
Installs the Radxa Dragon Q8B Qualcomm SC8280XP UCM profiles as an /etc
overlay. Keeping the files under /etc avoids taking ownership of Fedora's
vendor UCM database while allowing the Q8B DMI match to take precedence.

%prep
mkdir extracted
ar x %{SOURCE0}
data_archive=$(find . -maxdepth 1 -name 'data.tar.*' -print -quit)
test -n "$data_archive"
tar -xf "$data_archive" -C extracted

%install
ucm_root=extracted/usr/share/alsa/ucm2/Qualcomm/sc8280xp
test -d "$ucm_root"
for file in Dragon-Q8B-HiFi.conf Radxa-Dragon-Q8B.conf sc8280xp.conf; do
    test -f "$ucm_root/$file"
    install -Dpm0644 "$ucm_root/$file" \
        "%{buildroot}%{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/$file"
done

%files
%config(noreplace) %{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf
%config(noreplace) %{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/Radxa-Dragon-Q8B.conf
%config(noreplace) %{_sysconfdir}/alsa/ucm2/Qualcomm/sc8280xp/sc8280xp.conf

%changelog
* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 1.0.0-1
- Add Radxa Dragon Q8B ALSA UCM overlay.
