%global overlays_ref be64705364a8f131da018e322e04f3232e56d9a9
%{!?package_release:%global package_release 1}
%{!?radxa_overlays_ref:%global radxa_overlays_ref %{overlays_ref}}

Name:           dragon-q8b-overlays
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Radxa Dragon Q8B device-tree overlays
License:        BSD-3-Clause
URL:            https://github.com/radxa-pkg/radxa-overlays
BuildArch:      noarch
BuildRequires:  dtc
BuildRequires:  gcc
BuildRequires:  kernel-devel

Source0:        https://github.com/radxa-pkg/radxa-overlays/archive/%{radxa_overlays_ref}.tar.gz

%description
Device-tree overlays for the Dragon Q8B expansion headers and optional FPC
PCIe connector. The base Q8B device tree is shipped by the custom kernel.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%build
overlay_dir=$(find . -type d -path '*/arch/arm64/boot/dts/qcom/overlays' -print -quit)
test -n "$overlay_dir"
mkdir -p built
dt_include=$(find /usr/src/kernels -type d -path '*/include/dt-bindings' -print -quit 2>/dev/null || :)
test -n "$dt_include"
dt_include=${dt_include%/dt-bindings}
for name in \
    sc8280xp-i2c18 sc8280xp-i2c20 sc8280xp-i2c4 sc8280xp-i2c5 \
    sc8280xp-i2c8 sc8280xp-i2c9 \
    sc8280xp-radxa-dragon-q8b-fpc-pcie \
    sc8280xp-radxa-dragon-q8b-spi18-enc28j60 \
    sc8280xp-radxa-dragon-q8b-spi20-enc28j60 \
    sc8280xp-radxa-dragon-q8b-spi4-enc28j60 \
    sc8280xp-radxa-dragon-q8b-spi9-enc28j60 \
    sc8280xp-spi18-spidev sc8280xp-spi20-spidev \
    sc8280xp-spi4-spidev sc8280xp-spi9-spidev \
    sc8280xp-uart18 sc8280xp-uart20 sc8280xp-uart4 sc8280xp-uart6 sc8280xp-uart9; do
    src="$overlay_dir/$name.dtso"
    test -f "$src"
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$dt_include" \
        "$src" > "built/$name.dts"
    dtc -@ -I dts -O dtb -o "built/$name.dtbo" "built/$name.dts"
done

%install
install -d %{buildroot}%{_datadir}/dragon-q8b/overlays
install -m0644 built/*.dtbo %{buildroot}%{_datadir}/dragon-q8b/overlays/

cat > %{buildroot}%{_datadir}/dragon-q8b/overlays/README <<'EOF'
These overlays target compatible = "radxa,dragon-q8b".
Apply them using the boot firmware's documented device-tree overlay mechanism.
Do not enable mutually exclusive SPI/ENC28J60 and SPI/spidev overlays on the
same controller.
EOF

%files
%{_datadir}/dragon-q8b/overlays/

%changelog
* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Add Q8B expansion-header and FPC PCIe overlays.
