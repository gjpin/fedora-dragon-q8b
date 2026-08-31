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
Source2:        sc8280xp-radxa-dragon-q8b-pwm-fan.dtso
Source3:        dragon-q8b-overlay
Source4:        overlays.conf

%description
Device-tree overlays for the Dragon Q8B expansion headers, optional FPC
PCIe connector, and the optional Heatsink 6845B PWM fan (schematic GPIO119
via pwm-gpio, with the Q20 open-drain inversion and pulled-high fail-safe intent
modeled). The period and fan response are not hardware-validated. The base Q8B
device tree is shipped by the custom kernel. Enable overlays with
dragon-q8b-overlay.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}
cp %{SOURCE1} overlays.list
cp %{SOURCE2} sc8280xp-radxa-dragon-q8b-pwm-fan.dtso

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

# Q8B schematic v1.30: GPIO119 drives an inverting Q20 open-drain stage.
# Assert the compiled artifact, not only the preprocessed source, keeps the
# intended 25 kHz, inverted consumer polarity, and pulled-high fail-safe model.
fan_dtbo=built/sc8280xp-radxa-dragon-q8b-pwm-fan.dtbo
test -f "$fan_dtbo"
set -- $(fdtget -t i "$fan_dtbo" /fragment@1/__overlay__/pwm-fan pwms)
test "$#" -eq 4
test "$2" -eq 0
test "$3" -eq 40000
test "$4" -eq 1
test "$(fdtget -t i "$fan_dtbo" /fragment@1/__overlay__/pwm-fan fan-shutdown-percent)" -eq 100
fdtget -p "$fan_dtbo" /fragment@0/__overlay__/fan-pwm-state | grep -qx bias-pull-down
set -- $(fdtget -t i "$fan_dtbo" /fragment@1/__overlay__/pwm-gpio-fan gpios)
test "$#" -eq 3
test "$2" -eq 119
test "$3" -eq 0

%install
install -d %{buildroot}%{_datadir}/dragon-q8b/overlays
install -m0644 built/*.dtbo %{buildroot}%{_datadir}/dragon-q8b/overlays/
install -Dpm0755 %{SOURCE3} %{buildroot}%{_sbindir}/dragon-q8b-overlay
install -Dpm0644 %{SOURCE4} %{buildroot}%{_sysconfdir}/dragon-q8b/overlays.conf

cat > %{buildroot}%{_datadir}/dragon-q8b/overlays/README <<'EOF'
These overlays target compatible = "radxa,dragon-q8b".
Enable them with dragon-q8b-overlay (enable|disable|list), then reboot.
The kernel-install plugin merges enabled overlays into the Q8B DTB with
fdtoverlay. Do not enable mutually exclusive SPI/ENC28J60 and SPI/spidev
overlays on the same controller.

Heatsink 6845B PWM fan: schematic v1.30 FAN_PWM is TLMM GPIO119 (pwm-gpio).
The overlay compensates for Q20's open-drain inversion and favors J6's
pulled-high, inferred full-speed state at idle/shutdown. Enable with
dragon-q8b-overlay enable pwm-fan then reboot. The 25 kHz period, RPM curve,
starting duty, and inferred high=input-full-speed response need physical test.
EOF

%files
%config(noreplace) %{_sysconfdir}/dragon-q8b/overlays.conf
%{_sbindir}/dragon-q8b-overlay
%{_datadir}/dragon-q8b/overlays/

%changelog
* Mon Aug 31 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-4
- Restore overlays.conf when a strict DTB refresh does not merge.
- Model the 6845B Q20 inversion and pulled-high idle/shutdown fail-safe intent.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-3
- Drive the 6845B fan from schematic GPIO119 via pwm-gpio.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-2
- Compile overlays from config/overlays.list and add the 6845B pwm-fan overlay.

* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Add Q8B expansion-header and FPC PCIe overlays.
