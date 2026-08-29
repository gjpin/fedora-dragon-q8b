#!/usr/bin/env bash
set -Eeuo pipefail

# Print a stable, shell-safe manifest of an installed RPM. This is used by CI
# to detect accidental ownership overlap between qcom-firmware and the Radxa
# supplemental package.
usage() {
    echo "Usage: resolve-rpm-files.sh RPM..." >&2
}
[[ $# -gt 0 ]] || { usage; exit 2; }
command -v rpm >/dev/null || { echo "rpm is required" >&2; exit 1; }

for rpm_name in "$@"; do
    rpm -ql "$rpm_name" | LC_ALL=C sort | sed "s#^#$rpm_name\t#"
done

