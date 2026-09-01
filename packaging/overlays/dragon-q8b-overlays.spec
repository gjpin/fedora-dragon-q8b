%global overlays_ref be64705364a8f131da018e322e04f3232e56d9a9
%{!?package_release:%global package_release 1}
%{!?radxa_overlays_ref:%global radxa_overlays_ref %{overlays_ref}}

Name:           dragon-q8b-overlays
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Radxa Dragon Q8B device-tree overlays
License:        BSD-3-Clause
URL:            https://github.com/gjpin/fedora-dragon-q8b
BuildArch:      noarch
BuildRequires:  dtc
BuildRequires:  gcc
BuildRequires:  kernel-devel
Requires:       dtc
Requires:       dragon-q8b-boot

Source0:        radxa-overlays-%{radxa_overlays_ref}.tar.gz
Source1:        overlays.list
Source2:        dragon-q8b-overlay
Source3:        overlays.conf

%description
Device-tree overlays for the Dragon Q8B expansion headers and optional FPC
PCIe connector. The base Q8B device tree is shipped by the custom kernel.
Enable overlays with dragon-q8b-overlay.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}
cp %{SOURCE1} overlays.list

%build
overlay_dir=$(find . -type d -path '*/arch/arm64/boot/dts/qcom/overlays' -print -quit)
test -n "$overlay_dir"
mkdir -p built
dt_include=$(find /usr/src/kernels -type d -path '*/include/dt-bindings' -print -quit 2>/dev/null || :)
test -n "$dt_include"
dt_include=${dt_include%/dt-bindings}
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|\#*) continue ;;
    esac
    name=$line
    src=
    case "$name" in
        local:*)
            name=${name#local:}
            src="./${name}.dtso"
            ;;
        *)
            src="$overlay_dir/${name}.dtso"
            ;;
    esac
    test -f "$src"
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$dt_include" \
        "$src" > "built/${name}.dts"
    dtc -@ -I dts -O dtb -o "built/${name}.dtbo" "built/${name}.dts"
done < overlays.list

%install
install -d %{buildroot}%{_datadir}/dragon-q8b/overlays
install -m0644 built/*.dtbo %{buildroot}%{_datadir}/dragon-q8b/overlays/
install -Dpm0755 %{SOURCE2} %{buildroot}%{_sbindir}/dragon-q8b-overlay
install -Dpm0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/dragon-q8b/overlays.conf

cat > %{buildroot}%{_datadir}/dragon-q8b/overlays/README <<'EOF'
These overlays target compatible = "radxa,dragon-q8b".
Enable them with dragon-q8b-overlay (enable|disable|list), then reboot.
The kernel-install plugin merges enabled overlays into the Q8B DTB with
fdtoverlay. Do not enable mutually exclusive SPI/ENC28J60 and SPI/spidev
overlays on the same controller.
EOF

%files
%config(noreplace) %{_sysconfdir}/dragon-q8b/overlays.conf
%{_sbindir}/dragon-q8b-overlay
%{_datadir}/dragon-q8b/overlays/

%changelog
* Tue Sep 01 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-5
- Remove obsolete pwm-fan overlay; active fan control is handled by ADSP firmware.

* Mon Aug 31 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-4
- Restore overlays.conf when a strict DTB refresh does not merge.
- Model the 6845B Q20 inversion and pulled-high idle/shutdown fail-safe intent.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-3
- Drive the 6845B fan from schematic GPIO119 via pwm-gpio.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-2
- Compile overlays from config/overlays.list and add the 6845B pwm-fan overlay.

* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Add Q8B expansion-header and FPC PCIe overlays.
