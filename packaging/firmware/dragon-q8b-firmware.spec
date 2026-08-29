%global _source_firmware_ref e1761009df008adfd62c77f2c5584e3067449013
%global _source_firmware_version 0.2.41
%{!?package_release:%global package_release 1}
%{!?radxa_firmware_ref:%global radxa_firmware_ref %{_source_firmware_ref}}
%{!?radxa_firmware_version:%global radxa_firmware_version %{_source_firmware_version}}

Name:           dragon-q8b-firmware
Version:        %{radxa_firmware_version}
Release:        %{package_release}%{?dist}
Summary:        Radxa Dragon Q8B supplemental Qualcomm firmware
License:        Redistributable, see LICENSE
URL:            https://github.com/radxa-pkg/radxa-firmware
BuildArch:      noarch

Source0:        https://github.com/radxa-pkg/radxa-firmware/archive/%{radxa_firmware_ref}.tar.gz

%description
Supplemental SC8280XP and Dragon Q8B firmware from Radxa. Fedora's generic
qcom-firmware package remains the owner of generic Qualcomm firmware; this
package owns only the Radxa-specific firmware and DSP library paths.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%install
srcdir=$(find . -type d -name radxa-firmware-sc8280xp -print -quit)
test -n "$srcdir"

install -d %{buildroot}%{_prefix}/lib/firmware/qcom
install -d %{buildroot}%{_datadir}/qcom/sc8280xp/radxa/dragon-q8b
cp -a "$srcdir/lib/firmware/qcom/sc8280xp" %{buildroot}%{_prefix}/lib/firmware/qcom/
cp -a "$srcdir/lib/firmware/qcom/vpu" %{buildroot}%{_prefix}/lib/firmware/qcom/
cp -a "$srcdir/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp" \
    %{buildroot}%{_datadir}/qcom/sc8280xp/radxa/dragon-q8b/

if [ -f LICENSE ]; then
    install -Dpm0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE
elif [ -f "$srcdir/../LICENSE" ]; then
    install -Dpm0644 "$srcdir/../LICENSE" %{buildroot}%{_licensedir}/%{name}/LICENSE
else
    echo "Radxa firmware license file was not found" >&2
    exit 1
fi

%files
%license %{_licensedir}/%{name}/LICENSE
%{_prefix}/lib/firmware/qcom/sc8280xp/
%{_prefix}/lib/firmware/qcom/vpu/vpu20_p4_gen2_s6.mbn
%{_datadir}/qcom/sc8280xp/radxa/dragon-q8b/dsp/

%changelog
* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.2.41-1
- Package Radxa SC8280XP and Dragon Q8B supplemental firmware.
