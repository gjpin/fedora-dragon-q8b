#!/usr/bin/env bash
set -Eeuo pipefail

directory=${1:?Usage: validate-srpms.sh SRPM-DIR}
command -v rpm >/dev/null || { echo "rpm is required" >&2; exit 1; }
count=0
while IFS= read -r -d '' srpm; do
    count=$((count + 1))
    name=$(rpm -qp --qf '%{NAME}' "$srpm")
    version=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$srpm")
    printf 'validated SRPM %s-%s\n' "$name" "$version"
    rpm -qpl "$srpm" >/dev/null
done < <(find "$directory" -maxdepth 1 -type f -name '*.src.rpm' -print0)
[[ $count -gt 0 ]] || { echo "no SRPMs found in $directory" >&2; exit 1; }

