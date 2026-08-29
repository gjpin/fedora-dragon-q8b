%global fastrpc_ref 228d98b5f143ed917789cde017a8aa548e65b80b
%global fastrpc_version 0.0.1
%{!?package_release:%global package_release 1}
%{!?qualcomm_fastrpc_ref:%global qualcomm_fastrpc_ref %{fastrpc_ref}}

Name:           dragon-q8b-fastrpc
Version:        %{fastrpc_version}
Release:        %{package_release}%{?dist}
Summary:        Qualcomm FastRPC userspace runtime libraries for Radxa Dragon Q8B
License:        BSD-3-Clause
URL:            https://github.com/qualcomm/fastrpc

Source0:        fastrpc-%{qualcomm_fastrpc_ref}.tar.gz
Source1:        60-dragon-q8b-fastrpc.rules
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
Requires:       dragon-q8b-firmware

%description
Qualcomm FastRPC userspace runtime libraries (libcdsprpc, libadsprpc) and
support utilities for dispatching remote procedure calls to the Qualcomm
Compute DSP (CDSP / NPU) and Audio DSP (ADSP) on the Radxa Dragon Q8B.

%package devel
Summary:        Development files for Qualcomm FastRPC
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description devel
Header files and development libraries for building applications that interface
with Qualcomm FastRPC.

%prep
%setup -q -n fastrpc-%{qualcomm_fastrpc_ref}

%build
autoreconf -vfi
%configure --disable-static
%make_build

%install
%make_install
find %{buildroot} -name '*.la' -delete
rm -rf %{buildroot}%{_libdir}/fastrpc_test %{buildroot}%{_datadir}/fastrpc_test %{buildroot}%{_bindir}/fastrpc_test
install -Dpm0644 %{SOURCE1} %{buildroot}%{_udevrulesdir}/60-dragon-q8b-fastrpc.rules
install -Dpm0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/profile.d/dragon-q8b-fastrpc.sh

%files
%license LICENSE.txt
%{_bindir}/dsp_check
%{_sbindir}/*
%{_libdir}/lib*.so.*
%{_udevrulesdir}/60-dragon-q8b-fastrpc.rules
%{_sysconfdir}/profile.d/dragon-q8b-fastrpc.sh

%files devel
%{_includedir}/*
%{_libdir}/lib*.so

%changelog
* Sat Aug 29 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.0.1-1
- Initial Qualcomm FastRPC userspace runtime packaging for Dragon Q8B.
