%global kernel_need_version 7.1.12
%global kernel_need_release 200.dragonq8b%{?dist}
%{!?package_release:%global package_release 1}

Name:           dragon-q8b-kernel
Version:        0.1.0
Release:        %{package_release}%{?dist}
Summary:        Fedora kernel dependency for Radxa Dragon Q8B
License:        MIT
URL:            https://github.com/gjpin/fedora-dragon-q8b
BuildArch:      noarch

# build-srpms.sh rewrites these two macros from the Fedora kernel spec. Exact
# NEVRA matching prevents the support bundle from silently selecting stock
# Fedora kernel packages.
Requires:       kernel-core%{?_isa} = %{kernel_need_version}-%{kernel_need_release}
Requires:       kernel-modules-core%{?_isa} = %{kernel_need_version}-%{kernel_need_release}
Requires:       kernel-modules%{?_isa} = %{kernel_need_version}-%{kernel_need_release}
Recommends:     kernel-devel%{?_isa} = %{kernel_need_version}-%{kernel_need_release}

%description
Pins the Dragon Q8B support bundle to the matching Fedora kernel rebuild while
leaving older stock and custom kernels installed for rollback.

%files

%changelog
* Sun Aug 30 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-2
- Recommend kernel-devel at the pinned NVR instead of requiring it.

* Fri Aug 28 2026 Dragon Q8B Maintainers <maintainers@example.invalid> - 0.1.0-1
- Add exact custom-kernel dependency meta-package.
