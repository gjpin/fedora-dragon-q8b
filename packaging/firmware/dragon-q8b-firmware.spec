%global _source_firmware_ref e1761009df008adfd62c77f2c5584e3067449013
%global _source_firmware_version 0.2.41
%{!?package_release:%global package_release 1}
%{!?radxa_firmware_ref:%global radxa_firmware_ref %{_source_firmware_ref}}
%{!?radxa_firmware_version:%global radxa_firmware_version %{_source_firmware_version}}

# Firmware and Hexagon DSP binaries are architecture-independent data blobs for host packaging
%global _binaries_in_noarch_packages_terminate_build 0
%global __strip /bin/true
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_static_archive %{nil}
%global __brp_ldconfig %{nil}
AutoReqProv:    no

Name:           dragon-q8b-firmware
Version:        %{radxa_firmware_version}
Release:        %{package_release}%{?dist}
Summary:        Radxa Dragon Q8B supplemental Qualcomm firmware
License:        Redistributable, see LICENSE
URL:            https://github.com/gjpin/fedora-dragon-q8b
BuildArch:      noarch
Requires:       qcom-firmware

Source0:        radxa-firmware-%{radxa_firmware_ref}.tar.gz
Source1:        firmware.files

%description
Supplemental Dragon Q8B firmware from Radxa. Fedora's qcom-firmware package
owns generic Qualcomm blobs including LENOVO/21BX GPU ZAP reused by the Q8B
DTS. This package installs only the Q8B-specific paths listed in firmware.files.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%install
srcdir=$(find . -type d -name radxa-firmware-sc8280xp -print -quit)
test -n "$srcdir"

license=
if [ -f LICENSE ]; then
    license=LICENSE
elif [ -f "$srcdir/../LICENSE" ]; then
    license="$srcdir/../LICENSE"
else
    echo "Radxa firmware license file was not found" >&2
    exit 1
fi
install -Dpm0644 "$license" %{buildroot}%{_licensedir}/%{name}/LICENSE

rm -f q8b-firmware.files
: > q8b-firmware.files

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|\#*) continue ;;
    esac
    optional=0
    relpath=$line
    case "$relpath" in
        optional:*)
            optional=1
            relpath=${relpath#optional:}
            ;;
    esac
    src="$srcdir/$relpath"
    if [ ! -e "$src" ]; then
        if [ "$optional" -eq 1 ]; then
            echo "optional firmware not in archive, skipping: $relpath"
            continue
        fi
        echo "firmware path listed but missing from archive: $relpath" >&2
        exit 1
    fi
    case "$relpath" in
        lib/*)
            dest="%{buildroot}%{_prefix}/$relpath"
            packaged="%{_prefix}/$relpath"
            ;;
        usr/share/*)
            dest="%{buildroot}/$relpath"
            packaged="%{_datadir}/${relpath#usr/share/}"
            ;;
        *)
            dest="%{buildroot}/$relpath"
            packaged="/$relpath"
            ;;
    esac
    if [ -d "$src" ]; then
        install -d "$dest"
        cp -a "$src"/. "$dest"/
    else
        install -Dpm0644 "$src" "$dest"
    fi
    # Pass packaged paths as printf arguments. bash printf must not see
    # an RPM macro in the format string (percent-brace is not a conversion).
    printf '%%s\n' "$packaged" >> q8b-firmware.files
done < %{SOURCE1}

%files -f q8b-firmware.files
%license %{_licensedir}/%{name}/LICENSE

%changelog
* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.2.41-3
- Write firmware file lists with printf %%s so RPM macros are not format strings.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.2.41-2
- Install only Q8B firmware paths from config/firmware.files.

* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.2.41-1
- Package Radxa SC8280XP and Dragon Q8B supplemental firmware.
