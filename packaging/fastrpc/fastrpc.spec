%global fastrpc_version 1.0.6
%{!?package_release:%global package_release 1}

Name:           fastrpc
Version:        %{fastrpc_version}
Release:        %{package_release}%{?dist}
Summary:        Qualcomm FastRPC userspace runtime
License:        BSD-3-Clause
URL:            https://github.com/gjpin/fedora-dragon-q8b
ExclusiveArch:  aarch64

Source0:        fastrpc-%{version}.tar.gz
Source1:        fastrpc.sysusers
Source2:        dragon-q8b-fastrpc.sh

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  autoconf
BuildRequires:  automake
BuildRequires:  libtool
BuildRequires:  pkgconfig
BuildRequires:  libyaml-devel
BuildRequires:  libbsd-devel
BuildRequires:  systemd-rpm-macros
Requires:       acl
Requires:       systemd
%{?sysusers_requires_compat}

%description
Qualcomm FastRPC userspace libraries and DSP listener daemons (libadsprpc,
libcdsprpc, libsdsprpc). Device nodes are root:fastrpc mode 0640. udev
SYSTEMD_WANTS starts the matching listener; this package does not force-enable
every daemon.

%package devel
Summary:        Development files for Qualcomm FastRPC
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description devel
Header files and unversioned shared-library links for building applications
that use Qualcomm FastRPC.

%package -n dragon-q8b-fastrpc
Summary:        Dragon Q8B FastRPC DSP search path
Requires:       fastrpc%{?_isa} = %{version}-%{release}
Requires:       dragon-q8b-firmware

%description -n dragon-q8b-fastrpc
Board-specific ADSP_LIBRARY_PATH / DSP_LIBRARY_PATH for the Radxa Dragon Q8B
DSP libraries. The FastRPC runtime itself is in the fastrpc package.

%prep
%setup -q -n fastrpc-%{version}

%build
autoreconf -vfi
%configure \
    --disable-static \
    --with-systemdsystemunitdir=%{_unitdir} \
    --with-udevrulesdir=%{_udevrulesdir} \
    --with-sysusersdir=%{_sysusersdir}
%make_build

%install
%make_install
find %{buildroot} -name '*.la' -delete
rm -rf %{buildroot}%{_libdir}/fastrpc_test %{buildroot}%{_datadir}/fastrpc_test %{buildroot}%{_bindir}/fastrpc_test
install -Dpm0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/profile.d/dragon-q8b-fastrpc.sh
# Upstream 60-fastrpc.rules (0640 + group fastrpc) is installed by make.
# Do not ship a duplicate world-writable udev overlay.

%pre
%sysusers_create_compat %{SOURCE1}

%post
%systemd_post adsprpcd.service adsprpcd_audiopd.service cdsprpcd.service cdsp1rpcd.service sdsprpcd.service gdsp0rpcd.service gdsp1rpcd.service

%preun
%systemd_preun adsprpcd.service adsprpcd_audiopd.service cdsprpcd.service cdsp1rpcd.service sdsprpcd.service gdsp0rpcd.service gdsp1rpcd.service

%postun
%systemd_postun_with_restart adsprpcd.service adsprpcd_audiopd.service cdsprpcd.service cdsp1rpcd.service sdsprpcd.service gdsp0rpcd.service gdsp1rpcd.service

%files
%license LICENSE.txt
%doc README.md
%{_sbindir}/adsprpcd
%{_sbindir}/cdsprpcd
%{_sbindir}/sdsprpcd
%{_sbindir}/gdsprpcd
%{_libdir}/libadsprpc.so.1
%{_libdir}/libadsprpc.so.1.0.0
%{_libdir}/libcdsprpc.so.1
%{_libdir}/libcdsprpc.so.1.0.0
%{_libdir}/libsdsprpc.so.1
%{_libdir}/libsdsprpc.so.1.0.0
%{_libdir}/libadsp_default_listener.so.1
%{_libdir}/libadsp_default_listener.so.1.0.0
%{_libdir}/libcdsp_default_listener.so.1
%{_libdir}/libcdsp_default_listener.so.1.0.0
%{_libdir}/libsdsp_default_listener.so.1
%{_libdir}/libsdsp_default_listener.so.1.0.0
%{_unitdir}/adsprpcd.service
%{_unitdir}/adsprpcd_audiopd.service
%{_unitdir}/cdsprpcd.service
%{_unitdir}/cdsp1rpcd.service
%{_unitdir}/sdsprpcd.service
%{_unitdir}/gdsp0rpcd.service
%{_unitdir}/gdsp1rpcd.service
%{_sysusersdir}/fastrpc.conf
%{_udevrulesdir}/60-fastrpc.rules

%files devel
%{_includedir}/fastrpc/
%{_libdir}/libadsprpc.so
%{_libdir}/libcdsprpc.so
%{_libdir}/libsdsprpc.so
%{_libdir}/libadsp_default_listener.so
%{_libdir}/libcdsp_default_listener.so
%{_libdir}/libsdsp_default_listener.so

%files -n dragon-q8b-fastrpc
%config(noreplace) %{_sysconfdir}/profile.d/dragon-q8b-fastrpc.sh

%changelog
* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 1.0.6-2
- Keep systemd scriptlets on one line so RPM %post is valid shell.

* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 1.0.6-1
- Package Qualcomm FastRPC 1.0.6 with a Dragon Q8B config subpackage.
